import ARKit
import CoreImage
import UIKit
import simd

/// Watches how well ARKit is tracking and turns it into one simple signal for the user and the recorders.
///
/// Tracking breaks when the phone moves too fast, sees too little detail, or it's too dark. When it breaks, ARKit
/// later "snaps" back (relocalizes) and photos or depth recorded around that moment end up in the wrong place,
/// which shows as doubled or smeared surfaces. So this monitor:
/// - scores quality 0…1 from ARKit's tracking state, mapping status, speed, light and visible detail;
/// - detects pose jumps (a step much larger than the recent speed allows);
/// - only lets recorders record while tracking is good and has been steady for a moment;
/// - keeps a thumbnail of the last well-tracked view so the user can point back at it to recover.
@MainActor
final class TrackingMonitor: ObservableObject {
    enum Level: Equatable { case good, fair, lost }

    enum Reason: Equatable {
        case none, starting, movingFast, turningFast, lowDetail, dark, mapping, relocalizing, jumped

        var message: String? {
            switch self {
            case .none: return nil
            case .starting: return "Move the phone slowly from side to side to get started."
            case .movingFast: return "Slow down: walk more slowly."
            case .turningFast: return "Slow down: turn more gently."
            case .lowDetail: return "Point at something with more detail (furniture, corners, pictures)."
            case .dark: return "It's too dark. Turn on a light."
            case .mapping: return "Keep moving slowly so the phone can learn the room."
            case .relocalizing: return "Tracking lost. Point the phone at the view below and hold still."
            case .jumped: return "Tracking jumped. Hold still for a moment."
            }
        }

        var icon: String {
            switch self {
            case .movingFast, .turningFast: return "tortoise.fill"
            case .lowDetail: return "eye.trianglebadge.exclamationmark"
            case .dark: return "lightbulb.fill"
            case .relocalizing, .jumped: return "location.slash.fill"
            default: return "hand.raised.fill"
            }
        }
    }

    @Published private(set) var level: Level = .lost
    @Published private(set) var reason: Reason = .starting
    /// 0 = still, 1 = at the safe limit, above 1 = too fast.
    @Published private(set) var speedFraction: Float = 0
    /// Last well-tracked view (portrait), shown when tracking is lost.
    @Published private(set) var lastGoodImage: UIImage?
    /// Degrees to turn (positive = right) to face the last good view again; nil when unknown or small.
    @Published private(set) var turnHint: Float?
    /// World positions where tracking was lost or jumped (for the mini-map and coverage map).
    @Published private(set) var lossPositions: [SIMD3<Float>] = []
    /// Where the phone is (x, z) and which way it faces (radians, 0 = −z), for the mini-map.
    @Published private(set) var mapPosition: SIMD2<Float>?
    @Published private(set) var mapHeading: Float = 0

    /// Called when tracking breaks (with the time), so recorders can flag what they recorded just before.
    var onTrackingBreak: ((TimeInterval) -> Void)?

    /// Seconds since tracking last recovered (or jumped).
    private(set) var sinceRecovery: TimeInterval = 0
    /// Recording is allowed only while good and steady for 2 s.
    var canRecord: Bool { level == .good && sinceRecovery > 2 }
    /// 0…1 quality, stored with each recorded frame.
    private(set) var quality: Float = 0

    // Thresholds (same spirit as the recorders' blur limits).
    private let safeWalk: Float = 0.6      // m/s
    private let safeTurn: Float = 50       // °/s

    private var prevPosition: SIMD3<Float>?
    private var prevForward: SIMD3<Float>?
    private var prevTime: TimeInterval?
    private var walkEMA: Float = 0
    private var turnEMA: Float = 0
    private var featureEMA: Float = 200
    private var recoveredAt: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0
    private var wasNormal = false
    private var lastSnapshot: TimeInterval = 0
    private var lastGoodForward: SIMD3<Float>?
    private var lastHaptic = Date.distantPast
    private let context = CIContext()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let warning = UINotificationFeedbackGenerator()

    func reset() {
        level = .lost
        reason = .starting
        prevPosition = nil
        prevTime = nil
        wasNormal = false
        lossPositions = []
        lastGoodImage = nil
        turnHint = nil
    }

