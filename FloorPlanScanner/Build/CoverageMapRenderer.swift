import UIKit
import simd

/// Draws a top-down "what was captured" map after a build, saved next to the model as coverage.jpg:
/// - floor: green where a photo saw it, red where nothing did;
/// - walls: coloured by how much of them the photos covered;
/// - red dots: parts of the 3D shape no photo saw;
/// - grey dots: where photos were taken;
/// - red ✕: where tracking was lost while scanning.
enum CoverageMapRenderer {
    struct Input {
        var surfaces: [PlanarSurface]
        var baked: [Int: TextureBaker.BakedSurface]
        var cellSize: Float
        var unseenMeshPoints: [SIMD3<Float>]
        var photoPositions: [SIMD3<Float>]
        var lossPositions: [SIMD3<Float>]
    }

    static func render(_ input: Input, to url: URL, maxDimension: CGFloat = 1400) -> Bool {
        // Bounds of everything on the floor plane (x, z).
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        func include(_ p: SIMD3<Float>) {
            lo = simd_min(lo, SIMD2(p.x, p.z))
            hi = simd_max(hi, SIMD2(p.x, p.z))
        }
        for s in input.surfaces where s.kind == .wall || s.kind == .floor {
            for c in [SIMD2<Float>(0, 0), SIMD2(s.size.x, 0), SIMD2(0, s.size.y), s.size] { include(s.world(c)) }
        }
        guard lo.x < hi.x, lo.y < hi.y else { return false }
        lo -= 0.6
        hi += 0.6
        let span = hi - lo
        let pxPerM = min(maxDimension / CGFloat(max(span.x, span.y)), 220)
        let legendHeight: CGFloat = 70
        let size = CGSize(width: max(400, CGFloat(span.x) * pxPerM),
                          height: max(400, CGFloat(span.y) * pxPerM) + legendHeight)
        func pt(_ p: SIMD3<Float>) -> CGPoint {
            CGPoint(x: CGFloat(p.x - lo.x) * pxPerM, y: CGFloat(p.z - lo.y) * pxPerM)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Floors, cell by cell.
            for (si, s) in input.surfaces.enumerated() where s.kind == .floor {
                guard let b = input.baked[si], b.cellGrid.nu > 0 else { continue }
                let (nu, nv) = b.cellGrid
                for j in 0..<nv {
                    for i in 0..<nu {
                        let state = b.cellSeen[j * nu + i]
                        guard state > 0 else { continue }
                        let corners = [SIMD2<Float>(Float(i), Float(j)), SIMD2(Float(i + 1), Float(j)),
                                       SIMD2(Float(i + 1), Float(j + 1)), SIMD2(Float(i), Float(j + 1))]
                            .map { pt(s.world(simd_min($0 * input.cellSize, s.size))) }
                        cg.setFillColor((state == 2 ? UIColor(red: 0.62, green: 0.86, blue: 0.62, alpha: 1)
                                                    : UIColor(red: 0.95, green: 0.55, blue: 0.52, alpha: 1)).cgColor)
                        cg.beginPath()
                        cg.addLines(between: corners)
                        cg.closePath()
                        cg.fillPath()
                    }
                }
            }

            // Walls: one line per wall, coloured by the better-covered side.
            var wallCoverage: [Int: (SIMD3<Float>, SIMD3<Float>, Float)] = [:]
            for (si, s) in input.surfaces.enumerated() where s.kind == .wall {
                let a = s.world(SIMD2(0, 0)), b = s.world(SIMD2(s.size.x, 0))
                let cov = input.baked[si]?.coverage ?? 0
                if let existing = wallCoverage[s.group], existing.2 >= cov { continue }
                wallCoverage[s.group] = (a, b, cov)
            }
            cg.setLineCap(.round)
            cg.setLineWidth(max(5, 0.12 * pxPerM))
            for (_, (a, b, cov)) in wallCoverage {
                let color: UIColor = cov > 0.6 ? UIColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1)
                    : (cov > 0.3 ? .systemOrange : .systemRed)
                cg.setStrokeColor(color.cgColor)
                cg.move(to: pt(a))
                cg.addLine(to: pt(b))
                cg.strokePath()
            }

            // Photo positions.
            cg.setFillColor(UIColor(white: 0.45, alpha: 0.6).cgColor)
            for p in input.photoPositions {
                let c = pt(p)
                cg.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
            }

            // 3D-shape parts no photo saw.
            cg.setFillColor(UIColor.systemRed.withAlphaComponent(0.55).cgColor)
            for p in input.unseenMeshPoints {
                let c = pt(p)
                cg.fillEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            }

            // Tracking losses.
            for p in input.lossPositions {
                let c = pt(p)
                for (color, width) in [(UIColor.white, CGFloat(7)), (UIColor.systemRed, CGFloat(4))] {
                    cg.setStrokeColor(color.cgColor)
                    cg.setLineWidth(width)
                    cg.move(to: CGPoint(x: c.x - 8, y: c.y - 8)); cg.addLine(to: CGPoint(x: c.x + 8, y: c.y + 8))
                    cg.move(to: CGPoint(x: c.x + 8, y: c.y - 8)); cg.addLine(to: CGPoint(x: c.x - 8, y: c.y + 8))
                    cg.strokePath()
                }
            }

            // Legend.
            let top = size.height - legendHeight + 12
            let items: [(UIColor, String)] = [
                (UIColor(red: 0.62, green: 0.86, blue: 0.62, alpha: 1), "Photographed"),
                (UIColor(red: 0.95, green: 0.55, blue: 0.52, alpha: 1), "Not photographed"),
                (.systemRed, "✕ Tracking lost"),
                (UIColor(white: 0.45, alpha: 1), "• Photo taken"),
            ]
            var x: CGFloat = 16
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .medium),
                                                        .foregroundColor: UIColor.black]
            for (color, text) in items {
                color.setFill()
                ctx.fill(CGRect(x: x, y: top + 6, width: 22, height: 22))
                (text as NSString).draw(at: CGPoint(x: x + 30, y: top + 2), withAttributes: attrs)
                x += 40 + (text as NSString).size(withAttributes: attrs).width + 24
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
