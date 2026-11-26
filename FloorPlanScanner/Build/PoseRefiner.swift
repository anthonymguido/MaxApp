import Foundation
import simd

/// Refines every photo's camera pose so the photos agree on the surface colors (Color Map Optimization,
/// Zhou & Koltun 2014, rigid version; see `PoseMath`). ARKit's tracking drifts by a centimetre or two over a
/// scan, which shows up as ghosting and misaligned seams; after this step photos line up on the geometry.
extension TextureBaker {
    /// Grayscale photo, small, for photometric alignment.
    private struct GrayImage {
        var pixels: [Float]
        var width: Int
        var height: Int

        @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
            pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }

        func bilinear(_ u: Float, _ v: Float) -> Float {
            let x = u - 0.5, y = v - 0.5
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let tx = x - Float(x0), ty = y - Float(y0)
            let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
            let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
            return top * (1 - ty) + bottom * ty
        }

        func sample(_ u: Float, _ v: Float) -> (value: Float, gradient: SIMD2<Float>)? {
            guard u > 1, v > 1, u < Float(width) - 2, v < Float(height) - 2 else { return nil }
            let value = bilinear(u, v)
            let gx = (bilinear(u + 1, v) - bilinear(u - 1, v)) / 2
            let gy = (bilinear(u, v + 1) - bilinear(u, v - 1)) / 2
            return (value, SIMD2(gx, gy))
        }
    }

    /// - Returns: a one-line summary for the build note, or nil if nothing was refined.
    func refinePoses(mesh: ReconMesh?, iterations: Int = 5,
                     progress: (Double) -> Void, isCancelled: () -> Bool) -> String? {
        guard cameras.count >= 3 else { return nil }

        // 1. Surface points with normals: mesh vertices plus samples on walls and floors.
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        if let mesh, mesh.triangleCount > 0 {
            let vn = mesh.vertexNormals()
            let stride = max(1, mesh.positions.count / 40_000)
            for i in Swift.stride(from: 0, to: mesh.positions.count, by: stride) {
                points.append(mesh.positions[i])
                normals.append(vn[i])
            }
        }
        let planeSurfaces = surfaces.filter { $0.rendered && ($0.kind == .wall || $0.kind == .floor) }
        var area: Float = 0
        for s in planeSurfaces { area += s.size.x * s.size.y }
        let spacing = max(0.1, (area / 40_000).squareRoot())
        for s in planeSurfaces {
            var v = spacing / 2
            while v < s.size.y {
                var u = spacing / 2
                while u < s.size.x {
                    let lp = SIMD2(u, v)
                    if s.contains(lp) {
                        points.append(s.world(lp))
                        normals.append(s.normal)
                    }
                    u += spacing
                }
                v += spacing
            }
        }
        guard points.count > 200 else { return nil }

        // 2. Occlusion scene and small grayscale photos.
        var scene = mesh ?? ReconMesh()
        for s in surfaces where s.rendered && (s.kind == .wall || s.kind == .floor || s.kind == .ceiling) {
            appendTessellated(s, to: &scene, cell: 0.3)
        }
        var grays = [GrayImage?](repeating: nil, count: cameras.count)
        for ci in cameras.indices {
            if isCancelled() { return nil }
            if let img = image(ci) { grays[ci] = Self.gray(img, longest: 320) }
            if ci % 20 == 0 { progress(0.3 * Double(ci) / Double(cameras.count)) }
        }
        releaseCache()

        // 3. Which points each photo sees (computed once, at the starting poses).
        var visible = [[Int32]](repeating: [], count: cameras.count)
        let camsSnapshot = cameras
        visible.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: camsSnapshot.count) { ci in
                guard grays[ci] != nil else { return }
                let cam = camsSnapshot[ci]
                let zw = 320, zh = 240
                let zbuf = self.depthBuffer(cam, scene: scene, width: zw, height: zh)
                var list: [Int32] = []
                for (i, p) in points.enumerated() {
                    let toCam = cam.position - p
                    let dist = simd_length(toCam)
                    guard dist > 0.2, dist < 5, simd_dot(toCam / dist, normals[i]) > 0.3,
                          let px = self.project(p, cam, margin: 0.03) else { continue }
                    let zx = min(zw - 1, Int(px.x / cam.width * Float(zw)))
                    let zy = min(zh - 1, Int(px.y / cam.height * Float(zh)))
                    if px.z > zbuf[zy * zw + zx] + 0.03 + 0.015 * px.z { continue }
                    list.append(Int32(i))
                }
                out[ci] = list
            }
        }
        progress(0.4)

        // 4. Alternate: target brightness per point (average of photos) ↔ one Gauss-Newton step per photo.
        let start = cameras.map(\.worldToCamera)
        var poses = start
        var camGain = [Float](repeating: 1, count: cameras.count)
        func pinhole(_ ci: Int) -> PoseMath.Pinhole? {
            guard let g = grays[ci] else { return nil }
            let c = cameras[ci]
            let sx = Float(g.width) / c.width, sy = Float(g.height) / c.height
            return PoseMath.Pinhole(fx: c.fx * sx, fy: c.fy * sy, cx: c.cx * sx, cy: c.cy * sy,
                                    width: Float(g.width), height: Float(g.height))
        }
        func observe(_ ci: Int, _ p: SIMD3<Float>, pose: simd_float4x4, cam: PoseMath.Pinhole, gray: GrayImage) -> Float? {
            let q = pose * SIMD4(p.x, p.y, p.z, 1)
            let z = -q.z
            guard z > 0.1 else { return nil }
            return gray.sample(cam.fx * q.x / z + cam.cx, -cam.fy * q.y / z + cam.cy)?.value
        }

        for iteration in 0..<iterations {
            if isCancelled() { return nil }
            // Targets.
            var sum = [Float](repeating: 0, count: points.count)
            var count = [Float](repeating: 0, count: points.count)
            var observed = [[Float?]](repeating: [], count: cameras.count)
            for ci in cameras.indices {
                guard let g = grays[ci], let cam = pinhole(ci) else { continue }
                observed[ci] = visible[ci].map { observe(ci, points[Int($0)], pose: poses[ci], cam: cam, gray: g) }
                for (k, pi) in visible[ci].enumerated() {
                    guard let value = observed[ci][k] else { continue }
                    sum[Int(pi)] += camGain[ci] * value
                    count[Int(pi)] += 1
                }
            }
            var target = [Float](repeating: 0, count: points.count)
            for i in points.indices where count[i] >= 2 { target[i] = sum[i] / count[i] }
            // Exposure gain per photo.
            for ci in cameras.indices {
                var a: Float = 0, b: Float = 0
                for (k, pi) in visible[ci].enumerated() where count[Int(pi)] >= 2 {
                    guard let value = observed[ci][k] else { continue }
                    a += target[Int(pi)]
                    b += value
                }
                if b > 0 { camGain[ci] = min(2, max(0.5, a / b)) }
            }
            // Pose steps, in parallel (each photo independent given the targets).
            let gainsNow = camGain
            var newPoses = poses
            newPoses.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: cameras.count) { ci in
                    guard let g = grays[ci], let cam = pinhole(ci) else { return }
                    let ids = visible[ci].filter { count[Int($0)] >= 2 }
                    guard ids.count >= 30 else { return }
                    let pts = ids.map { points[Int($0)] }
                    let tgt = ids.map { target[Int($0)] }
                    var pose = poses[ci]
                    for _ in 0..<2 {
                        guard let step = PoseMath.gaussNewtonStep(worldToCamera: pose, points: pts, targets: tgt,
                                                                  camera: cam, gain: gainsNow[ci],
                                                                  sample: { g.sample($0, $1) }) else { break }
                        pose = step.0
                    }
                    // Never let a photo wander far from where ARKit put it.
                    let (dist, angle) = PoseMath.difference(pose, start[ci])
                    out[ci] = (dist < 0.08 && angle < 4) ? pose : poses[ci]
                }
            }
            poses = newPoses
            progress(0.4 + 0.6 * Double(iteration + 1) / Double(iterations))
        }

        // 5. Apply.
        var totalDist: Float = 0, totalAngle: Float = 0, moved = 0
        for ci in cameras.indices {
            let (dist, angle) = PoseMath.difference(poses[ci], start[ci])
            if dist > 1e-5 || angle > 1e-4 {
                moved += 1
                totalDist += dist
                totalAngle += angle
            }
            cameras[ci].worldToCamera = poses[ci]
            let inv = poses[ci].inverse
            cameras[ci].position = SIMD3(inv.columns.3.x, inv.columns.3.y, inv.columns.3.z)
        }
        guard moved > 0 else { return nil }
        return String(format: "Photo positions refined for %d photos (average %.1f cm, %.2f°).",
                      moved, totalDist / Float(moved) * 100, totalAngle / Float(moved))
    }

    /// Box-downsampled, lightly blurred luminance.
    private static func gray(_ img: DecodedImage, longest: Int) -> GrayImage {
        let factor = max(1, Int((Float(max(img.width, img.height)) / Float(longest)).rounded(.up)))
        let w = max(1, img.width / factor), h = max(1, img.height / factor)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let o = ((y * factor + dy) * img.width + (x * factor + dx)) * 4
                        let r = Float(img.pixels[o]), g = Float(img.pixels[o + 1]), b = Float(img.pixels[o + 2])
                        s += 0.2126 * r + 0.7152 * g + 0.0722 * b
                    }
                }
                out[y * w + x] = s / Float(factor * factor) / 255
            }
        }
        // 3×3 blur so gradients are smooth enough for Gauss-Newton.
        var blurred = out
        for y in 1..<max(1, h - 1) {
            for x in 1..<max(1, w - 1) {
                var s: Float = 0
                for dy in -1...1 { for dx in -1...1 { s += out[(y + dy) * w + (x + dx)] } }
                blurred[y * w + x] = s / 9
            }
        }
        return GrayImage(pixels: blurred, width: w, height: h)
    }
}
