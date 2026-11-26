import Foundation
import simd

/// Choosing one photo per spot and hiding the seams between photos.
///
/// After Waechter, Moehrle & Goesele, "Let There Be Color! Large-Scale Texturing of 3D Reconstructions" (ECCV 2014):
/// - **View selection** is a Markov random field: each cell (or face) picks one photo label; the data term prefers
///   the sharpest, most head-on, closest photo; a Potts smoothness term prefers neighbours using the same photo,
///   so the texture is made of a few large sharp patches instead of a blurry average of many photos.
/// - **Seam leveling** finds a smooth color offset per patch so neighbouring patches meet without a visible step.
///
/// No ARKit here: pure math, shared by the plane and mesh texturers.
enum ViewSelection {
    /// Labels a grid of cells with one photo each.
    /// - Parameters:
    ///   - labels: per cell, the candidate photos (best first).
    ///   - scores: per cell, the matching quality scores (higher is better).
    ///   - smoothness: penalty for each 4-neighbour that uses a different photo, relative to a data cost in 0…1.
    /// - Returns: chosen photo per cell, or -1 where no photo sees it.
    static func solveGrid(labels: [[Int32]], scores: [[Float]], nu: Int, nv: Int,
                          smoothness: Float = 0.35, sweeps: Int = 8) -> [Int32] {
        let n = nu * nv
        precondition(labels.count == n && scores.count == n)
        // Data cost: 0 for the cell's best photo, rising toward 1 for much worse ones.
        var cost: [[Float]] = []
        cost.reserveCapacity(n)
        for c in 0..<n {
            let best = scores[c].max() ?? 0
            cost.append(scores[c].map { best > 0 ? 1 - $0 / best : 1 })
        }
        // Start from the best photo per cell.
        var result = (0..<n).map { labels[$0].first ?? -1 }

        // Iterated conditional modes, alternating sweep direction.
        for sweep in 0..<sweeps {
            var changed = false
            let order: [Int] = sweep % 2 == 0 ? Array(0..<n) : Array((0..<n).reversed())
            for c in order {
                let options = labels[c]
                guard options.count > 1 else { continue }
                let i = c % nu, j = c / nu
                var neighbours: [Int32] = []
                if i > 0 { neighbours.append(result[c - 1]) }
                if i < nu - 1 { neighbours.append(result[c + 1]) }
                if j > 0 { neighbours.append(result[c - nu]) }
                if j < nv - 1 { neighbours.append(result[c + nu]) }
                var bestLabel = result[c]
                var bestEnergy = Float.greatestFiniteMagnitude
                for (k, label) in options.enumerated() {
                    var e = cost[c][k]
                    for nb in neighbours where nb >= 0 && nb != label { e += smoothness }
                    if e < bestEnergy - 1e-6 {
                        bestEnergy = e
                        bestLabel = label
                    }
                }
                if bestLabel != result[c] {
                    result[c] = bestLabel
                    changed = true
                }
            }
            if !changed { break }
        }
        return result
    }

    /// Labels the faces of a mesh with one photo each (same MRF as `solveGrid`, on the face adjacency graph).
    /// Neighbouring faces' smoothness penalty is weighted, so big shared edges matter more than tiny ones.
    static func solveGraph(labels: [[Int32]], scores: [[Float]], neighbours: [[Int32]],
                           smoothness: Float = 0.35, sweeps: Int = 10) -> [Int32] {
        let n = labels.count
        precondition(scores.count == n && neighbours.count == n)
        var cost: [[Float]] = []
        cost.reserveCapacity(n)
        for f in 0..<n {
            let best = scores[f].max() ?? 0
            cost.append(scores[f].map { best > 0 ? 1 - $0 / best : 1 })
        }
        var result = (0..<n).map { labels[$0].first ?? -1 }
        for sweep in 0..<sweeps {
            var changed = 0
            let order: [Int] = sweep % 2 == 0 ? Array(0..<n) : Array((0..<n).reversed())
            for f in order {
                let options = labels[f]
                guard options.count > 1 else { continue }
                var bestLabel = result[f]
                var bestEnergy = Float.greatestFiniteMagnitude
                for (k, label) in options.enumerated() {
                    var e = cost[f][k]
                    for nb in neighbours[f] {
                        let other = result[Int(nb)]
                        if other >= 0 && other != label { e += smoothness }
                    }
                    if e < bestEnergy - 1e-6 {
                        bestEnergy = e
                        bestLabel = label
                    }
                }
                if bestLabel != result[f] {
                    result[f] = bestLabel
                    changed += 1
                }
            }
            if changed == 0 { break }
        }
        return result
    }

