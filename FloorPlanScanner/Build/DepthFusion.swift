import Foundation
import RoomPlan
import simd

/// Turns the detail pass's LiDAR depth frames into a clean triangle mesh of everything that isn't a plain wall or
/// floor: furniture, the TV, plants, objects on shelves.
///
/// depth frames → TSDF fusion (2 cm voxels) → surface nets → hybrid merge (drop what lies on RoomPlan's walls,
/// floors and ceilings, which stay as perfect planes) → remove floating noise → Taubin smoothing → QEM simplification.
enum DepthFusion {
    struct Result {
        var mesh: ReconMesh
        var note: String
        /// Shift applied to line the detail pass up with the room scan; detail-pass photos need the same shift.
        var offset: SIMD3<Float>
        /// Where tracking was lost during the detail pass (world, already shifted by `offset`).
        var lossPositions: [SIMD3<Float>] = []
    }

    static func reconstruct(logURL: URL, frameDir: URL, geometry: SurfaceBuilder.Result, room: CapturedRoom,
                            cutOut: Set<UUID>, targetTriangles: Int = 350_000,
                            progress: (Double, String) -> Void, isCancelled: () -> Bool) -> Result? {
        guard let data = try? Data(contentsOf: logURL),
              let log = try? JSONDecoder().decode(DepthFrameLog.self, from: data),
              log.frames.count >= 30 else { return nil }

        // Only fuse inside the house (window views and mirrors otherwise add phantom geometry).
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for s in geometry.surfaces where s.kind == .wall || s.kind == .floor {
            for p in [SIMD2<Float>(0, 0), SIMD2(s.size.x, 0), SIMD2(0, s.size.y), s.size] {
                lo = simd_min(lo, s.world(p))
                hi = simd_max(hi, s.world(p))
            }
        }
        guard lo.x < hi.x else { return nil }
        lo -= SIMD3(0.2, 0.15, 0.2)
        hi += SIMD3(0.2, 0.15, 0.2)

        // 1. Fuse.
        let volume = TSDFVolume(voxelSize: 0.02, truncationVoxels: 3)
        var skippedSuspect = 0, skippedDrift = 0, fusedCount = 0
        for (n, frame) in log.frames.enumerated() {
            if isCancelled() { return nil }
            // Recorded just before tracking broke: its position may be off.
            if frame.suspect == true { skippedSuspect += 1; continue }
            guard frame.transform.count == 16, frame.intrinsics.count == 4,
                  let raw = try? Data(contentsOf: frameDir.appendingPathComponent(frame.depth)),
                  raw.count == frame.width * frame.height * 2 else { continue }
            let depth: [UInt16] = raw.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            var confidence: [UInt8]?
            if let name = frame.confidence, let c = try? Data(contentsOf: frameDir.appendingPathComponent(name)),
               c.count == frame.width * frame.height {
                confidence = [UInt8](c)
            }
            let t = frame.transform
            let pose = simd_float4x4(SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                                     SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15]))
            let cam = TSDFVolume.DepthCamera(fx: frame.intrinsics[0], fy: frame.intrinsics[1],
                                             cx: frame.intrinsics[2], cy: frame.intrinsics[3], cameraToWorld: pose)
            // Drift check: a frame that disagrees with what's already fused would add a ghost copy.
            if fusedCount >= 20 {
                let check = volume.agreement(depthMM: depth, confidence: confidence, width: frame.width,
                                             height: frame.height, camera: cam, minConfidence: confidence == nil ? 0 : 2)
                if check.checked >= 80 && Float(check.agreeing) / Float(check.checked) < 0.45 {
                    skippedDrift += 1
                    continue
                }
            }
            fusedCount += 1
            volume.integrate(depthMM: depth, confidence: confidence, width: frame.width, height: frame.height,
                             camera: cam, stride: 2, minConfidence: confidence == nil ? 0 : 2, bounds: (lo, hi))
            if n % 20 == 0 {
                progress(Double(n) / Double(log.frames.count) * 0.7, "Fusing LiDAR depth \(n + 1) of \(log.frames.count)…")
            }
        }

        // 2. Surface.
        progress(0.72, "Building the 3D shape…")
        var mesh = volume.extractSurface()
        let raw = mesh.triangleCount
        guard raw > 0 else { return nil }
        if isCancelled() { return nil }

        // 3. Line the mesh up with RoomPlan's walls and floor (the detail pass can relocalize a few cm off).
        progress(0.76, "Lining the 3D shape up with the room…")
        let planes = geometry.surfaces.filter { $0.kind == .wall || $0.kind == .floor || $0.kind == .ceiling }
        mesh.taubinSmooth(iterations: 2)   // steadier normals for the plane tests
        // Vertical only: the floor (and ceiling) pin the height. In the first real test the walls already lined up,
        // and RoomPlan's wall centre lines aren't exact enough to pull the mesh sideways.
        let registrationPlanes: [PlaneRegistration.Plane] = planes.filter { $0.kind != .wall }.map { s in
            PlaneRegistration.Plane(point: s.origin, normal: s.normal, contains: { p in
                let lp = s.local(p)
                guard lp.x > -0.05, lp.y > -0.05, lp.x < s.size.x + 0.05, lp.y < s.size.y + 0.05 else { return false }
                if let poly = s.polygon { return Geometry2D.pointInPolygon(lp, poly) }
                return true
            })
        }
        let registration = PlaneRegistration.translation(points: mesh.positions, normals: mesh.vertexNormals(),
                                                         planes: registrationPlanes)
        var offset = SIMD3<Float>(0, registration.translation.y, 0)
        if abs(offset.y) > 0.4 || abs(offset.y) < 0.005 { offset = .zero }   // implausible or negligible
        if offset != .zero {
            for i in mesh.positions.indices { mesh.positions[i] += offset }
        }

        // 4. Hybrid merge: walls, floors and ceilings stay RoomPlan planes.
        progress(0.78, "Straightening walls and floors…")
        let boxes: [(simd_float4x4, SIMD3<Float>)] = room.objects
            .filter { cutOut.contains($0.identifier) }
            .map { ($0.transform.inverse, $0.dimensions / 2 + 0.05) }
        // A vertex belongs to a plane if it's close to it AND its surface faces the same way, so furniture
        // standing against a wall or on the floor is kept (its sides and top face other directions or sit further out).
        func onPlane(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> Bool {
            for s in planes {
                let d = simd_dot(p - s.origin, s.normal)
                let aligned = abs(simd_dot(n, s.normal))
                switch s.kind {
                case .wall:
                    guard abs(d) < 0.08, aligned > 0.8 else { continue }
                case .floor:
                    guard d > -0.05, d < 0.06, aligned > 0.85 else { continue }
                default:   // ceiling
                    guard abs(d) < 0.08, aligned > 0.85 else { continue }
                }
                let lp = s.local(p)
                if lp.x > -0.1, lp.y > -0.1, lp.x < s.size.x + 0.1, lp.y < s.size.y + 0.1 {
                    if let poly = s.polygon, !Geometry2D.pointInPolygon(lp, poly) { continue }
                    return true
                }
            }
            return false
        }
        func inCutOut(_ p: SIMD3<Float>) -> Bool {
            for (inv, half) in boxes {
                let l = inv * SIMD4(p.x, p.y, p.z, 1)
                if abs(l.x) < half.x && abs(l.y) < half.y && abs(l.z) < half.z { return true }
            }
            return false
        }
        var planeVertex = [Bool](repeating: false, count: mesh.positions.count)
        var cutVertex = [Bool](repeating: false, count: mesh.positions.count)
        // Anything outside the rooms' floor outlines (seen through doorways and windows) is dropped too.
        let floors = geometry.surfaces.filter { $0.kind == .floor && $0.polygon != nil }
        func outsideRooms(_ p: SIMD3<Float>) -> Bool {
            guard !floors.isEmpty else { return false }
            for s in floors {
                let lp = s.local(p)
                if let poly = s.polygon, Geometry2D.distanceToPolygon(lp, poly) < 0.15 { return false }
            }
            return true
        }
        let positions = mesh.positions
        let vertexNormals = mesh.vertexNormals()
        planeVertex.withUnsafeMutableBufferPointer { pv in
            cutVertex.withUnsafeMutableBufferPointer { cv in
                DispatchQueue.concurrentPerform(iterations: 64) { chunk in
                    var i = chunk
                    while i < positions.count {
                        pv[i] = onPlane(positions[i], vertexNormals[i])
                        cv[i] = (!boxes.isEmpty && inCutOut(positions[i])) || outsideRooms(positions[i])
                        i += 64
                    }
                }
            }
        }
        let keep: [Bool] = (0..<mesh.triangleCount).map { t in
            let (a, b, c) = mesh.triangle(t)
            if cutVertex[a] || cutVertex[b] || cutVertex[c] { return false }
            return !(planeVertex[a] && planeVertex[b] && planeVertex[c])
        }
        mesh.filterTriangles { keep[$0] }

        // 4. Clean up and simplify.
        progress(0.84, "Cleaning up the 3D shape…")
        mesh.removeSmallComponents(minTriangles: 400)
        guard mesh.triangleCount > 0 else { return nil }
        mesh.taubinSmooth(iterations: 1)
        if isCancelled() { return nil }
        progress(0.88, "Simplifying the 3D shape…")
        if mesh.triangleCount > targetTriangles {
            mesh = MeshSimplifier.simplify(mesh, targetTriangles: targetTriangles)
        }
        progress(1, "3D shape ready")
        let mb = volume.memoryBytes / 1_048_576
        var note = "3D shape fused from \(fusedCount) of \(log.frames.count) LiDAR frames (\(raw.formatted()) → \(mesh.triangleCount.formatted()) triangles, \(mb) MB volume)."
        if offset != .zero {
            note += String(format: " Detail pass lined up with the room scan (moved %.0f cm: %.0f / %.0f / %.0f).",
                           simd_length(offset) * 100, offset.x * 100, offset.y * 100, offset.z * 100)
        }
        if skippedSuspect + skippedDrift > 0 {
            note += " Skipped for tracking problems: \(skippedSuspect) flagged while scanning, \(skippedDrift) that didn't line up."
        }
        return Result(mesh: mesh, note: note, offset: offset, lossPositions: (log.losses ?? []).compactMap {
            $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) + offset : nil
        })
    }
}
