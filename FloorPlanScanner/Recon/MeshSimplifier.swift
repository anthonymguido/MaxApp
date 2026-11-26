import Foundation
import simd

/// Quadric error metric mesh simplification (Garland & Heckbert, SIGGRAPH 1997).
///
/// Each vertex accumulates the planes of its triangles as a 4×4 quadric; collapsing an edge costs the summed
/// squared distance of the new vertex to all those planes. Edges are collapsed cheapest-first, so flat areas
/// (walls, table tops) lose almost all their triangles while edges, corners and curved shapes keep theirs.
/// Mesh borders are protected by extra perpendicular planes, and collapses that would flip a triangle are refused.
///
/// Pure math, no ARKit: also compiled into the unit tests.
enum MeshSimplifier {
    /// Simplifies until `targetTriangles` remain (cheapest collapses first).
    static func simplify(_ input: ReconMesh, targetTriangles: Int) -> ReconMesh {
        guard input.triangleCount > targetTriangles else { return input }
        var positions = input.positions
        let nv = positions.count
        let nf = input.triangleCount
        var faces = [SIMD3<Int32>](repeating: .zero, count: nf)
        for t in 0..<nf {
            let (a, b, c) = input.triangle(t)
            faces[t] = SIMD3(Int32(a), Int32(b), Int32(c))
        }
        var faceAlive = [Bool](repeating: true, count: nf)
        var vertexFaces = [[Int32]](repeating: [], count: nv)
        for t in 0..<nf {
            for k in 0..<3 { vertexFaces[Int(faces[t][k])].append(Int32(t)) }
        }

        // Quadrics from triangle planes (area-weighted).
        var quadrics = [Quadric](repeating: Quadric(), count: nv)
        for t in 0..<nf {
            let a = positions[Int(faces[t].x)], b = positions[Int(faces[t].y)], c = positions[Int(faces[t].z)]
            let cr = simd_cross(b - a, c - a)
            let area = simd_length(cr) / 2
            guard area > 1e-12 else { continue }
            let n = cr / (2 * area)
            let q = Quadric(plane: n, point: a, weight: Double(area))
            for k in 0..<3 { quadrics[Int(faces[t][k])].add(q) }
        }

        // Border edges (used by one triangle): add a strong plane perpendicular to the face along the edge.
        var edgeCount: [UInt64: Int] = [:]
        func edgeKey(_ a: Int32, _ b: Int32) -> UInt64 {
            (UInt64(UInt32(min(a, b))) << 32) | UInt64(UInt32(max(a, b)))
        }
        for t in 0..<nf {
            let f = faces[t]
            for (a, b) in [(f.x, f.y), (f.y, f.z), (f.z, f.x)] { edgeCount[edgeKey(a, b), default: 0] += 1 }
        }
        for t in 0..<nf {
            let f = faces[t]
            let pa = positions[Int(f.x)], pb = positions[Int(f.y)], pc = positions[Int(f.z)]
            let fn = simd_normalize(simd_cross(pb - pa, pc - pa))
            guard fn.x.isFinite else { continue }
            for (a, b) in [(f.x, f.y), (f.y, f.z), (f.z, f.x)] where edgeCount[edgeKey(a, b)] == 1 {
                let p0 = positions[Int(a)], p1 = positions[Int(b)]
                let along = p1 - p0
                let len = simd_length(along)
                guard len > 1e-9 else { continue }
                let n = simd_normalize(simd_cross(along / len, fn))
                let q = Quadric(plane: n, point: p0, weight: Double(len * len) * 50)
                quadrics[Int(a)].add(q)
                quadrics[Int(b)].add(q)
            }
        }

        // Heap of candidate collapses, invalidated lazily by vertex versions.
        var version = [UInt32](repeating: 0, count: nv)
        var alive = [Bool](repeating: true, count: nv)
        var heap = CollapseHeap()
        func push(_ a: Int32, _ b: Int32) {
            let q = quadrics[Int(a)] + quadrics[Int(b)]
            let (p, cost) = q.bestPosition(positions[Int(a)], positions[Int(b)])
            heap.push(Collapse(cost: cost, a: a, b: b, va: version[Int(a)], vb: version[Int(b)], target: p))
        }
        for key in edgeCount.keys {
            push(Int32(truncatingIfNeeded: key >> 32), Int32(truncatingIfNeeded: key & 0xffff_ffff))
        }

        var faceTotal = nf
        while faceTotal > targetTriangles, let c = heap.pop() {
            let a = Int(c.a), b = Int(c.b)
            guard alive[a], alive[b], version[a] == c.va, version[b] == c.vb else { continue }

            // Refuse collapses that flip or squash a triangle.
            var ok = true
            for vtx in [a, b] where ok {
                for f in vertexFaces[vtx] where faceAlive[Int(f)] {
                    let face = faces[Int(f)]
                    let hasA = face.x == Int32(a) || face.y == Int32(a) || face.z == Int32(a)
                    let hasB = face.x == Int32(b) || face.y == Int32(b) || face.z == Int32(b)
                    if hasA && hasB { continue }   // removed by the collapse
                    let p = [positions[Int(face.x)], positions[Int(face.y)], positions[Int(face.z)]]
                    var q = p
                    for k in 0..<3 where face[k] == Int32(vtx) { q[k] = c.target }
                    let before = simd_cross(p[1] - p[0], p[2] - p[0])
                    let after = simd_cross(q[1] - q[0], q[2] - q[0])
                    let lb = simd_length(before), la = simd_length(after)
                    if la < 1e-12 || (lb > 1e-12 && simd_dot(before / lb, after / la) < 0.3) { ok = false; break }
                }
            }
            guard ok else { continue }

            // Collapse b into a.
            positions[a] = c.target
            quadrics[a].add(quadrics[b])
            alive[b] = false
            version[a] &+= 1
            version[b] &+= 1
            for f in vertexFaces[b] where faceAlive[Int(f)] {
                var face = faces[Int(f)]
                let hasA = face.x == Int32(a) || face.y == Int32(a) || face.z == Int32(a)
                if hasA {
                    faceAlive[Int(f)] = false
                    faceTotal -= 1
                } else {
                    for k in 0..<3 where face[k] == Int32(b) { face[k] = Int32(a) }
                    faces[Int(f)] = face
                    vertexFaces[a].append(f)
                }
            }
            vertexFaces[b] = []
            vertexFaces[a].removeAll { !faceAlive[Int($0)] }

            // New candidate collapses around a.
            var neighbours = Set<Int32>()
            for f in vertexFaces[a] {
                let face = faces[Int(f)]
                for k in 0..<3 where face[k] != Int32(a) { neighbours.insert(face[k]) }
            }
            for n in neighbours where alive[Int(n)] { push(Int32(a), n) }
        }

        var out = ReconMesh()
        out.positions = positions
        for t in 0..<nf where faceAlive[t] {
            let f = faces[t]
            guard f.x != f.y, f.y != f.z, f.x != f.z else { continue }
            out.indices += [UInt32(f.x), UInt32(f.y), UInt32(f.z)]
        }
        out.compact()
        return out
    }
}