    /// Per-patch color offsets that make neighbouring patches agree (global seam leveling at patch level).
    /// - Parameters:
    ///   - patchCount: number of patches.
    ///   - constraints: (patch a, patch b, mean color of a − mean color of b along their shared border, weight).
    /// - Returns: an offset per patch to add to its colors.
    static func levelPatches(patchCount: Int, constraints: [(Int, Int, SIMD3<Float>, Float)],
                             regularization: Float = 1, iterations: Int = 80) -> [SIMD3<Float>] {
        var adjacency = [[(Int, Float, SIMD3<Float>)]](repeating: [], count: patchCount)
        for (a, b, diff, w) in constraints where a != b && w > 0 {
            // Want color_a + g_a = color_b + g_b  →  g_a − g_b = −diff.
            adjacency[a].append((b, w, -diff))
            adjacency[b].append((a, w, diff))
        }
        var g = [SIMD3<Float>](repeating: .zero, count: patchCount)
        for _ in 0..<iterations {
            var maxChange: Float = 0
            for a in 0..<patchCount where !adjacency[a].isEmpty {
                var num = SIMD3<Float>.zero
                var den = regularization
                for (b, w, target) in adjacency[a] {
                    num += w * (g[b] + target)
                    den += w
                }
                let new = num / den
                maxChange = max(maxChange, simd_length(new - g[a]))
                g[a] = new
            }
            if maxChange < 1e-4 { break }
        }
        return g
    }

