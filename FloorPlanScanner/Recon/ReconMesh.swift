import Foundation
import simd

/// A triangle mesh used by the reconstruction steps: positions plus three indices per triangle.
/// Pure math, no ARKit: also compiled into the unit tests.
struct ReconMesh {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }

    func triangle(_ t: Int) -> (Int, Int, Int) {
        (Int(indices[t * 3]), Int(indices[t * 3 + 1]), Int(indices[t * 3 + 2]))
    }

    func faceNormal(_ t: Int) -> SIMD3<Float> {
        let (a, b, c) = triangle(t)
        let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
        let len = simd_length(n)
        return len > 1e-12 ? n / len : SIMD3(0, 1, 0)
    }

    func faceArea(_ t: Int) -> Float {
        let (a, b, c) = triangle(t)
        return simd_length(simd_cross(positions[b] - positions[a], positions[c] - positions[a])) / 2
    }

    /// Area-weighted vertex normals.
    func vertexNormals() -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n
            normals[b] += n
            normals[c] += n
        }
        return normals.map { n in
            let len = simd_length(n)
            return len > 1e-12 ? n / len : SIMD3(0, 1, 0)
        }
    }

    /// Triangles that share an edge with each triangle.
    func faceAdjacency() -> [[Int32]] {
        var edgeFaces: [UInt64: [Int32]] = [:]
        edgeFaces.reserveCapacity(indices.count)
        func key(_ a: Int, _ b: Int) -> UInt64 {
            let lo = UInt64(min(a, b)), hi = UInt64(max(a, b))
            return (lo << 32) | hi
        }
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            for k in [key(a, b), key(b, c), key(c, a)] { edgeFaces[k, default: []].append(Int32(t)) }
        }
        var adjacency = [[Int32]](repeating: [], count: triangleCount)
        for faces in edgeFaces.values where faces.count > 1 {
            for f in faces {
                for g in faces where g != f { adjacency[Int(f)].append(g) }
            }
        }
        return adjacency
    }

    /// Drops vertices no triangle uses and renumbers.
    mutating func compact() {
        var map = [Int32](repeating: -1, count: positions.count)
        var newPositions: [SIMD3<Float>] = []
        newPositions.reserveCapacity(positions.count)
        for i in indices.indices {
            let v = Int(indices[i])
            if map[v] < 0 {
                map[v] = Int32(newPositions.count)
                newPositions.append(positions[v])
            }
            indices[i] = UInt32(map[v])
        }
        positions = newPositions
    }

    /// Keeps only triangles for which `keep` is true.
    mutating func filterTriangles(_ keep: (Int) -> Bool) {
        var out: [UInt32] = []
        out.reserveCapacity(indices.count)
        for t in 0..<triangleCount where keep(t) {
            out.append(indices[t * 3]); out.append(indices[t * 3 + 1]); out.append(indices[t * 3 + 2])
        }
        indices = out
        compact()
    }

    /// Undirected edge key.
    @inline(__always)
    static func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
        (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
    }

    /// Number of edges used by only one triangle (0 = closed surface).
    func boundaryEdgeCount() -> Int {
        var count: [UInt64: Int] = [:]
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            for k in [Self.edgeKey(a, b), Self.edgeKey(b, c), Self.edgeKey(c, a)] { count[k, default: 0] += 1 }
        }
        return count.values.filter { $0 == 1 }.count
    }

    /// Closes small holes: boundary loops of at most `maxEdges` edges get a fan of triangles around their centre.
    /// Big open borders (the edge of what was scanned) are left alone.
    /// - Returns: number of holes filled.
    @discardableResult
    mutating func fillHoles(maxEdges: Int) -> Int {
        // Directed edges present; a boundary half-edge a→b has no b→a.
        var directed = Set<UInt64>()
        directed.reserveCapacity(indices.count)
        func dkey(_ a: Int, _ b: Int) -> UInt64 { (UInt64(a) << 32) | UInt64(b) }
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            directed.insert(dkey(a, b)); directed.insert(dkey(b, c)); directed.insert(dkey(c, a))
        }
        // The hole runs the other way round: for boundary a→b, the loop goes b→a.
        var next: [Int: Int] = [:]
        var ambiguous = Set<Int>()
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            for (u, v) in [(a, b), (b, c), (c, a)] where !directed.contains(dkey(v, u)) {
                if next[v] != nil { ambiguous.insert(v) }
                next[v] = u
            }
        }
        var visited = Set<Int>()
        var filled = 0
        for start in next.keys where !visited.contains(start) && !ambiguous.contains(start) {
            var loop = [start]
            var v = start
            var ok = false
            while loop.count <= maxEdges {
                guard let n = next[v], !ambiguous.contains(n) else { break }
                if n == start { ok = true; break }
                if visited.contains(n) || loop.contains(n) { break }
                loop.append(n)
                v = n
            }
            for x in loop { visited.insert(x) }
            guard ok, loop.count >= 3 else { continue }
            if loop.count == 3 {
                indices += [UInt32(loop[0]), UInt32(loop[1]), UInt32(loop[2])]
            } else {
                var centre = SIMD3<Float>.zero
                for x in loop { centre += positions[x] }
                centre /= Float(loop.count)
                let ci = UInt32(positions.count)
                positions.append(centre)
                for i in loop.indices {
                    indices += [UInt32(loop[i]), UInt32(loop[(i + 1) % loop.count]), ci]
                }
            }
            filled += 1
        }
        return filled
    }

    /// Removes frayed slivers at open borders (triangles with two border edges), `passes` times.
    mutating func trimFringe(passes: Int) {
        for _ in 0..<passes {
            var count: [UInt64: Int] = [:]
            for t in 0..<triangleCount {
                let (a, b, c) = triangle(t)
                for k in [Self.edgeKey(a, b), Self.edgeKey(b, c), Self.edgeKey(c, a)] { count[k, default: 0] += 1 }
            }
            let keep: [Bool] = (0..<triangleCount).map { t in
                let (a, b, c) = triangle(t)
                let border = [Self.edgeKey(a, b), Self.edgeKey(b, c), Self.edgeKey(c, a)].filter { count[$0] == 1 }.count
                return border < 2
            }
            if keep.allSatisfy({ $0 }) { return }
            filterTriangles { keep[$0] }
        }
    }

    /// Removes connected pieces with fewer than `minTriangles` triangles or less than `minArea` m² (floating noise).
    mutating func removeSmallComponents(minTriangles: Int, minArea: Float = 0) {
        guard triangleCount > 0 else { return }
        var parent = Array(0..<positions.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            let ra = find(a), rb = find(b), rc = find(c)
            parent[rb] = ra
            parent[find(rc)] = find(ra)
        }
        var size: [Int: Int] = [:]
        var area: [Int: Float] = [:]
        var root = [Int](repeating: 0, count: triangleCount)
        for t in 0..<triangleCount {
            root[t] = find(triangle(t).0)
            size[root[t], default: 0] += 1
            area[root[t], default: 0] += faceArea(t)
        }
        filterTriangles { t in (size[root[t]] ?? 0) >= minTriangles && (area[root[t]] ?? 0) >= minArea }
    }

    /// Taubin smoothing: removes voxel steps without shrinking the shape.
    mutating func taubinSmooth(iterations: Int) {
        let n = positions.count
        var neighbors = [[UInt32]](repeating: [], count: n)
        for t in 0..<triangleCount {
            let a = indices[t * 3], b = indices[t * 3 + 1], c = indices[t * 3 + 2]
            neighbors[Int(a)].append(b); neighbors[Int(a)].append(c)
            neighbors[Int(b)].append(a); neighbors[Int(b)].append(c)
            neighbors[Int(c)].append(a); neighbors[Int(c)].append(b)
        }
        func step(_ factor: Float) {
            let old = positions
            for i in 0..<n where !neighbors[i].isEmpty {
                var avg = SIMD3<Float>.zero
                for j in neighbors[i] { avg += old[Int(j)] }
                avg /= Float(neighbors[i].count)
                positions[i] = old[i] + factor * (avg - old[i])
            }
        }
        for _ in 0..<iterations {
            step(0.5)
            step(-0.53)
        }
    }
}
