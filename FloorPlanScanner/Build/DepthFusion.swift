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
        for (n, frame) in log.frames.enumerated() {
            if isCancelled() { return nil }
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

        // 3. Hybrid merge: walls, floors and ceilings stay RoomPlan planes.
        progress(0.78, "Straightening walls and floors…")
        let planes = geometry.surfaces.filter { $0.kind == .wall || $0.kind == .floor || $0.kind == .ceiling }
        let boxes: [(simd_float4x4, SIMD3<Float>)] = room.objects
            .filter { cutOut.contains($0.identifier) }
            .map { ($0.transform.inverse, $0.dimensions / 2 + 0.05) }
        func onPlane(_ p: SIMD3<Float>) -> Bool {
            for s in planes {
                let d = simd_dot(p - s.origin, s.normal)
                let tolerance: Float = s.kind == .wall ? 0.07 : 0.045
                guard abs(d) < tolerance else { continue }
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
        let positions = mesh.positions
        planeVertex.withUnsafeMutableBufferPointer { pv in
            cutVertex.withUnsafeMutableBufferPointer { cv in
                DispatchQueue.concurrentPerform(iterations: 64) { chunk in
                    var i = chunk
                    while i < positions.count {
                        pv[i] = onPlane(positions[i])
                        cv[i] = !boxes.isEmpty && inCutOut(positions[i])
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
        mesh.taubinSmooth(iterations: 3)
        if isCancelled() { return nil }
        progress(0.88, "Simplifying the 3D shape…")
        if mesh.triangleCount > targetTriangles {
            mesh = MeshSimplifier.simplify(mesh, targetTriangles: targetTriangles)
        }
        progress(1, "3D shape ready")
        let mb = volume.memoryBytes / 1_048_576
        return Result(mesh: mesh, note: "3D shape fused from \(log.frames.count) LiDAR frames (\(raw.formatted()) → \(mesh.triangleCount.formatted()) triangles, \(mb) MB volume).")
    }
}