    /// Levels the seams of a baked texture made of single-photo patches.
    /// - Parameters:
    ///   - color: texture (row-major), changed in place.
    ///   - valid: which texels were seen by a photo.
    ///   - texelLabel: the photo each texel was taken from (-1 = none).
    ///   - texelCell: the grid cell each texel belongs to (-1 = none).
    ///   - cellCount: number of cells.
    ///   - cellCoordinate: fractional cell-grid position of a texel (cell centres at integer + 0.5 − 0.5 = integer).
    ///   - cellLabel: the photo chosen for each cell.
    static func levelSeams(color: inout [SIMD3<Float>], valid: [Bool], texelLabel: [Int32], texelCell: [Int32],
                           width w: Int, height h: Int, nu: Int, nv: Int, cellLabel: [Int32],
                           cellCoordinate: (Int, Int) -> SIMD2<Float>) {
        let cellCount = nu * nv
        guard cellCount > 1 else { return }

        // 1. Constraints between neighbouring cells, from adjacent texel pairs.
        struct Edge { var sum = SIMD3<Float>.zero; var weight: Float = 0 }
        var edges: [Int64: Edge] = [:]   // key: a * cellCount + b with a < b; sum is of (color[a-side] − color[b-side])
        var seamTexels = 0
        func addPair(_ p: Int, _ q: Int) {
            guard valid[p], valid[q] else { return }
            let ca = Int(texelCell[p]), cb = Int(texelCell[q])
            guard ca >= 0, cb >= 0, ca != cb else { return }
            let differentPhoto = texelLabel[p] != texelLabel[q]
            let (a, b, d): (Int, Int, SIMD3<Float>) = ca < cb ? (ca, cb, color[p] - color[q]) : (cb, ca, color[q] - color[p])
            let key = Int64(a) * Int64(cellCount) + Int64(b)
            var e = edges[key] ?? Edge()
            if differentPhoto {
                e.sum += d
                e.weight += 1
                seamTexels += 1
            } else {
                e.weight += 0.25   // same photo: just keep the offsets smooth (target difference 0)
            }
            edges[key] = e
        }
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                if x + 1 < w { addPair(p, p + 1) }
                if y + 1 < h { addPair(p, p + w) }
            }
        }
        guard seamTexels > 0 else { return }

        // 2. Adjacency: for cell a, (b, weight, target g_a − g_b).
        var adjacency = [[(Int, Float, SIMD3<Float>)]](repeating: [], count: cellCount)
        for (key, e) in edges where e.weight > 0 {
            let a = Int(key / Int64(cellCount)), b = Int(key % Int64(cellCount))
            // Want color_a + g_a = color_b + g_b  →  g_a − g_b = −mean(color_a − color_b).
            let target = -e.sum / e.weight
            adjacency[a].append((b, e.weight, target))
            adjacency[b].append((a, e.weight, -target))
        }

        // 3. Gauss–Seidel on the least-squares problem, with a small pull toward zero offset.
        let mu: Float = 1
        var g = [SIMD3<Float>](repeating: .zero, count: cellCount)
        for _ in 0..<60 {
            var maxChange: Float = 0
            for a in 0..<cellCount where !adjacency[a].isEmpty {
                var num = SIMD3<Float>.zero
                var den = mu
                for (b, wgt, target) in adjacency[a] {
                    num += wgt * (g[b] + target)
                    den += wgt
                }
                let new = num / den
                maxChange = max(maxChange, simd_length(new - g[a]))
                g[a] = new
            }
            if maxChange < 1e-4 { break }
        }

        // 4. Apply: per texel, interpolate offsets of nearby cells that used the same photo.
        var out = color
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                guard valid[p], texelCell[p] >= 0 else { continue }
                let label = texelLabel[p]
                let f = cellCoordinate(x, y)
                let i0 = Int(f.x.rounded(.down)), j0 = Int(f.y.rounded(.down))
                let tu = f.x - Float(i0), tv = f.y - Float(j0)
                var sum = SIMD3<Float>.zero
                var wsum: Float = 0
                for dj in 0...1 {
                    for di in 0...1 {
                        let i = i0 + di, j = j0 + dj
                        guard i >= 0, j >= 0, i < nu, j < nv else { continue }
                        let c = j * nu + i
                        guard cellLabel[c] == label else { continue }
                        let wgt: Float = (di == 0 ? 1 - tu : tu) * (dj == 0 ? 1 - tv : tv)
                        sum += wgt * g[c]
                        wsum += wgt
                    }
                }
                let offset = wsum > 1e-4 ? sum / wsum : g[Int(texelCell[p])]
                out[p] = simd_clamp(color[p] + offset, .zero, SIMD3(repeating: 1))
            }
        }

        // 5. Soften what's left of each seam over a couple of texels.
        var feathered = out
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                guard valid[p] else { continue }
                var onSeam = false
                if x > 0, valid[p - 1], texelLabel[p - 1] != texelLabel[p] { onSeam = true }
                if x + 1 < w, valid[p + 1], texelLabel[p + 1] != texelLabel[p] { onSeam = true }
                if y > 0, valid[p - w], texelLabel[p - w] != texelLabel[p] { onSeam = true }
                if y + 1 < h, valid[p + w], texelLabel[p + w] != texelLabel[p] { onSeam = true }
                guard onSeam else { continue }
                var sum = SIMD3<Float>.zero
                var n: Float = 0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                        let q = yy * w + xx
                        guard valid[q] else { continue }
                        sum += out[q]
                        n += 1
                    }
                }
                if n > 0 { feathered[p] = sum / n }
            }
        }
        color = feathered
    }
}
