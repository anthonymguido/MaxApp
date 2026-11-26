import Foundation
import simd

/// Truncated signed distance volume on a sparse voxel grid (voxel hashing, after Nießner et al. 2013).
///
/// LiDAR depth frames are fused into it: every voxel near an observed surface stores a running weighted average
/// of its signed distance to that surface (positive in front, negative behind). Noise from single frames averages
/// out, and the zero crossing becomes the reconstructed surface (see `extractSurface`).
///
/// Pure math, no ARKit: also compiled into the unit tests.
final class TSDFVolume {
    static let blockSide = 8
    static let blockVoxels = blockSide * blockSide * blockSide

    let voxelSize: Float
    let truncation: Float
    /// Weight cap, so the volume keeps adapting a little.
    let maxWeight: UInt8 = 60

    private(set) var blocks: [SIMD3<Int32>: Int] = [:]
    private(set) var blockKeys: [SIMD3<Int32>] = []
    private var sdf: [Float16] = []
    private var weight: [UInt8] = []

    var blockCount: Int { blockKeys.count }
    var memoryBytes: Int { sdf.count * 3 }

    init(voxelSize: Float = 0.02, truncationVoxels: Float = 3) {
        self.voxelSize = voxelSize
        self.truncation = voxelSize * truncationVoxels
    }

    /// Camera model of one depth frame (ARKit convention: camera looks down −Z, +Y up, image v grows downward).
    struct DepthCamera {
        var fx: Float, fy: Float, cx: Float, cy: Float
        var cameraToWorld: simd_float4x4
    }