/// Symmetric 4×4 quadric, stored as its 10 distinct entries: a2 ab ac ad b2 bc bd c2 | cd d2.
struct Quadric {
    var lo = SIMD8<Double>()
    var hi = SIMD2<Double>()

    init() {}

    init(plane n: SIMD3<Float>, point p: SIMD3<Float>, weight: Double) {
        let a = Double(n.x), b = Double(n.y), c = Double(n.z)
        let d = -(a * Double(p.x) + b * Double(p.y) + c * Double(p.z))
        lo = SIMD8(a * a, a * b, a * c, a * d, b * b, b * c, b * d, c * c) * weight
        hi = SIMD2(c * d, d * d) * weight
    }

    mutating func add(_ o: Quadric) {
        lo += o.lo
        hi += o.hi
    }

    static func + (l: Quadric, r: Quadric) -> Quadric {
        var q = l
        q.add(r)
        return q
    }

    func error(_ p: SIMD3<Float>) -> Double {
        let x = Double(p.x), y = Double(p.y), z = Double(p.z)
        let t1: Double = lo[0] * x * x + 2 * lo[1] * x * y + 2 * lo[2] * x * z + 2 * lo[3] * x
        let t2: Double = lo[4] * y * y + 2 * lo[5] * y * z + 2 * lo[6] * y
        let t3: Double = lo[7] * z * z + 2 * hi[0] * z + hi[1]
        return max(0, t1 + t2 + t3)
    }

    /// The best of: the optimal point (if the system is well conditioned), the two ends and the midpoint.
    func bestPosition(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (SIMD3<Float>, Double) {
        var best = a
        var bestError = error(a)
        func consider(_ p: SIMD3<Float>) {
            let e = error(p)
            if e < bestError { best = p; bestError = e }
        }
        consider(b)
        consider((a + b) / 2)
        let A = simd_double3x3(SIMD3(lo[0], lo[1], lo[2]), SIMD3(lo[1], lo[4], lo[5]), SIMD3(lo[2], lo[5], lo[7]))
        if abs(A.determinant) > 1e-12 {
            let x = A.inverse * SIMD3(-lo[3], -lo[6], -hi[0])
            let p = SIMD3<Float>(Float(x.x), Float(x.y), Float(x.z))
            // Only trust it near the edge (ill-conditioned systems can shoot far away).
            if simd_distance(p, (a + b) / 2) < simd_distance(a, b) * 2 { consider(p) }
        }
        return (best, bestError)
    }
}

struct Collapse {
    var cost: Double
    var a: Int32
    var b: Int32
    var va: UInt32
    var vb: UInt32
    var target: SIMD3<Float>
}

/// Binary min-heap on cost.
struct CollapseHeap {
    private var items: [Collapse] = []

    mutating func push(_ c: Collapse) {
        items.append(c)
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].cost < items[parent].cost else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> Collapse? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var smallest = i
                if l < items.count && items[l].cost < items[smallest].cost { smallest = l }
                if r < items.count && items[r].cost < items[smallest].cost { smallest = r }
                if smallest == i { break }
                items.swapAt(i, smallest)
                i = smallest
            }
        }
        return top
    }
}