    func tick(session: ARSession?) {
        guard let frame = session?.currentFrame, frame.timestamp != lastTimestamp else { return }
        let now = frame.timestamp
        lastTimestamp = now
        let t = frame.camera.transform
        let position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = simd_normalize(-SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))

        var newLevel: Level = .good
        var newReason: Reason = .none
        var jumped = false

        if case .normal = frame.camera.trackingState {
            if !wasNormal { recoveredAt = now }
            wasNormal = true
            // Speed and jumps.
            if let pp = prevPosition, let pf = prevForward, let pt = prevTime, now > pt, now - pt < 0.5 {
                let dt = Float(now - pt)
                let step = simd_distance(pp, position)
                let walk = step / dt
                let turn = FrameRecorder.degrees(between: pf, forward) / dt
                // A step far beyond the recent speed is ARKit snapping to a corrected position.
                if step > max(0.12, walkEMA * dt * 4 + 0.06) {
                    jumped = true
                } else {
                    walkEMA = walkEMA * 0.6 + walk * 0.4
                    turnEMA = turnEMA * 0.6 + turn * 0.4
                }
            }
            let features = Float(frame.rawFeaturePoints?.points.count ?? 0)
            featureEMA = featureEMA * 0.8 + features * 0.2
            let ambient = Float(frame.lightEstimate?.ambientIntensity ?? 1000)

            if jumped {
                newLevel = .lost; newReason = .jumped
                recoveredAt = now
            } else if walkEMA > safeWalk {
                newLevel = .fair; newReason = .movingFast
            } else if turnEMA > safeTurn {
                newLevel = .fair; newReason = .turningFast
            } else if ambient < 200 {
                newLevel = .fair; newReason = .dark
            } else if featureEMA < 40 {
                newLevel = .fair; newReason = .lowDetail
            } else if frame.worldMappingStatus == .notAvailable {
                newLevel = .fair; newReason = .mapping
            }
        } else {
            wasNormal = false
            newLevel = .lost
            switch frame.camera.trackingState {
            case .limited(.excessiveMotion): newReason = .movingFast
            case .limited(.insufficientFeatures): newReason = .lowDetail
            case .limited(.relocalizing): newReason = .relocalizing
            case .limited(.initializing): newReason = .starting
            default: newReason = .relocalizing
            }
        }
        prevPosition = position
        prevForward = forward
        prevTime = now
        mapPosition = SIMD2(position.x, position.z)
        mapHeading = atan2(forward.x, -forward.z)
        sinceRecovery = now - recoveredAt
        speedFraction = max(walkEMA / safeWalk, turnEMA / safeTurn)

        // Quality score for the frame logs.
        var q: Float = newLevel == .good ? 1 : (newLevel == .fair ? 0.5 : 0)
        q *= max(0.2, 1 - max(0, speedFraction - 0.6))
        quality = q

        // Tracking just broke: haptic, remember where, tell the recorders.
        if newLevel == .lost && level != .lost && newReason != .starting {
            lossPositions.append(position)
            onTrackingBreak?(now)
            haptic(strong: true)
        } else if newLevel == .fair && level == .good {
            haptic(strong: false)
        }
        if level != newLevel { level = newLevel }
        if reason != newReason { reason = newReason }

        // Keep a snapshot of the last well-tracked view (about once a second).
        if newLevel == .good && sinceRecovery > 1 {
            lastGoodForward = forward
            turnHint = nil
            if now - lastSnapshot > 1 {
                lastSnapshot = now
                lastGoodImage = snapshot(frame.capturedImage)
            }
        } else if newLevel == .lost, let g = lastGoodForward {
            // Yaw difference on the floor plane; positive = turn right.
            let a = atan2(forward.x, -forward.z), b = atan2(g.x, -g.z)
            var d = (b - a) * 180 / .pi
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            turnHint = abs(d) > 20 ? d : nil
        }
    }

    private func snapshot(_ buffer: CVPixelBuffer) -> UIImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = 320 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .right)   // camera images are landscape
    }

    private func haptic(strong: Bool) {
        guard Date().timeIntervalSince(lastHaptic) > 1.5 else { return }
        lastHaptic = Date()
        if strong { warning.notificationOccurred(.warning) } else { light.impactOccurred() }
    }
}
