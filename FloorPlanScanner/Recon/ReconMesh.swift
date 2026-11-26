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

    /// Removes connected pieces with fewer than `minTriangles` triangles (floating noise).
    mutating func removeSmallComponents(minTriangles: Int) {
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
        var root = [Int](repeating: 0, count: triangleCount)
        for t in 0..<triangleCount {
            root[t] = find(triangle(t).0)
            size[root[t], default: 0] += 1
        }
        filterTriangles { t in (size[root[t]] ?? 0) >= minTriangles }
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
