import Foundation
import simd

/// The person holding the phone is in many photos, especially their feet when the phone tilts down to the floor.
/// The scan geometry doesn't know they're there, so without this rule their shoes get painted onto the carpet.
///
/// Rule: a point near the floor that lies almost straight below where the phone was, is assumed to be covered by
/// the user's feet or legs in that photo, and that photo isn't used for it. Pure math, also in the unit tests.
enum PersonMask {
    /// - Parameters:
    ///   - radius: horizontal distance from the phone (metres) treated as "where you're standing".
    ///   - height: only points this close to the floor (metres) are affected.
    static func hides(_ point: SIMD3<Float>, cameraPosition c: SIMD3<Float>, floorY: Float,
                      radius: Float = 0.55, height: Float = 0.4) -> Bool {
        guard point.y - floorY < height else { return false }
        let dx = point.x - c.x, dz = point.z - c.z
        return dx * dx + dz * dz < radius * radius
    }
}
