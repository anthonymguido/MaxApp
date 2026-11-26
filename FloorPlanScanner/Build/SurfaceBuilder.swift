import Foundation
import RoomPlan
import simd

/// An axis-aligned rectangle in a surface's local 2D coordinates (metres).
struct Rect2: Hashable {
    var minU: Float, minV: Float, maxU: Float, maxV: Float

    func contains(_ p: SIMD2<Float>) -> Bool {
        p.x > minU && p.x < maxU && p.y > minV && p.y < maxV
    }
}

/// A flat piece of the house (one side of a wall, a floor, a furniture face…) with its own 2D frame:
/// world = origin + right·u + up·v, for u in 0…size.x and v in 0…size.y. `normal` = right × up and
/// points to the side the surface is seen from.
struct PlanarSurface {
    enum Kind: String { case wall, floor, ceiling, window, furniture }

    var name: String
    var kind: Kind
    /// Surfaces in the same group never block each other's view (two sides of a wall, faces of one box).
    var group: Int
    var origin: SIMD3<Float>
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var normal: SIMD3<Float>
    var size: SIMD2<Float>
    /// Outline for floors and ceilings (counter-clockwise, local coordinates). nil = the full rectangle.
    var polygon: [SIMD2<Float>]?
    var holes: [Rect2] = []
    /// Blocks the camera's view of surfaces behind it.
    var occludes: Bool
    /// Drawn in the model (false for furniture boxes replaced by a detailed model: they still block views).
    var rendered: Bool = true
    /// Color used where no photo saw the surface (linear 0…1 RGB).
    var defaultColor: SIMD3<Float>

    func world(_ p: SIMD2<Float>) -> SIMD3<Float> { origin + right * p.x + up * p.y }

    func local(_ w: SIMD3<Float>) -> SIMD2<Float> {
        let d = w - origin
        return SIMD2(simd_dot(d, right), simd_dot(d, up))
    }

    /// Is this local point part of the surface (inside the outline and not in a hole)?
    func contains(_ p: SIMD2<Float>) -> Bool {
        guard p.x >= 0, p.y >= 0, p.x <= size.x, p.y <= size.y else { return false }
        for h in holes where h.contains(p) { return false }
        if let polygon { return Geometry2D.pointInPolygon(p, polygon) }
        return true
    }

    var center: SIMD3<Float> { world(size / 2) }

    /// Triangles in local coordinates, counter-clockwise seen from the normal side.
    func triangles() -> [SIMD2<Float>] {
        if let polygon { return Geometry2D.earClip(polygon) }
        return Geometry2D.rectWithHoles(size: size, holes: holes)
    }
}

