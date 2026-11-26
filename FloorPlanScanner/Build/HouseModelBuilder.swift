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
        progress(0, "Reading the scan…")
        let room: CapturedRoom
        do {
            room = try JSONDecoder().decode(CapturedRoom.self, from: Data(contentsOf: input.roomURL))
        } catch {
            throw BuildError.noRoom(error.localizedDescription)
        }
        let frames: [Keyframe]
        if let data = try? Data(contentsOf: input.frameLogURL),
           let log = try? JSONDecoder().decode(KeyframeLog.self, from: data) {
            frames = log.frames
        } else {
            frames = []
        }

        // 1. Geometry.
        let usable = input.details.filter { fm.fileExists(atPath: $0.modelURL.path) }
        var options = SurfaceBuilder.Options()
        options.includeCeilings = input.includeCeilings
        options.replacedObjects = Set(usable.map(\.objectID))
        let geometry = SurfaceBuilder.build(room, options: options)

        // 2. Choose photos for each spot and balance their brightness.
        try? fm.removeItem(at: input.texturesDir)
        try fm.createDirectory(at: input.texturesDir, withIntermediateDirectories: true)
        let baker = TextureBaker(surfaces: geometry.surfaces, frames: frames,
                                 framesDir: input.framesDir, depthDir: input.depthDir)
        progress(0.02, "Matching \(baker.photoCount) photos to walls and floors…")
        baker.prepare(progress: { progress(0.02 + 0.28 * $0, "Matching \(baker.photoCount) photos to walls and floors…") },
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
            progress(0.3 + 0.6 * Double(n) / Double(max(1, drawn.count)),
                     "Painting \(label(s.kind)) \(n + 1) of \(drawn.count)…")
            let result = baker.bake(surfaceIndex: si, to: input.texturesDir, isCancelled: isCancelled)
            baked[si] = result
            if s.kind == .wall || s.kind == .floor {
                coverageSum += result.coverage
                coverageCount += 1
            }
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

        for si in drawn {
            let s = geometry.surfaces[si]
            guard let node = node(for: s, baked: baked[si]) else { continue }
            (s.kind == .furniture ? furniture : structure).addChildNode(node)
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

        // 6. Write the USDZ.
        progress(0.96, "Saving the 3D model…")
        try? fm.removeItem(at: input.outputURL)
        let ok = scene.write(to: input.outputURL, options: nil, delegate: nil, progressHandler: nil)
        guard ok, fm.fileExists(atPath: input.outputURL.path) else { throw BuildError.writeFailed }
        progress(1, "Done")

        var lines: [String] = []
        let pct = coverageCount > 0 ? Int((coverageSum / coverageCount * 100).rounded()) : 0
        if frames.isEmpty {
            lines.append("No photos were recorded during the scan, so walls and floors have plain colors.")
        } else {
            lines.append("Built from \(baker.photoCount) photos. Photos covered about \(pct)% of the walls and floors; the rest is filled with nearby colors.")
        }
        if !usable.isEmpty {
            lines.append("\(placed) detailed piece\(placed == 1 ? "" : "s") of furniture placed.")
        }
        if pct > 0 && pct < 60 {
            lines.append("Tip: for fuller textures, scan again more slowly and point the phone at every wall and the floor.")
        }
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
        if let url = baked?.textureURL, let image = UIImage(contentsOfFile: url.path) {
            material.diffuse.contents = image
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
