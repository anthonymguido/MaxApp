import SwiftUI
import simd

/// Tracking feedback drawn over a camera view: a coloured edge glow, a speed gauge, an instruction,
/// and — when tracking is lost — the last good view to point back at.
struct TrackingHUD: View {
    @ObservedObject var monitor: TrackingMonitor
    /// The room scan has its own coaching text; the detail pass shows the monitor's message.
    var showsMessage = true

    private var color: Color {
        switch monitor.level {
        case .good: return .green
        case .fair: return .orange
        case .lost: return .red
        }
    }

    var body: some View {
        ZStack {
            // Edge glow.
            RoundedRectangle(cornerRadius: 44)
                .strokeBorder(color.opacity(monitor.level == .good ? 0.35 : 0.85), lineWidth: monitor.level == .good ? 4 : 10)
                .blur(radius: 3)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.3), value: monitor.level)

            HStack {
                Spacer()
                SpeedGauge(fraction: monitor.speedFraction)
                    .frame(width: 10, height: 140)
                    .padding(.trailing, 6)
            }

            VStack(spacing: 10) {
                Spacer().frame(height: 70)
                if showsMessage, monitor.level != .good, let message = monitor.reason.message {
                    Label(message, systemImage: monitor.reason.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(color.opacity(0.85), in: Capsule())
                        .padding(.horizontal)
                        .transition(.opacity)
                }
                if monitor.level == .lost, monitor.reason != .starting, let image = monitor.lastGoodImage {
                    RecoveryCard(image: image, turnHint: monitor.turnHint)
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.25), value: monitor.reason)
        }
        .allowsHitTesting(false)
    }
}

/// Vertical bar that fills with speed; the top band is "too fast".
struct SpeedGauge: View {
    var fraction: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let filled = CGFloat(min(1.3, max(0, fraction))) / 1.3 * h
            ZStack(alignment: .bottom) {
                Capsule().fill(.black.opacity(0.4))
                Rectangle().fill(.red.opacity(0.35)).frame(height: h * (0.3 / 1.3)).frame(maxHeight: .infinity, alignment: .top)
                Capsule().fill(fraction > 1 ? Color.red : (fraction > 0.75 ? .orange : .green))
                    .frame(height: max(4, filled))
            }
            .clipShape(Capsule())
        }
        .accessibilityLabel(fraction > 1 ? "Moving too fast" : "Speed OK")
    }
}

/// "Point the phone at this": the last well-tracked view, plus which way to turn.
struct RecoveryCard: View {
    let image: UIImage
    var turnHint: Float?

    var body: some View {
        VStack(spacing: 8) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 160, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2))
            HStack(spacing: 6) {
                if let turnHint {
                    Image(systemName: turnHint > 0 ? "arrow.turn.up.right" : "arrow.turn.up.left")
                    Text("Turn \(turnHint > 0 ? "right" : "left") about \(Int(abs(turnHint)))°")
                } else {
                    Image(systemName: "viewfinder")
                    Text("Point the phone at this view")
                }
            }
            .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Small top-down map of the scan: where photos were taken, where tracking was lost, and where you are.
struct ScanMiniMap: View {
    var photoPositions: [SIMD2<Float>]
    var lossPositions: [SIMD2<Float>]
    var current: SIMD2<Float>?
    var heading: Float?   // radians, 0 = −z

    var body: some View {
        Canvas { ctx, size in
            let all = photoPositions + lossPositions + (current.map { [$0] } ?? [])
            guard !all.isEmpty else { return }
            var lo = all[0], hi = all[0]
            for p in all { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            let span = max(hi.x - lo.x, hi.y - lo.y, 2)
            let scale = Float(min(size.width, size.height) - 16) / span
            let mid = (lo + hi) / 2
            func pt(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: size.width / 2 + CGFloat((p.x - mid.x) * scale), y: size.height / 2 + CGFloat((p.y - mid.y) * scale))
            }
            for p in photoPositions {
                let c = pt(p)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(.green))
            }
            for p in lossPositions {
                let c = pt(p)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.red))
            }
            if let current {
                let c = pt(current)
                var arrow = Path()
                let h = CGFloat(heading ?? 0)
                let tip = CGPoint(x: c.x + 9 * sin(h), y: c.y - 9 * cos(h))
                let left = CGPoint(x: c.x + 5 * sin(h - 2.5), y: c.y - 5 * cos(h - 2.5))
                let right = CGPoint(x: c.x + 5 * sin(h + 2.5), y: c.y - 5 * cos(h + 2.5))
                arrow.move(to: tip); arrow.addLine(to: left); arrow.addLine(to: right); arrow.closeSubpath()
                ctx.fill(arrow, with: .color(.white))
            }
        }
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Map of photos taken (green) and places tracking was lost (red)")
    }
}
