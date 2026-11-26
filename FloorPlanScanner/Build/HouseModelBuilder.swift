import Foundation
import RoomPlan
import SceneKit
import UIKit
import simd

/// Runs the whole build: RoomPlan result → surfaces → photo textures → detailed furniture → house.usdz.
enum HouseModelBuilder {
    struct DetailModel {
        var objectID: UUID
        var modelURL: URL
        var quarterTurns: Int
    }

    struct Input {
        var roomURL: URL
        var frameLogURL: URL
        var framesDir: URL
        var depthDir: URL
        var texturesDir: URL
        var highResDir: URL
        var highResLogURL: URL
        var depthFramesDir: URL
        var depthFrameLogURL: URL
        var coverageURL: URL
        var outputURL: URL
        var includeCeilings: Bool
        var details: [DetailModel]
    }

    struct Output {
        var note: String
    }

    enum BuildError: LocalizedError {
        case noRoom(String)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noRoom(let why): return "Couldn't read the scan: \(why)"
            case .writeFailed: return "Couldn't save the 3D model."
            }
        }
    }

    /// Runs on a background thread. `progress` gets (fraction 0…1, stage text).
    static func run(_ input: Input, progress: @escaping (Double, String) -> Void,
                    isCancelled: @escaping () -> Bool) throws -> Output? {
        let fm = FileManager.default
        let started = Date()
        progress(0, "Reading the scan…")
        let room: CapturedRoom
        do {
            room = try JSONDecoder().decode(CapturedRoom.self, from: Data(contentsOf: input.roomURL))
        } catch {
            throw BuildError.noRoom(error.localizedDescription)
        }
        let frames: [Keyframe]
        var roomScanLosses: [SIMD3<Float>] = []
        if let data = try? Data(contentsOf: input.frameLogURL),
           let log = try? JSONDecoder().decode(KeyframeLog.self, from: data) {
            frames = log.frames
            roomScanLosses = (log.losses ?? []).compactMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
        } else {
            frames = []
        }

        // 1. Geometry.
        let usable = input.details.filter { fm.fileExists(atPath: $0.modelURL.path) }
        var options = SurfaceBuilder.Options()
        options.includeCeilings = input.includeCeilings
        options.replacedObjects = Set(usable.map(\.objectID))
        var geometry = SurfaceBuilder.build(room, options: options)

        // 1b. Real 3D shapes from the detail pass's LiDAR depth (if recorded).
        var fused: DepthFusion.Result?
        if fm.fileExists(atPath: input.depthFrameLogURL.path) {
            fused = DepthFusion.reconstruct(logURL: input.depthFrameLogURL, frameDir: input.depthFramesDir,
                                            geometry: geometry, room: room, cutOut: Set(usable.map(\.objectID)),
                                            progress: { progress(0.3 * $0, $1) }, isCancelled: isCancelled)
            if isCancelled() { return nil }
        }
        if fused != nil {
            // The mesh has the real furniture: its boxes are no longer drawn (they still help work out occlusion).
            for i in geometry.surfaces.indices where geometry.surfaces[i].kind == .furniture {
                geometry.surfaces[i].rendered = false
            }
        }
        let p0 = fused == nil ? 0.0 : 0.3      // progress after fusion
        let bakeShare = fused == nil ? 0.88 : 0.4

        // 2. Choose photos for each spot and balance their brightness.
        try? fm.removeItem(at: input.texturesDir)
        try fm.createDirectory(at: input.texturesDir, withIntermediateDirectories: true)
        var sources = [TextureBaker.PhotoSource(frames: frames, imageDir: input.framesDir, depthDir: input.depthDir,
                                                decodeSize: 960)]
        if let data = try? Data(contentsOf: input.highResLogURL),
           let log = try? JSONDecoder().decode(KeyframeLog.self, from: data), !log.frames.isEmpty {
            // 12 MP stills from the detail pass: decoded at up to 2048 px for sharper textures.
            // Same shift as the fused mesh, so detail-pass photos stay lined up with it.
            var frames = log.frames
            if let offset = fused?.offset, offset != .zero {
                for i in frames.indices where frames[i].transform.count == 16 {
                    frames[i].transform[12] += offset.x
                    frames[i].transform[13] += offset.y
                    frames[i].transform[14] += offset.z
                }
            }
            sources.append(TextureBaker.PhotoSource(frames: frames, imageDir: input.highResDir, depthDir: nil,
                                                    decodeSize: 2048))
        }
        let baker = TextureBaker(surfaces: geometry.surfaces, sources: sources)
        baker.floorY = geometry.floorY

        // 2b. Line the photos up with the geometry (photometric pose refinement).
        progress(p0, "Lining up \(baker.photoCount) photos…")
        let refineNote = baker.refinePoses(mesh: fused?.mesh,
                                           progress: { progress(p0 + 0.06 * $0, "Lining up \(baker.photoCount) photos…") },
                                           isCancelled: isCancelled)
        if isCancelled() { return nil }
        if let fused {
            // Exact occlusion for walls and floors from the 3D shape (things in front of a wall don't get painted on it).
            var scene = fused.mesh
            for s in geometry.surfaces where s.rendered && (s.kind == .wall || s.kind == .floor || s.kind == .ceiling) {
                baker.appendTessellated(s, to: &scene, cell: 0.3)
            }
            baker.setOcclusionScene(scene) { progress(p0 + 0.06, "Working out what each photo sees… \(Int($0 * 100))%") }
            if isCancelled() { return nil }
        }
        progress(p0 + 0.06, "Matching \(baker.photoCount) photos to walls and floors…")
        baker.prepare(progress: { progress(p0 + 0.06 + (bakeShare - 0.06) * 0.3 * $0, "Matching \(baker.photoCount) photos to walls and floors…") },
                      isCancelled: isCancelled)
        if isCancelled() { return nil }

        // 3. Bake each surface.
        let drawn = geometry.surfaces.indices.filter { geometry.surfaces[$0].rendered }
        var baked: [Int: TextureBaker.BakedSurface] = [:]
        var coverageSum: Float = 0
        var coverageCount: Float = 0
        for (n, si) in drawn.enumerated() {
            if isCancelled() { baker.releaseCache(); return nil }
            let s = geometry.surfaces[si]
            progress(p0 + 0.06 + (bakeShare - 0.06) * (0.3 + 0.7 * Double(n) / Double(max(1, drawn.count))),
                     "Painting \(label(s.kind)) \(n + 1) of \(drawn.count)…")
            let result = baker.bake(surfaceIndex: si, to: input.texturesDir, isCancelled: isCancelled)
            baked[si] = result
            if s.kind == .wall || s.kind == .floor {
                coverageSum += result.coverage
                coverageCount += 1
            }
        }
        // 3b. Texture the fused mesh from the photos (one sharp photo per face, packed into atlases).
        var meshParts: [TextureBaker.MeshPart] = []
        var meshNote: String?
        var unseenMeshPoints: [SIMD3<Float>] = []
        if let fused {
            let start = p0 + bakeShare
            let result = baker.textureMesh(fused.mesh, directory: input.texturesDir,
                                           progress: { progress(start + (0.92 - start) * $0, $1) },
                                           isCancelled: isCancelled)
            meshParts = result.parts
            unseenMeshPoints = result.unseenPoints
            meshNote = String(format: "3D shape textures at %.0f%% of photo resolution; %.0f%% of it seen by no photo.",
                              result.scale * 100, result.unseenShare * 100)
        }
        baker.releaseCache()
        if isCancelled() { return nil }

        // 4. Assemble the scene, centred on the footprint with the floor at y = 0.
        progress(0.92, "Putting the house together…")
        let scene = SCNScene()
        let house = SCNNode()
        house.name = "House"
        house.simdPosition = SIMD3(-geometry.center.x, -geometry.floorY, -geometry.center.y)
        scene.rootNode.addChildNode(house)

        let structure = SCNNode()
        structure.name = "Structure"
        let furniture = SCNNode()
        furniture.name = "Furniture"
        house.addChildNode(structure)
        house.addChildNode(furniture)

        // Faces no photo saw (e.g. tops of tall cabinets) take the average color of the same object's seen faces.
        var groupSum: [Int: (SIMD3<Float>, Float)] = [:]
        for si in drawn {
            let s = geometry.surfaces[si]
            guard s.kind == .furniture, let b = baked[si], b.textureURL != nil else { continue }
            let area = s.size.x * s.size.y
            let prev = groupSum[s.group] ?? (.zero, 0)
            groupSum[s.group] = (prev.0 + b.averageColor * area, prev.1 + area)
        }
        // Wall sides no photo saw (e.g. the outside of outer walls) take the average color of the seen walls.
        var wallSum = SIMD3<Float>.zero, wallArea: Float = 0
        for si in drawn where geometry.surfaces[si].kind == .wall {
            guard let b = baked[si], b.textureURL != nil else { continue }
            let area = geometry.surfaces[si].size.x * geometry.surfaces[si].size.y
            wallSum += b.averageColor * area
            wallArea += area
        }
        if wallArea > 0 {
            for si in drawn where geometry.surfaces[si].kind == .wall && baked[si]?.textureURL == nil {
                baked[si] = TextureBaker.BakedSurface(textureURL: nil, coverage: 0, averageColor: wallSum / wallArea)
            }
        }
        for si in drawn {
            let s = geometry.surfaces[si]
            if s.kind == .furniture, baked[si]?.textureURL == nil, let g = groupSum[s.group], g.1 > 0 {
                baked[si] = TextureBaker.BakedSurface(textureURL: nil, coverage: 0, averageColor: g.0 / g.1)
            }
            guard let node = node(for: s, baked: baked[si]) else { continue }
            (s.kind == .furniture ? furniture : structure).addChildNode(node)
        }
        for (i, part) in meshParts.enumerated() {
            if let node = node(for: part, name: "Scanned_\(i)") { furniture.addChildNode(node) }
        }

        // 5. Detailed furniture from photogrammetry, fitted into its RoomPlan box.
        var placed = 0
        for detail in usable {
            guard let object = room.objects.first(where: { $0.identifier == detail.objectID }),
                  let model = try? SCNScene(url: detail.modelURL, options: nil) else { continue }
            let holder = SCNNode()
            holder.name = "Detail_\(placed)"
            for child in model.rootNode.childNodes { holder.addChildNode(child.clone()) }
            guard let bounds = boundingBox(of: holder) else { continue }
            let wrapper = SCNNode()
            wrapper.name = "DetailedFurniture_\(placed)"
            wrapper.simdTransform = FurniturePlacer.placement(modelMin: bounds.min, modelMax: bounds.max,
                                                              boxTransform: object.transform,
                                                              boxSize: object.dimensions,
                                                              quarterTurns: detail.quarterTurns)
            wrapper.addChildNode(holder)
            furniture.addChildNode(wrapper)
            placed += 1
        }

        // 5b. Coverage map for the house page: what was photographed, what wasn't, where tracking was lost.
        _ = CoverageMapRenderer.render(CoverageMapRenderer.Input(
            surfaces: geometry.surfaces, baked: baked, cellSize: 0.10,
            unseenMeshPoints: unseenMeshPoints,
            photoPositions: baker.cameras.map(\.position),
            lossPositions: roomScanLosses + (fused?.lossPositions ?? [])), to: input.coverageURL)

        // 6. Write the USDZ.
        progress(0.96, "Saving the 3D model…")
        try? fm.removeItem(at: input.outputURL)
        let ok = scene.write(to: input.outputURL, options: nil, delegate: nil, progressHandler: nil)
        guard ok, fm.fileExists(atPath: input.outputURL.path) else { throw BuildError.writeFailed }
        progress(1, "Done")

        var lines: [String] = []
        let pct = coverageCount > 0 ? Int((coverageSum / coverageCount * 100).rounded()) : 0
        if baker.photoCount == 0 {
            lines.append("No photos were recorded during the scan, so walls and floors have plain colors.")
        } else {
            lines.append("Built from \(baker.photoCount) photos. Photos covered about \(pct)% of the walls and floors; the rest is filled with nearby colors.")
        }
        if let fused { lines.append(fused.note) }
        if let refineNote { lines.append(refineNote) }
        if let meshNote { lines.append(meshNote) }
        if baker.skippedPhotos > 0 {
            lines.append("\(baker.skippedPhotos) photos left out because tracking broke right after them.")
        }
        if !usable.isEmpty {
            lines.append("\(placed) detailed piece\(placed == 1 ? "" : "s") of furniture placed.")
        }
        if pct > 0 && pct < 60 {
            lines.append("Tip: for fuller textures, scan again more slowly and point the phone at every wall and the floor.")
        }
        let seconds = Int(Date().timeIntervalSince(started))
        lines.append(String(format: "Build took %d:%02d.", seconds / 60, seconds % 60))
        return Output(note: lines.joined(separator: "\n"))
    }

    private static func label(_ kind: PlanarSurface.Kind) -> String {
        switch kind {
        case .wall: return "wall"
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .window: return "window"
        case .furniture: return "furniture"
        }
    }

    /// A SceneKit node for one surface: triangles with UVs, and its photo texture (or average color).
    private static func node(for s: PlanarSurface, baked: TextureBaker.BakedSurface?) -> SCNNode? {
        let tris = s.triangles()
        guard tris.count >= 3 else { return nil }
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        vertices.reserveCapacity(tris.count)
        let n = SCNVector3(s.normal.x, s.normal.y, s.normal.z)
        for p in tris {
            let w = s.world(p)
            vertices.append(SCNVector3(w.x, w.y, w.z))
            normals.append(n)
            // Texture row 0 is the top of the surface (v = size.y).
            uvs.append(CGPoint(x: CGFloat(p.x / s.size.x), y: CGFloat(1 - p.y / s.size.y)))
        }
        let indices = (0..<UInt32(vertices.count)).map { $0 }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                             SCNGeometrySource(normals: normals),
                                             SCNGeometrySource(textureCoordinates: uvs)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])

        let material = SCNMaterial()
        material.name = s.name
        material.lightingModel = .physicallyBased
        material.roughness.contents = s.kind == .window ? 0.1 : 0.85
        material.metalness.contents = 0.0
        material.isDoubleSided = false
        if let url = baked?.textureURL, FileManager.default.fileExists(atPath: url.path) {
            // A file URL makes SceneKit copy the JPEG into the USDZ as-is (a UIImage gets re-encoded as a ~3x larger PNG).
            material.diffuse.contents = url
        } else {
            let c = baked?.averageColor ?? s.defaultColor
            material.diffuse.contents = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        }
        if s.kind == .window { material.transparency = 0.55 }
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = s.name
        return node
    }

    /// A SceneKit node for one textured piece of the fused mesh.
    private static func node(for part: TextureBaker.MeshPart, name: String) -> SCNNode? {
        guard part.indices.count >= 3 else { return nil }
        let vertices = part.positions.map { SCNVector3($0.x, $0.y, $0.z) }
        let normals = part.normals.map { SCNVector3($0.x, $0.y, $0.z) }
        let uvs = part.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                             SCNGeometrySource(normals: normals),
                                             SCNGeometrySource(textureCoordinates: uvs)],
                                   elements: [SCNGeometryElement(indices: part.indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.name = name
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.8
        material.metalness.contents = 0.0
        if let url = part.textureURL, FileManager.default.fileExists(atPath: url.path) {
            // A file URL makes SceneKit copy the JPEG into the USDZ as-is (a UIImage gets re-encoded as a ~3x larger PNG).
            material.diffuse.contents = url
        } else {
            let c = part.color
            material.diffuse.contents = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        }
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = name
        return node
    }

    /// Bounding box of everything under `root`, in `root`'s coordinates.
    private static func boundingBox(of root: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var found = false
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [a.x, b.x] {
                for y in [a.y, b.y] {
                    for z in [a.z, b.z] {
                        let p = node.convertPosition(SCNVector3(x, y, z), to: root)
                        let v = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
                        lo = simd_min(lo, v)
                        hi = simd_max(hi, v)
                        found = true
                    }
                }
            }
        }
        return found ? (lo, hi) : nil
    }
}
