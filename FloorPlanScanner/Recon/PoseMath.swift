import Foundation
import simd

/// Photometric camera pose refinement, after Zhou & Koltun, "Color Map Optimization for 3D Reconstruction with
/// Consumer Depth Cameras" (SIGGRAPH 2014), rigid version.
///
/// Given surface points with a target brightness (the average over all photos that see them), one Gauss-Newton step
/// moves a camera so its photo agrees better with that target. Repeated over all photos, small tracking errors
/// (typically 1–3 cm on ARKit) shrink, so textures stop ghosting and seams line up.
///
/// ARKit camera convention: camera looks down −Z, +Y up; image u = fx·x/z + cx, v = −fy·y/z + cy with z = −y_cam.z.
/// Pure math, no ARKit: also compiled into the unit tests.
enum PoseMath {
    struct Pinhole {
        var fx: Float, fy: Float, cx: Float, cy: Float
        var width: Float, height: Float
    }

    /// One damped Gauss-Newton step.
    /// - Parameters:
    ///   - worldToCamera: current pose.
    ///   - points/targets: world points and the brightness the photo should show there.
    ///   - sample: brightness and its gradient (per pixel) at an image position, or nil outside the image.
    ///   - gain: brightness scale of this photo (exposure).
    ///   - maxStep: largest translation (m) and rotation (rad) allowed in one step.
    /// - Returns: the improved pose and the RMS residual before the step (nil if too few points).
    static func gaussNewtonStep(worldToCamera: simd_float4x4, points: [SIMD3<Float>], targets: [Float],
                                camera: Pinhole, gain: Float,
                                sample: (Float, Float) -> (value: Float, gradient: SIMD2<Float>)?,
                                damping: Float = 1e-3, maxStep: (Float, Float) = (0.02, 0.02)) -> (simd_float4x4, Float)? {
        var H = [Double](repeating: 0, count: 36)
        var b = [Double](repeating: 0, count: 6)
        var sumSq: Double = 0
        var n = 0
        for (i, p) in points.enumerated() {
            let q4 = worldToCamera * SIMD4(p.x, p.y, p.z, 1)
            let q = SIMD3(q4.x, q4.y, q4.z)
            let z = -q.z
            guard z > 0.1 else { continue }
            let u = camera.fx * q.x / z + camera.cx
            let v = -camera.fy * q.y / z + camera.cy
            guard u > 1, v > 1, u < camera.width - 2, v < camera.height - 2,
                  let s = sample(u, v) else { continue }
            let r = gain * s.value - targets[i]
            // d(u,v)/dq
            let du = SIMD3<Float>(camera.fx / z, 0, camera.fx * q.x / (z * z))
            let dv = SIMD3<Float>(0, -camera.fy / z, -camera.fy * q.y / (z * z))
            let g = gain * (s.gradient.x * du + s.gradient.y * dv)       // dr/dq
            // q' = q + δθ × q + δt  →  dq/dδθ = −[q]×, dq/dδt = I  →  dr/dδθ = q × g.
            let jr = simd_cross(q, g)
            let J: [Double] = [Double(jr.x), Double(jr.y), Double(jr.z), Double(g.x), Double(g.y), Double(g.z)]
            for a in 0..<6 {
                b[a] += J[a] * Double(r)
                for c in a..<6 { H[a * 6 + c] += J[a] * J[c] }
            }
            sumSq += Double(r * r)
            n += 1
        }
        guard n >= 30 else { return nil }
        for a in 0..<6 {
            for c in 0..<a { H[a * 6 + c] = H[c * 6 + a] }
        }
        let trace = (0..<6).reduce(0.0) { $0 + H[$1 * 7] }
        for a in 0..<6 { H[a * 7] += Double(damping) * trace / 6 + 1e-9 }
        guard let delta = solve6(H, b.map { -$0 }) else { return nil }

        var rot = SIMD3<Float>(Float(delta[0]), Float(delta[1]), Float(delta[2]))
        var trans = SIMD3<Float>(Float(delta[3]), Float(delta[4]), Float(delta[5]))
        let ra = simd_length(rot), ta = simd_length(trans)
        if ra > maxStep.1 { rot *= maxStep.1 / ra }
        if ta > maxStep.0 { trans *= maxStep.0 / ta }
        let update = rigid(rotation: rot, translation: trans)
        return (update * worldToCamera, Float((sumSq / Double(n)).squareRoot()))
    }

    /// 4×4 rigid transform from a rotation vector (axis × angle) and a translation.
    static func rigid(rotation w: SIMD3<Float>, translation t: SIMD3<Float>) -> simd_float4x4 {
        let angle = simd_length(w)
        var m = matrix_identity_float4x4
        if angle > 1e-9 {
            let r = simd_float3x3(simd_quatf(angle: angle, axis: w / angle))
            m.columns.0 = SIMD4(r.columns.0, 0)
            m.columns.1 = SIMD4(r.columns.1, 0)
            m.columns.2 = SIMD4(r.columns.2, 0)
        }
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// Solves a symmetric positive definite 6×6 system (row-major) by Cholesky decomposition.
    static func solve6(_ A: [Double], _ b: [Double]) -> [Double]? {
        var L = [Double](repeating: 0, count: 36)
        for i in 0..<6 {
            for j in 0...i {
                var sum = A[i * 6 + j]
                for k in 0..<j { sum -= L[i * 6 + k] * L[j * 6 + k] }
                if i == j {
                    guard sum > 1e-15 else { return nil }
                    L[i * 6 + i] = sum.squareRoot()
                } else {
                    L[i * 6 + j] = sum / L[j * 6 + j]
                }
            }
        }
        var y = [Double](repeating: 0, count: 6)
        for i in 0..<6 {
            var sum = b[i]
            for k in 0..<i { sum -= L[i * 6 + k] * y[k] }
            y[i] = sum / L[i * 6 + i]
        }
        var x = [Double](repeating: 0, count: 6)
        for i in stride(from: 5, through: 0, by: -1) {
            var sum = y[i]
            for k in (i + 1)..<6 { sum -= L[k * 6 + i] * x[k] }
            x[i] = sum / L[i * 6 + i]
        }
        return x
    }

    /// How far a pose moved: translation of the camera centre (m) and rotation angle (degrees).
    static func difference(_ a: simd_float4x4, _ b: simd_float4x4) -> (Float, Float) {
        let ca = a.inverse.columns.3, cb = b.inverse.columns.3
        let dist = simd_distance(SIMD3(ca.x, ca.y, ca.z), SIMD3(cb.x, cb.y, cb.z))
        let rel = a * b.inverse
        let trace = rel.columns.0.x + rel.columns.1.y + rel.columns.2.z
        let angle = acos(min(1, max(-1, (trace - 1) / 2))) * 180 / .pi
        return (dist, angle)
    }
}
