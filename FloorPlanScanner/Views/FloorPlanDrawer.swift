import RoomPlan
import UIKit
import simd

/// Turns a RoomPlan scan into a clean top-down floor plan image (looking straight down).
enum FloorPlanDrawer {
    static func image(from room: CapturedRoom, maxDimension: CGFloat = 2000) -> UIImage {
        // Everything is projected onto the floor: world x → image x, world z → image y (metres).
        func flat(_ t: simd_float4x4) -> SIMD2<Float> { SIMD2(t.columns.3.x, t.columns.3.z) }
        func axis(_ v: simd_float4) -> SIMD2<Float> {
            let a = SIMD2(v.x, v.z)
            let len = simd_length(a)
            return len > 0.0001 ? a / len : SIMD2(1, 0)
        }
        func segment(_ s: CapturedRoom.Surface) -> (SIMD2<Float>, SIMD2<Float>) {
            let c = flat(s.transform)
            let half = axis(s.transform.columns.0) * (s.dimensions.x / 2)
            return (c - half, c + half)
        }
        func box(_ o: CapturedRoom.Object) -> [SIMD2<Float>] {
            let c = flat(o.transform)
            let ax = axis(o.transform.columns.0) * (o.dimensions.x / 2)
            let az = axis(o.transform.columns.2) * (o.dimensions.z / 2)
            return [c + ax + az, c + ax - az, c - ax - az, c - ax + az]
        }

        let walls = room.walls.map(segment)
        let doors = room.doors.map(segment)
        let windows = room.windows.map(segment)
        let openings = room.openings.map(segment)
        let objects = room.objects.map(box)

        var all: [SIMD2<Float>] = walls.flatMap { [$0.0, $0.1] } + objects.flatMap { $0 }
        all += doors.flatMap { [$0.0, $0.1] } + openings.flatMap { [$0.0, $0.1] }
        guard let first = all.first else { return .blankGrid() }

        var lo = first, hi = first
        for p in all { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let margin: Float = 0.8
        lo -= SIMD2(margin, margin)
        hi += SIMD2(margin, margin)
        let spanM = hi - lo                                   // metres
        let pxPerM = min(maxDimension / CGFloat(max(spanM.x, spanM.y)), 300)
        let size = CGSize(width: max((CGFloat(spanM.x) * pxPerM).rounded(), 400),
                          height: max((CGFloat(spanM.y) * pxPerM).rounded(), 400))

        func pt(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: CGFloat(p.x - lo.x) * pxPerM, y: CGFloat(p.y - lo.y) * pxPerM)
        }

        let wallWidth = max(4, 0.12 * pxPerM)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Faint 1 m grid for orientation.
            cg.setStrokeColor(UIColor(white: 0.93, alpha: 1).cgColor)
            cg.setLineWidth(1)
            var x: CGFloat = 0
            while x <= size.width { cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height)); x += pxPerM }
            var y: CGFloat = 0
            while y <= size.height { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y)); y += pxPerM }
            cg.strokePath()

            // Furniture: light grey boxes.
            cg.setFillColor(UIColor(white: 0.88, alpha: 1).cgColor)
            cg.setStrokeColor(UIColor(white: 0.75, alpha: 1).cgColor)
            cg.setLineWidth(max(1, wallWidth * 0.2))
            for corners in objects {
                cg.beginPath()
                cg.addLines(between: corners.map(pt))
                cg.closePath()
                cg.drawPath(using: .fillStroke)
            }

            func stroke(_ segs: [(SIMD2<Float>, SIMD2<Float>)], color: UIColor, width: CGFloat) {
                guard !segs.isEmpty else { return }
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(width)
                cg.setLineCap(.butt)
                for (a, b) in segs { cg.move(to: pt(a)); cg.addLine(to: pt(b)) }
                cg.strokePath()
            }

            // Walls, then cut gaps for doors/openings, then mark doors and windows.
            cg.setLineJoin(.round)
            stroke(walls, color: UIColor(white: 0.15, alpha: 1), width: wallWidth)
            stroke(doors + openings, color: .white, width: wallWidth + 2)
            stroke(doors, color: .systemBlue, width: max(2, wallWidth * 0.3))
            stroke(windows, color: .systemTeal, width: max(2, wallWidth * 0.45))

            // 1 m scale bar, bottom-left.
            let barY = size.height - pxPerM * 0.35
            let barX = pxPerM * 0.3
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(max(2, wallWidth * 0.3))
            cg.move(to: CGPoint(x: barX, y: barY)); cg.addLine(to: CGPoint(x: barX + pxPerM, y: barY))
            cg.move(to: CGPoint(x: barX, y: barY - 8)); cg.addLine(to: CGPoint(x: barX, y: barY + 8))
            cg.move(to: CGPoint(x: barX + pxPerM, y: barY - 8)); cg.addLine(to: CGPoint(x: barX + pxPerM, y: barY + 8))
            cg.strokePath()
            let label = "1 m" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(14, pxPerM * 0.18), weight: .semibold),
                .foregroundColor: UIColor.black
            ]
            let ls = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: barX + (pxPerM - ls.width) / 2, y: barY - ls.height - 6), withAttributes: attrs)
        }
    }
}

extension UIImage {
    static func blankGrid(size: CGSize = CGSize(width: 1600, height: 1200), spacing: CGFloat = 50) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.setLineWidth(1)
            var i = 0
            var x: CGFloat = 0
            while x <= size.width {
                cg.setStrokeColor((i % 4 == 0 ? UIColor.systemGray3 : UIColor.systemGray5).cgColor)
                cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height)); cg.strokePath()
                x += spacing; i += 1
            }
            i = 0
            var y: CGFloat = 0
            while y <= size.height {
                cg.setStrokeColor((i % 4 == 0 ? UIColor.systemGray3 : UIColor.systemGray5).cgColor)
                cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y)); cg.strokePath()
                y += spacing; i += 1
            }
        }
    }
}