    /// Fuses one depth map. `depthMM` is row-major millimetres (0 = unknown); `confidence` (0/1/2) is optional.
    /// - Parameters:
    ///   - stride: use every n-th pixel in each direction (2 is plenty at 2 cm voxels).
    ///   - minConfidence: ARKit confidence needed (2 = high).
    ///   - bounds: optional world box; points outside are ignored (e.g. seen through windows).
    func integrate(depthMM: [UInt16], confidence: [UInt8]?, width: Int, height: Int, camera: DepthCamera,
                   stride: Int = 2, minConfidence: UInt8 = 2, maxDepth: Float = 4.5,
                   bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil) {
        let toWorld = camera.cameraToWorld
        let toCamera = toWorld.inverse
        let origin = SIMD3(toWorld.columns.3.x, toWorld.columns.3.y, toWorld.columns.3.z)
        let rows = Array(Swift.stride(from: 0, to: height, by: stride))
        let half = truncation
        let step = voxelSize * 0.5

        // 1. In parallel: voxel updates (voxel coordinate, signed distance) along each pixel's ray near the surface.
        var perRow = [[(SIMD3<Int32>, Float)]](repeating: [], count: rows.count)
        perRow.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: rows.count) { r in
                let v = rows[r]
                var updates: [(SIMD3<Int32>, Float)] = []
                updates.reserveCapacity(width / stride * 8)
                var u = 0
                while u < width {
                    defer { u += stride }
                    let i = v * width + u
                    let mm = depthMM[i]
                    guard mm > 0 else { continue }
                    if let confidence, confidence[i] < minConfidence { continue }
                    let d = Float(mm) / 1000
                    guard d > 0.15, d < maxDepth else { continue }
                    // Pixel → camera → world.
                    let pc = SIMD4<Float>((Float(u) + 0.5 - camera.cx) / camera.fx * d,
                                          -(Float(v) + 0.5 - camera.cy) / camera.fy * d, -d, 1)
                    let pw4 = toWorld * pc
                    let pw = SIMD3(pw4.x, pw4.y, pw4.z)
                    if let b = bounds, any(pw .< b.min) || any(pw .> b.max) { continue }
                    let dir = simd_normalize(pw - origin)
                    var t = -half
                    var last = SIMD3<Int32>(Int32.min, 0, 0)
                    while t <= half {
                        let q = pw + dir * t
                        t += step
                        let key = SIMD3<Int32>(Int32((q.x / self.voxelSize).rounded(.down)),
                                               Int32((q.y / self.voxelSize).rounded(.down)),
                                               Int32((q.z / self.voxelSize).rounded(.down)))
                        if key == last { continue }
                        last = key
                        // Projective signed distance of the voxel centre along the camera axis.
                        let c = (SIMD3<Float>(key) + 0.5) * self.voxelSize
                        let cc = toCamera * SIMD4(c.x, c.y, c.z, 1)
                        let sd = d - (-cc.z)
                        guard sd > -half else { continue }
                        updates.append((key, min(1, sd / half)))
                    }
                }
                out[r] = updates
            }
        }

        // 2. Serially: allocate blocks and average the updates in.
        var lastBlock = SIMD3<Int32>(Int32.min, 0, 0)
        var lastBase = 0
        let side = Int32(Self.blockSide)
        for updates in perRow {
            for (key, value) in updates {
                let bk = SIMD3<Int32>(floorDiv(key.x, side), floorDiv(key.y, side), floorDiv(key.z, side))
                if bk != lastBlock {
                    lastBlock = bk
                    lastBase = blockBase(bk, create: true)!
                }
                let local = key &- bk &* side
                let i = lastBase + Int(local.x) + Self.blockSide * (Int(local.y) + Self.blockSide * Int(local.z))
                let w = weight[i]
                let old = Float(sdf[i])
                let nw = Float(w) + 1
                sdf[i] = Float16((old * Float(w) + value) / nw)
                weight[i] = min(maxWeight, w &+ 1)
            }
        }
    }

    /// How well a depth frame agrees with what's already fused: of its sampled surface points that land in observed
    /// voxels, how many lie on the existing surface (|distance| under ~¾ of the truncation band).
    /// A frame whose camera position drifted (tracking error) lands its points in free space or behind surfaces,
    /// so it agrees poorly and can be skipped before it adds a ghost copy of the room.
    func agreement(depthMM: [UInt16], confidence: [UInt8]?, width: Int, height: Int, camera: DepthCamera,
                   minConfidence: UInt8 = 2, maxDepth: Float = 4.5, samples: Int = 600) -> (checked: Int, agreeing: Int) {
        let toWorld = camera.cameraToWorld
        let step = max(1, Int((Float(width * height) / Float(samples)).squareRoot()))
        var checked = 0, agreeing = 0
        var v = step / 2
        while v < height {
            var u = step / 2
            while u < width {
                defer { u += step }
                let i = v * width + u
                let mm = depthMM[i]
                guard mm > 0 else { continue }
                if let confidence, confidence[i] < minConfidence { continue }
                let d = Float(mm) / 1000
                guard d > 0.15, d < maxDepth else { continue }
                let pc = SIMD4<Float>((Float(u) + 0.5 - camera.cx) / camera.fx * d,
                                      -(Float(v) + 0.5 - camera.cy) / camera.fy * d, -d, 1)
                let p = toWorld * pc
                let key = SIMD3<Int32>(Int32((p.x / voxelSize).rounded(.down)), Int32((p.y / voxelSize).rounded(.down)),
                                       Int32((p.z / voxelSize).rounded(.down)))
                guard let value = value(key) else { continue }
                checked += 1
                if abs(value) < 0.75 { agreeing += 1 }
            }
            v += step
        }
        return (checked, agreeing)
    }

    /// Signed distance (in truncation units, −1…1) at a voxel, or nil if never observed.
    @inline(__always)
    func value(_ key: SIMD3<Int32>) -> Float? {
        let side = Int32(Self.blockSide)
        let bk = SIMD3<Int32>(floorDiv(key.x, side), floorDiv(key.y, side), floorDiv(key.z, side))
        guard let b = blocks[bk] else { return nil }
        let local = key &- bk &* side
        let i = b * Self.blockVoxels + Int(local.x) + Self.blockSide * (Int(local.y) + Self.blockSide * Int(local.z))
        return weight[i] > 0 ? Float(sdf[i]) : nil
    }

    /// Writes a value directly (used by tests to build synthetic volumes).
    func set(_ key: SIMD3<Int32>, value: Float, weight w: UInt8 = 10) {
        let side = Int32(Self.blockSide)
        let bk = SIMD3<Int32>(floorDiv(key.x, side), floorDiv(key.y, side), floorDiv(key.z, side))
        let base = blockBase(bk, create: true)!
        let local = key &- bk &* side
        let i = base + Int(local.x) + Self.blockSide * (Int(local.y) + Self.blockSide * Int(local.z))
        sdf[i] = Float16(value)
        weight[i] = w
    }

    private func blockBase(_ bk: SIMD3<Int32>, create: Bool) -> Int? {
        if let b = blocks[bk] { return b * Self.blockVoxels }
        guard create else { return nil }
        let b = blockKeys.count
        blocks[bk] = b
        blockKeys.append(bk)
        sdf.append(contentsOf: repeatElement(Float16(1), count: Self.blockVoxels))
        weight.append(contentsOf: repeatElement(UInt8(0), count: Self.blockVoxels))
        return b * Self.blockVoxels
    }

    // MARK: Surface extraction (naive surface nets)

    /// The zero crossing of the volume as a triangle mesh: one vertex per voxel cell the surface passes through
    /// (placed at the average of the edge crossings), one quad per grid edge with a sign change.
    /// Cells touching unobserved voxels are skipped, so there are no fake surfaces at the edge of what was seen.
    func extractSurface() -> ReconMesh {
        let corners: [SIMD3<Int32>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0], [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1]]
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        let side = Int32(Self.blockSide)
        let keys = blockKeys

        // 1. In parallel per block: vertices for its cells.
        var perBlock = [[(SIMD3<Int32>, SIMD3<Float>)]](repeating: [], count: keys.count)
        perBlock.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: keys.count) { b in
                let origin = keys[b] &* side
                var verts: [(SIMD3<Int32>, SIMD3<Float>)] = []
                for z in 0..<side {
                    for y in 0..<side {
                        for x in 0..<side {
                            let cell = origin &+ SIMD3(x, y, z)
                            var values = SIMD8<Float>()
                            var missing = -1
                            var bad = false
                            var sum: Float = 0
                            for (c, o) in corners.enumerated() {
                                if let v = self.value(cell &+ o) {
                                    values[c] = v
                                    sum += v
                                } else if missing < 0 {
                                    missing = c          // one unobserved corner is tolerated…
                                } else {
                                    bad = true           // …two or more are not (could invent fake surfaces)
                                    break
                                }
                            }
                            guard !bad else { continue }
                            if missing >= 0 { values[missing] = sum / 7 }   // closes 1-voxel gaps
                            var mask = 0
                            for c in 0..<8 where values[c] < 0 { mask |= 1 << c }
                            guard mask != 0, mask != 255 else { continue }
                            var sum = SIMD3<Float>.zero
                            var n: Float = 0
                            for (e0, e1) in edges where (values[e0] < 0) != (values[e1] < 0) {
                                let t = values[e0] / (values[e0] - values[e1])
                                let p0 = SIMD3<Float>(corners[e0]), p1 = SIMD3<Float>(corners[e1])
                                sum += p0 + (p1 - p0) * t
                                n += 1
                            }
                            let p = (SIMD3<Float>(cell) + 0.5 + sum / n) * self.voxelSize
                            verts.append((cell, p))
                        }
                    }
                }
                out[b] = verts
            }
        }

        // 2. Number the vertices.
        var mesh = ReconMesh()
        var vertexOf: [SIMD3<Int32>: UInt32] = [:]
        for verts in perBlock {
            for (cell, p) in verts {
                vertexOf[cell] = UInt32(mesh.positions.count)
                mesh.positions.append(p)
            }
        }

        // 3. Quads: for each cell's min corner, the three grid edges going +x, +y, +z.
        //    The edge from corner v along axis a is shared by the 4 cells around it.
        let axes: [(SIMD3<Int32>, SIMD3<Int32>, SIMD3<Int32>)] = [
            ([1, 0, 0], [0, 1, 0], [0, 0, 1]),
            ([0, 1, 0], [0, 0, 1], [1, 0, 0]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]),
        ]
        for (cell, _) in perBlock.joined() {
            for (axis, u, w) in axes {
                // The edge from grid point v to v + axis is shared by cells v−u−w, v−w, v, v−u.
                // Taking v = cell + u + w visits every edge exactly once (from its "lowest" cell).
                let v = cell &+ u &+ w
                guard let a = value(v), let b = value(v &+ axis) else { continue }
                guard (a < 0) != (b < 0) else { continue }
                let q = [cell, cell &+ u, cell &+ u &+ w, cell &+ w]
                guard let i0 = vertexOf[q[0]], let i1 = vertexOf[q[1]],
                      let i2 = vertexOf[q[2]], let i3 = vertexOf[q[3]] else { continue }
                // Wind so the normal points from inside (negative) to outside (positive).
                let outward = SIMD3<Float>(axis) * (a < 0 ? 1 : -1)
                let p0 = mesh.positions[Int(i0)], p1 = mesh.positions[Int(i1)]
                let p2 = mesh.positions[Int(i2)], p3 = mesh.positions[Int(i3)]
                let normal = simd_cross(p1 - p0, p2 - p0) + simd_cross(p2 - p0, p3 - p0)
                if simd_dot(normal, outward) >= 0 {
                    mesh.indices += [i0, i1, i2, i0, i2, i3]
                } else {
                    mesh.indices += [i0, i3, i2, i0, i2, i1]
                }
            }
        }
        return mesh
    }
}

@inline(__always)
private func floorDiv(_ a: Int32, _ b: Int32) -> Int32 {
    a >= 0 ? a / b : -((-a + b - 1) / b)
}
