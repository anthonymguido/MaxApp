import Foundation
import simd

/// Fits a detailed photogrammetry model into the RoomPlan box of the same piece of furniture.
///
/// Object Capture models are already real size (they're measured with LiDAR), so they're only rescaled
/// if they come out clearly different from the box. The model is turned to whichever 90° step makes its
/// footprint best match the box, plus any extra quarter turns the user asked for, then set on the floor
/// at the box's centre.
enum FurniturePlacer {
    /// - Parameters:
    ///   - modelMin, modelMax: the model's bounding box in its own coordinates (Y up).
    ///   - boxTransform: the RoomPlan object's transform (centre of the box).
    ///   - boxSize: the RoomPlan object's dimensions (x, y, z).
    ///   - quarterTurns: extra rotation chosen by the user.
    /// - Returns: model-to-world transform.
    static func placement(modelMin: SIMD3<Float>, modelMax: SIMD3<Float>,
                          boxTransform: simd_float4x4, boxSize: SIMD3<Float>, quarterTurns: Int) -> simd_float4x4 {
        let m = simd_max(modelMax - modelMin, SIMD3(repeating: 0.001))

        // Footprint match: as-is, or turned 90°.
        let err0 = abs(m.x - boxSize.x) + abs(m.z - boxSize.z)
        let err1 = abs(m.z - boxSize.x) + abs(m.x - boxSize.z)
        let autoTurns = err1 < err0 ? 1 : 0
        let turns = ((autoTurns + quarterTurns) % 4 + 4) % 4
        let angle = Float(turns) * .pi / 2

        // Keep real size unless the height is clearly off (e.g. a model with no scale information).
        let ratio = boxSize.y / m.y
        let scale: Float = (ratio < 0.7 || ratio > 1.4) ? ratio : 1

        // Clean rigid box frame (RoomPlan transforms are rigid, but normalise to be safe).
        let f = SurfaceBuilder.Frame(boxTransform)
        let box = simd_float4x4(SIMD4(f.x, 0), SIMD4(f.y, 0), SIMD4(f.z, 0), SIMD4(f.center, 1))

        let center = (modelMin + modelMax) / 2
        let toOrigin = translation(SIMD3(-center.x, -modelMin.y, -center.z))
        let scaling = simd_float4x4(diagonal: SIMD4(scale, scale, scale, 1))
        let rotation = simd_float4x4(simd_quatf(angle: angle, axis: SIMD3(0, 1, 0)))
        let toFloor = translation(SIMD3(0, -boxSize.y / 2, 0))
        return box * toFloor * rotation * scaling * toOrigin
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}
