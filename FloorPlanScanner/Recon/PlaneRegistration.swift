import Foundation
import simd

/// Lines up the fused LiDAR mesh with RoomPlan's walls, floor and ceiling.
///
/// The detail pass relocalizes into the room scan's coordinates, but that can be off by several centimetres
/// (the first real test was 13 cm too high). This finds the translation that best puts mesh surfaces onto the
/// planes they belong to: point-to-plane least squares (as in ICP), using only mesh points whose surface faces
/// the same way as a nearby plane, with the search radius shrinking over a few rounds and outliers down-weighted.
///
/// Pure math, no ARKit: also compiled into the unit tests.
enum PlaneRegistration {
    struct Plane {
        var point: SIMD3<Float>
        var normal: SIMD3<Float>
        /// Is a (projected) point within this plane's extent?
        var contains: (SIMD3<Float>) -> Bool
    }

    struct Result {
        var translation: SIMD3<Float>
        /// Points that matched a plane in the final round.
        var matches: Int
    }

    static func translation(points: [SIMD3<Float>], normals: [SIMD3<Float>], planes: [Plane],
                            radii: [Float] = [0.3, 0.2, 0.12, 0.08, 0.06], maxPoints: Int = 60_000) -> Result {
        guard !points.isEmpty, !planes.isEmpty else { return Result(translation: .zero, matches: 0) }
        let stride = max(1, points.count / maxPoints)
        var t = SIMD3<Float>.zero
        var matches = 0
        for radius in radii {
            var A = simd_double3x3()
            var b = SIMD3<Double>.zero
            matches = 0
            var i = 0
            while i < points.count {
                defer { i += stride }
                let p = points[i] + t
                let n = normals[i]
                var best: (d: Float, normal: SIMD3<Float>)?
                for plane in planes {
                    guard abs(simd_dot(n, plane.normal)) > 0.85 else { continue }
                    let d = simd_dot(p - plane.point, plane.normal)
                    guard abs(d) < radius, abs(d) < abs(best?.d ?? .infinity) else { continue }
                    let onPlane = p - plane.normal * d
                    guard plane.contains(onPlane) else { continue }
                    best = (d, plane.normal)
                }
                guard let best else { continue }
                // Tukey-style weight: points far from the plane (other objects) count less.
                let u = best.d / radius
                let w = Double((1 - u * u) * (1 - u * u))
                let nd = SIMD3<Double>(best.normal)
                A += w * simd_double3x3(rows: [nd * nd.x, nd * nd.y, nd * nd.z])
                b += w * Double(-best.d) * nd
                matches += 1
            }
            guard matches >= 50 else { break }
            // Small regularization keeps directions without any plane (e.g. no wall facing that way) at zero.
            let trace = A[0][0] + A[1][1] + A[2][2]
            let reg = max(1e-9, trace * 1e-3)
            A += simd_double3x3(diagonal: SIMD3(repeating: reg))
            let delta = A.inverse * b
            t += SIMD3<Float>(delta)
        }
        return Result(translation: t, matches: matches)
    }
}