enum Geometry2D {
    static func signedArea(_ poly: [SIMD2<Float>]) -> Float {
        var a: Float = 0
        for i in poly.indices {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    static func pointInPolygon(_ p: SIMD2<Float>, _ poly: [SIMD2<Float>]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Ear-clipping triangulation of a simple counter-clockwise polygon.
    static func earClip(_ polygon: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var poly = polygon
        if signedArea(poly) < 0 { poly.reverse() }
        var idx = Array(poly.indices)
        var out: [SIMD2<Float>] = []
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func inTriangle(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
        }
        var guardCount = 0
        while idx.count > 3, guardCount < 10_000 {
            guardCount += 1
            var clipped = false
            for k in idx.indices {
                let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = poly[i0], b = poly[i1], c = poly[i2]
                guard cross(a, b, c) > 1e-7 else { continue }   // reflex or degenerate
                var blocked = false
                for j in idx where j != i0 && j != i1 && j != i2 {
                    if inTriangle(poly[j], a, b, c) { blocked = true; break }
                }
                if blocked { continue }
                out += [a, b, c]
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped {
                // Self-touching outline: fall back to a fan for what's left.
                for k in 1..<(idx.count - 1) { out += [poly[idx[0]], poly[idx[k]], poly[idx[k + 1]]] }
                return out
            }
        }
        if idx.count == 3 { out += [poly[idx[0]], poly[idx[1]], poly[idx[2]]] }
        return out
    }

    /// A rectangle 0…size with rectangular holes, split into a grid on the hole edges.
    static func rectWithHoles(size: SIMD2<Float>, holes: [Rect2]) -> [SIMD2<Float>] {
        var us: [Float] = [0, size.x]
        var vs: [Float] = [0, size.y]
        for h in holes {
            us += [h.minU, h.maxU].map { min(max($0, 0), size.x) }
            vs += [h.minV, h.maxV].map { min(max($0, 0), size.y) }
        }
        us = Array(Set(us)).sorted()
        vs = Array(Set(vs)).sorted()
        var out: [SIMD2<Float>] = []
        for i in 0..<(us.count - 1) {
            for j in 0..<(vs.count - 1) {
                let u0 = us[i], u1 = us[i + 1], v0 = vs[j], v1 = vs[j + 1]
                guard u1 - u0 > 1e-4, v1 - v0 > 1e-4 else { continue }
                let mid = SIMD2((u0 + u1) / 2, (v0 + v1) / 2)
                if holes.contains(where: { $0.contains(mid) }) { continue }
                out += [SIMD2(u0, v0), SIMD2(u1, v0), SIMD2(u1, v1),
                        SIMD2(u0, v0), SIMD2(u1, v1), SIMD2(u0, v1)]
            }
        }
        return out
    }

    /// Convex hull (monotone chain), counter-clockwise.
    static func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let pts = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count > 2 else { return pts }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Float>] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

/// Turns a RoomPlan result into planar surfaces ready for texturing.
enum SurfaceBuilder {
    struct Options {
        var includeCeilings = false
        /// RoomPlan objects that will be replaced by a detailed model (their box is not drawn).
        var replacedObjects: Set<UUID> = []
    }

    struct Result {
        var surfaces: [PlanarSurface]
        var floorY: Float
        var ceilingY: Float
        /// Centre of the house footprint (x, z), used to centre the model.
        var center: SIMD2<Float>
    }

    // Default colors for surfaces no photo saw.
    static let wallColor = SIMD3<Float>(0.86, 0.84, 0.80)
    static let floorColor = SIMD3<Float>(0.62, 0.53, 0.42)
    static let ceilingColor = SIMD3<Float>(0.93, 0.93, 0.92)
    static let windowColor = SIMD3<Float>(0.70, 0.82, 0.90)
    static let furnitureColor = SIMD3<Float>(0.70, 0.70, 0.72)

    static func build(_ room: CapturedRoom, options: Options) -> Result {
        var surfaces: [PlanarSurface] = []
        var group = 0

        let walls = room.walls
        let cutouts = room.doors + room.openings + room.windows
        var footprint: [SIMD2<Float>] = []
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude

        // Walls: both sides, with holes for doors, openings and windows.
        for (wi, wall) in walls.enumerated() {
            let f = Frame(wall.transform)
            let w = wall.dimensions.x, h = wall.dimensions.y
            guard w > 0.05, h > 0.05 else { continue }
            let half = max(0.04, wall.dimensions.z / 2)
            lowest = min(lowest, f.center.y - h / 2)
            highest = max(highest, f.center.y + h / 2)
            footprint.append(SIMD2(f.center.x - f.x.x * w / 2, f.center.z - f.x.z * w / 2))
            footprint.append(SIMD2(f.center.x + f.x.x * w / 2, f.center.z + f.x.z * w / 2))

            let sideCuts = cutouts.filter { onWall($0, wall: f, width: w) }
            for (si, side) in [Float(1), -1].enumerated() {
                let normal = f.z * side
                var s = rect(name: "wall\(wi)_\(si == 0 ? "a" : "b")", kind: .wall, group: group,
                             center: f.center + normal * half, normal: normal, up: f.y,
                             width: w, height: h, occludes: true, color: wallColor)
                let wallSide = s
                let holes = sideCuts.compactMap { cut in hole(for: cut, in: wallSide) }
                s.holes = holes
                surfaces.append(s)
            }
            group += 1
        }

        // Windows: a pane on each side, textured with whatever the camera saw through or on them.
        for (i, window) in room.windows.enumerated() {
            let f = Frame(window.transform)
            let w = window.dimensions.x, h = window.dimensions.y
            guard w > 0.05, h > 0.05 else { continue }
            for (si, side) in [Float(1), -1].enumerated() {
                surfaces.append(rect(name: "window\(i)_\(si == 0 ? "a" : "b")", kind: .window, group: group,
                                     center: f.center, normal: f.z * side, up: f.y,
                                     width: w, height: h, occludes: false, color: windowColor))
            }
            group += 1
        }

        if lowest > highest { lowest = 0; highest = 2.5 }   // no walls at all

        // Floors (iOS 17 gives each floor's outline), with a fallback to the walls' outline.
        var floorY = lowest
        var floorOutlines: [[SIMD2<Float>]] = []   // world x, z
        var floorHeights: [Float] = []
        for floor in room.floors {
            if let outline = worldOutline(floor) {
                floorOutlines.append(outline.points)
                floorHeights.append(outline.y)
            }
        }
        if floorOutlines.isEmpty, footprint.count >= 3 {
            floorOutlines = [Geometry2D.convexHull(footprint)]
            floorHeights = [lowest]
        }
        if !floorHeights.isEmpty { floorY = floorHeights.reduce(0, +) / Float(floorHeights.count) }

        for (i, outline) in floorOutlines.enumerated() {
            if let s = horizontal(name: "floor\(i)", kind: .floor, group: group, outline: outline,
                                  y: floorHeights[i], facingUp: true, color: floorColor) {
                surfaces.append(s)
            }
            if options.includeCeilings,
               let s = horizontal(name: "ceiling\(i)", kind: .ceiling, group: group + 1, outline: outline,
                                  y: highest, facingUp: false, color: ceilingColor) {
                surfaces.append(s)
            }
            group += 2
        }

        // Furniture: a box per object, five faces (no bottom).
        for (oi, object) in room.objects.enumerated() {
            let f = Frame(object.transform)
            let d = object.dimensions
            guard d.x > 0.02, d.y > 0.02, d.z > 0.02 else { continue }
            let drawn = !options.replacedObjects.contains(object.identifier)
            let faces: [(String, SIMD3<Float>, SIMD3<Float>, Float, Float, Float)] = [
                // name, normal, up, width, height, distance from centre
                ("top", f.y, -f.z, d.x, d.z, d.y / 2),
                ("px", f.x, f.y, d.z, d.y, d.x / 2),
                ("nx", -f.x, f.y, d.z, d.y, d.x / 2),
                ("pz", f.z, f.y, d.x, d.y, d.z / 2),
                ("nz", -f.z, f.y, d.x, d.y, d.z / 2),
            ]
            for face in faces {
                var s = rect(name: "object\(oi)_\(face.0)", kind: .furniture, group: group,
                             center: f.center + face.1 * face.5, normal: face.1, up: face.2,
                             width: face.3, height: face.4, occludes: true, color: furnitureColor)
                s.rendered = drawn
                surfaces.append(s)
            }
            group += 1
        }

        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in footprint + floorOutlines.flatMap({ $0 }) {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let center = lo.x <= hi.x ? (lo + hi) / 2 : .zero
        return Result(surfaces: surfaces, floorY: floorY, ceilingY: highest, center: center)
    }

    // MARK: Helpers

    /// A RoomPlan transform split into unit axes and centre.
    struct Frame {
        var x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>, center: SIMD3<Float>
        init(_ t: simd_float4x4) {
            func unit(_ v: simd_float4, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
                let a = SIMD3(v.x, v.y, v.z)
                let len = simd_length(a)
                return len > 1e-5 ? a / len : fallback
            }
            x = unit(t.columns.0, SIMD3(1, 0, 0))
            y = unit(t.columns.1, SIMD3(0, 1, 0))
            z = unit(t.columns.2, SIMD3(0, 0, 1))
            center = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
    }

    static func rect(name: String, kind: PlanarSurface.Kind, group: Int, center: SIMD3<Float>,
                     normal: SIMD3<Float>, up: SIMD3<Float>, width: Float, height: Float,
                     occludes: Bool, color: SIMD3<Float>) -> PlanarSurface {
        let right = simd_normalize(simd_cross(up, normal))
        let origin = center - right * (width / 2) - up * (height / 2)
        return PlanarSurface(name: name, kind: kind, group: group, origin: origin, right: right, up: up,
                             normal: normal, size: SIMD2(width, height), polygon: nil,
                             occludes: occludes, defaultColor: color)
    }

    /// Does this door/window/opening sit in this wall?
    private static func onWall(_ cut: CapturedRoom.Surface, wall: Frame, width: Float) -> Bool {
        let c = Frame(cut.transform)
        let d = c.center - wall.center
        return abs(simd_dot(d, wall.z)) < 0.3
            && abs(simd_dot(c.z, wall.z)) > 0.85
            && abs(simd_dot(d, wall.x)) < width / 2 + cut.dimensions.x / 2
    }

    private static func hole(for cut: CapturedRoom.Surface, in s: PlanarSurface) -> Rect2? {
        let c = Frame(cut.transform)
        let p = s.local(c.center)
        let hw = cut.dimensions.x / 2, hh = cut.dimensions.y / 2
        let r = Rect2(minU: max(0, p.x - hw), minV: max(0, p.y - hh),
                      maxU: min(s.size.x, p.x + hw), maxV: min(s.size.y, p.y + hh))
        return (r.maxU - r.minU > 0.05 && r.maxV - r.minV > 0.05) ? r : nil
    }

    /// A floor's outline in world (x, z), and its height. RoomPlan gives the corners in the floor's
    /// own coordinates; if that doesn't come out level, the raw corners are tried as world points.
    private static func worldOutline(_ floor: CapturedRoom.Surface) -> (points: [SIMD2<Float>], y: Float)? {
        let corners = floor.polygonCorners
        guard corners.count >= 3 else { return nil }
        func level(_ pts: [SIMD3<Float>]) -> (points: [SIMD2<Float>], y: Float)? {
            let ys = pts.map(\.y)
            guard let lo = ys.min(), let hi = ys.max(), hi - lo < 0.08 else { return nil }
            let outline = pts.map { SIMD2($0.x, $0.z) }
            guard abs(Geometry2D.signedArea(outline)) > 0.2 else { return nil }
            return (outline, ys.reduce(0, +) / Float(ys.count))
        }
        let transformed = corners.map { c -> SIMD3<Float> in
            let w = floor.transform * SIMD4(c.x, c.y, c.z, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        return level(transformed) ?? level(corners)
    }

    /// A floor (facing up) or ceiling (facing down) from a world (x, z) outline.
    private static func horizontal(name: String, kind: PlanarSurface.Kind, group: Int, outline: [SIMD2<Float>],
                                   y: Float, facingUp: Bool, color: SIMD3<Float>) -> PlanarSurface? {
        guard outline.count >= 3 else { return nil }
        var lo = outline[0], hi = outline[0]
        for p in outline { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let size = hi - lo
        guard size.x > 0.1, size.y > 0.1 else { return nil }
        let right = SIMD3<Float>(1, 0, 0)
        let up: SIMD3<Float>
        let origin: SIMD3<Float>
        let local: [SIMD2<Float>]
        if facingUp {
            // right × up must be +Y: x × (−z) = +y. Local v grows toward −z.
            up = SIMD3(0, 0, -1)
            origin = SIMD3(lo.x, y, hi.y)
            local = outline.map { SIMD2($0.x - lo.x, hi.y - $0.y) }
        } else {
            // x × z = −y.
            up = SIMD3(0, 0, 1)
            origin = SIMD3(lo.x, y, lo.y)
            local = outline.map { SIMD2($0.x - lo.x, $0.y - lo.y) }
        }
        var poly = local
        if Geometry2D.signedArea(poly) < 0 { poly.reverse() }
        return PlanarSurface(name: name, kind: kind, group: group, origin: origin, right: right, up: up,
                             normal: simd_cross(right, up), size: size, polygon: poly,
                             occludes: false, defaultColor: color)
    }
}
