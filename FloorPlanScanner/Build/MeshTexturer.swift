import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Textures a reconstructed mesh from the scan photos, after Waechter et al., "Let There Be Color!" (2014):
/// 1. **Visibility**: each photo gets a small z-buffer of the whole house (mesh + walls + floors), so a face is
///    only textured from photos that really see it.
/// 2. **View selection**: an MRF on the face graph picks one photo per face: large, sharp, head-on views win,
///    and neighbouring faces prefer the same photo.
/// 3. **Charts + atlas**: connected faces with the same photo become a chart, cut straight out of that photo
///    at full decoded resolution and packed into 4096 px atlas pages.
/// 4. **Seam leveling**: a color offset per chart makes neighbouring charts agree.
extension TextureBaker {
    struct MeshPart {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        var indices: [UInt32]
        /// Atlas page image, or nil for faces no photo saw (drawn with `color`).
        var textureURL: URL?
        var color: SIMD3<Float>
    }

    struct MeshTextureResult {
        var parts: [MeshPart]
        /// Texture resolution relative to the decoded photos (1 = full; lower if the atlas budget forced scaling).
        var scale: Float
        /// Share of mesh faces no photo saw at all.
        var unseenShare: Float
        /// Centres of (a sample of) those faces, for the coverage map.
        var unseenPoints: [SIMD3<Float>] = []
    }

    func textureMesh(_ mesh: ReconMesh, directory: URL, pageSize: Int = 4096, maxPages: Int = 6,
                     progress: (Double, String) -> Void, isCancelled: () -> Bool) -> MeshTextureResult {
        let empty = MeshTextureResult(parts: [], scale: 0, unseenShare: 1)
        let faceCount = mesh.triangleCount
        guard faceCount > 0 else { return empty }
        let normals = mesh.vertexNormals()
        let faceNormals = (0..<faceCount).map { mesh.faceNormal($0) }
        let centroids: [SIMD3<Float>] = (0..<faceCount).map { t in
            let (a, b, c) = mesh.triangle(t)
            return (mesh.positions[a] + mesh.positions[b] + mesh.positions[c]) / 3
        }

        // 1. Occlusion scene: the mesh plus the walls and floors, tessellated so big planes clip well.
        progress(0, "Working out what each photo sees…")
        var scene = mesh
        for s in surfaces where s.rendered && (s.kind == .wall || s.kind == .floor || s.kind == .ceiling) {
            appendTessellated(s, to: &scene, cell: 0.3)
        }

        // 2. Candidate photos per face, from per-photo z-buffers (in chunks to bound memory).
        let keep = 6
        var candidates = [[(Int32, Float)]](repeating: [], count: faceCount)
        // Fallback views for faces no photo sees clearly (looser angle and occlusion tests), used only for those.
        var relaxed = [[(Int32, Float)]](repeating: [], count: faceCount)
        let chunk = 24
        var start = 0
        while start < cameras.count {
            if isCancelled() { return empty }
            let end = min(cameras.count, start + chunk)
            var results = [[(Int32, Float, Bool)]](repeating: [], count: end - start)   // (face, score, strict) per camera
            results.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: end - start) { k in
                    out[k] = self.visibleFaces(camera: start + k, mesh: mesh, faceNormals: faceNormals,
                                               centroids: centroids, scene: scene)
                }
            }
            for (k, list) in results.enumerated() {
                let ci = Int32(start + k)
                for (face, score, strict) in list {
                    var c = strict ? candidates[Int(face)] : relaxed[Int(face)]
                    if c.count < keep {
                        c.append((ci, score))
                    } else if let worst = c.indices.min(by: { c[$0].1 < c[$1].1 }), c[worst].1 < score {
                        c[worst] = (ci, score)
                    } else {
                        continue
                    }
                    if strict { candidates[Int(face)] = c } else { relaxed[Int(face)] = c }
                }
            }
            start = end
            progress(0.35 * Double(start) / Double(cameras.count), "Working out what each photo sees…")
        }
        for f in 0..<faceCount {
            if candidates[f].isEmpty { candidates[f] = relaxed[f] }
            candidates[f].sort { $0.1 > $1.1 }
        }
        relaxed = []

        // 3. View selection.
        progress(0.36, "Choosing the sharpest photo for every surface…")
        let adjacency = mesh.faceAdjacency()
        let labels = ViewSelection.solveGraph(labels: candidates.map { $0.map(\.0) },
                                              scores: candidates.map { $0.map(\.1) }, neighbours: adjacency)
        if isCancelled() { return empty }

        // 4. Charts: connected faces with the same photo, kept under 1024 px so atlases pack well.
        progress(0.42, "Cutting textures out of the photos…")
        var chartOf = [Int32](repeating: -1, count: faceCount)
        var charts: [Chart] = []
        var cornerPixels = [SIMD2<Float>](repeating: .zero, count: faceCount * 3)   // decoded-photo pixels
        for seed in 0..<faceCount where chartOf[seed] < 0 && labels[seed] >= 0 {
            let ci = Int(labels[seed])
            let cam = cameras[ci]
            let scale = decodedScale(cam)
            var chart = Chart(camera: ci, faces: [])
            var queue = [seed]
            chartOf[seed] = Int32(charts.count)
            var head = 0
            while head < queue.count {
                let f = queue[head]
                head += 1
                let (a, b, c) = mesh.triangle(f)
                var pts: [SIMD2<Float>] = []
                for v in [a, b, c] {
                    let p = project(mesh.positions[v], cam, margin: -.greatestFiniteMagnitude)
                    pts.append(p.map { SIMD2($0.x, $0.y) * scale } ?? .zero)
                }
                var lo = chart.lo, hi = chart.hi
                for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
                if !chart.faces.isEmpty && (hi.x - lo.x > 1024 || hi.y - lo.y > 1024) {
                    chartOf[f] = -1   // too big: leave for another chart
                    continue
                }
                chart.lo = lo
                chart.hi = hi
                chart.faces.append(f)
                for k in 0..<3 { cornerPixels[f * 3 + k] = pts[k] }
                for nb in adjacency[f] where chartOf[Int(nb)] < 0 && labels[Int(nb)] == labels[f] {
                    chartOf[Int(nb)] = Int32(charts.count)
                    queue.append(Int(nb))
                }
            }
            charts.append(chart)
        }
        // Faces whose chart filled up were reset to −1 above; give each leftover its own chart.
        for f in 0..<faceCount where chartOf[f] < 0 && labels[f] >= 0 {
            let ci = Int(labels[f])
            let cam = cameras[ci]
            let scale = decodedScale(cam)
            var chart = Chart(camera: ci, faces: [f])
            let (a, b, c) = mesh.triangle(f)
            for (k, v) in [a, b, c].enumerated() {
                let p = project(mesh.positions[v], cam, margin: -.greatestFiniteMagnitude)
                let px = p.map { SIMD2($0.x, $0.y) * scale } ?? .zero
                cornerPixels[f * 3 + k] = px
                chart.lo = simd_min(chart.lo, px)
                chart.hi = simd_max(chart.hi, px)
            }
            chartOf[f] = Int32(charts.count)
            charts.append(chart)
        }

        // 5. Seam leveling between charts: compare both photos along shared edges.
        progress(0.5, "Evening out colors between photos…")
        let offsets = levelCharts(mesh: mesh, charts: charts, chartOf: chartOf, adjacency: adjacency)
        if isCancelled() { return empty }

        // 6. Atlas layout: scale everything down evenly if it would need more than `maxPages` pages.
        let pad = 2
        var totalArea: Double = 0
        for c in charts { totalArea += Double(c.hi.x - c.lo.x + 1) * Double(c.hi.y - c.lo.y + 1) }
        let capacity = Double(maxPages * pageSize * pageSize) * 0.72
        let scale = Float(min(1, (capacity / max(totalArea, 1)).squareRoot()))
        let sizes: [(w: Int, h: Int)] = charts.map { c in
            (Int(((c.hi.x - c.lo.x) * scale).rounded(.up)) + 1 + 2 * pad,
             Int(((c.hi.y - c.lo.y) * scale).rounded(.up)) + 1 + 2 * pad)
        }
        let (placements, pageCount) = AtlasPacker.pack(sizes, pageSize: pageSize)

        // 7. Fill each page from the photos and write it.
        var parts: [MeshPart] = []
        var colorSum = SIMD3<Float>.zero, colorCount: Float = 0
        // Shared-vertex bookkeeping: a vertex keeps one index per chart (its UV is the same everywhere in a chart).
        var vertexSlot = [UInt32](repeating: 0, count: mesh.positions.count)
        var vertexStamp = [Int32](repeating: -1, count: mesh.positions.count)
        let chartsByPage = Dictionary(grouping: charts.indices, by: { placements[$0].page })
        for page in 0..<pageCount {
            if isCancelled() { return empty }
            progress(0.55 + 0.4 * Double(page) / Double(max(1, pageCount)), "Painting texture page \(page + 1) of \(pageCount)…")
            let list = chartsByPage[page] ?? []
            var pixels = [UInt8](repeating: 0, count: pageSize * pageSize * 4)
            // Group by photo so each photo is decoded once per page.
            let byCamera = Dictionary(grouping: list, by: { charts[$0].camera })
            for (ci, chartList) in byCamera {
                guard let img = image(ci) else { continue }
                let cam = cameras[ci]
                let dscale = decodedScale(cam)
                let gain = gains[ci]
                pixels.withUnsafeMutableBufferPointer { buf in
                    DispatchQueue.concurrentPerform(iterations: chartList.count) { k in
                        let chartIndex = chartList[k]
                        let chart = charts[chartIndex]
                        let place = placements[chartIndex]
                        let size = sizes[chartIndex]
                        let offset = offsets[chartIndex]
                        for yy in 0..<size.h {
                            let ay = place.y + yy
                            guard ay < pageSize else { break }
                            for xx in 0..<size.w {
                                let ax = place.x + xx
                                guard ax < pageSize else { break }
                                // Atlas pixel → decoded photo pixel → photo pixel.
                                let sx = chart.lo.x + (Float(xx - pad) + 0.5) / scale
                                let sy = chart.lo.y + (Float(yy - pad) + 0.5) / scale
                                let px = SIMD3<Float>(sx / dscale, sy / dscale, 1)
                                let c = simd_clamp(gain * self.sample(img, cam, px) + offset, .zero, SIMD3(repeating: 1)) * 255
                                let o = (ay * pageSize + ax) * 4
                                buf[o] = UInt8(c.x.rounded())
                                buf[o + 1] = UInt8(c.y.rounded())
                                buf[o + 2] = UInt8(c.z.rounded())
                                buf[o + 3] = 255
                            }
                        }
                    }
                }
            }
            var o = 0
            while o < pixels.count {
                if pixels[o + 3] != 0 {
                    colorSum += SIMD3(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2])) / 255
                    colorCount += 1
                }
                o += 4 * 997
            }
            let url = directory.appendingPathComponent("mesh_atlas_\(page).jpg")
            guard Self.writeRGBA(pixels, width: pageSize, height: pageSize, to: url) else { continue }

            // Geometry for this page; vertices are shared within a chart.
            var part = MeshPart(positions: [], normals: [], uvs: [], indices: [], textureURL: url, color: .zero)
            let ps = Float(pageSize)
            for chartIndex in list {
                let chart = charts[chartIndex]
                let place = placements[chartIndex]
                let stamp = Int32(chartIndex)
                for f in chart.faces {
                    let (a, b, c) = mesh.triangle(f)
                    for (k, v) in [a, b, c].enumerated() {
                        if vertexStamp[v] == stamp {
                            part.indices.append(vertexSlot[v])
                            continue
                        }
                        let p = cornerPixels[f * 3 + k]
                        let u = (Float(place.x + pad) + (p.x - chart.lo.x) * scale) / ps
                        let w = (Float(place.y + pad) + (p.y - chart.lo.y) * scale) / ps
                        vertexStamp[v] = stamp
                        vertexSlot[v] = UInt32(part.positions.count)
                        part.indices.append(vertexSlot[v])
                        part.positions.append(mesh.positions[v])
                        part.normals.append(normals[v])
                        part.uvs.append(SIMD2(u, w))
                    }
                }
            }
            parts.append(part)
        }

        // 8. Faces no photo saw: one plain part in the mesh's average color.
        var unseen = MeshPart(positions: [], normals: [], uvs: [], indices: [], textureURL: nil,
                              color: colorCount > 0 ? colorSum / colorCount : SIMD3(repeating: 0.6))
        var unseenFaces = 0
        let unseenStamp = Int32(charts.count)
        var unseenPoints: [SIMD3<Float>] = []
        for f in 0..<faceCount where labels[f] < 0 {
            unseenFaces += 1
            if unseenFaces % 4 == 0 { unseenPoints.append(centroids[f]) }
            let (a, b, c) = mesh.triangle(f)
            for v in [a, b, c] {
                if vertexStamp[v] == unseenStamp {
                    unseen.indices.append(vertexSlot[v])
                    continue
                }
                vertexStamp[v] = unseenStamp
                vertexSlot[v] = UInt32(unseen.positions.count)
                unseen.indices.append(vertexSlot[v])
                unseen.positions.append(mesh.positions[v])
                unseen.normals.append(normals[v])
                unseen.uvs.append(.zero)
            }
        }
        if !unseen.indices.isEmpty { parts.append(unseen) }
        progress(1, "Mesh textured")
        return MeshTextureResult(parts: parts, scale: scale, unseenShare: Float(unseenFaces) / Float(faceCount),
                                 unseenPoints: unseenPoints)
    }

    // MARK: Helpers

    struct Chart {
        var camera: Int
        var faces: [Int]
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
    }

    /// Decoded image size relative to the photo's own pixel size.
    func decodedScale(_ cam: Camera) -> Float {
        min(1, Float(cam.decodeSize) / max(cam.width, cam.height))
    }

    /// Faces this photo sees, with a quality score (projected size × sharpness × how head-on).
    private func visibleFaces(camera ci: Int, mesh: ReconMesh, faceNormals: [SIMD3<Float>],
                              centroids: [SIMD3<Float>], scene: ReconMesh) -> [(Int32, Float, Bool)] {
        let cam = cameras[ci]
        let zw = 320, zh = 240
        let zbuf = depthBuffer(cam, scene: scene, width: zw, height: zh)
        let sx = Float(zw) / cam.width, sy = Float(zh) / cam.height
        let resolution = decodedScale(cam)
        var out: [(Int32, Float, Bool)] = []
        for f in 0..<mesh.triangleCount {
            let c = centroids[f]
            let toCam = cam.position - c
            let dist = simd_length(toCam)
            guard dist > 0.15, dist < 6 else { continue }
            let facing = simd_dot(toCam / dist, faceNormals[f])
            guard facing > 0.05, let pc = project(c, cam, margin: 0) else { continue }
            // Hidden behind something nearer in this photo? (Strict test, or a loose one for the fallback list.)
            let zx = min(zw - 1, Int(pc.x * sx)), zy = min(zh - 1, Int(pc.y * sy))
            let excess = pc.z - zbuf[zy * zw + zx]
            if excess > 0.25 + 0.05 * pc.z { continue }
            let strict = facing > 0.2 && dist < 5 && excess <= 0.04 + 0.02 * pc.z
            let (a, b, d) = mesh.triangle(f)
            guard let pa = project(mesh.positions[a], cam, margin: 0),
                  let pb = project(mesh.positions[b], cam, margin: 0),
                  let pd = project(mesh.positions[d], cam, margin: 0) else { continue }
            let area = abs((pb.x - pa.x) * (pd.y - pa.y) - (pd.x - pa.x) * (pb.y - pa.y)) / 2
            let score = area * resolution * resolution * cam.sharpness * facing
            if score > 0 { out.append((Int32(f), strict ? score : score * 0.01, strict)) }
        }
        return out
    }

    /// Nearest-surface depth (camera axis, metres) per pixel of a small buffer.
    func depthBuffer(_ cam: Camera, scene: ReconMesh, width w: Int, height h: Int) -> [Float] {
        var zbuf = [Float](repeating: .greatestFiniteMagnitude, count: w * h)
        let sx = Float(w) / cam.width, sy = Float(h) / cam.height
        var projected = [SIMD3<Float>?](repeating: nil, count: scene.positions.count)
        for i in scene.positions.indices {
            if let p = project(scene.positions[i], cam, margin: -.greatestFiniteMagnitude) {
                projected[i] = SIMD3(p.x * sx, p.y * sy, p.z)
            }
        }
        for t in 0..<scene.triangleCount {
            let (ia, ib, ic) = scene.triangle(t)
            guard let a = projected[ia], let b = projected[ib], let c = projected[ic] else { continue }
            let minX = max(0, Int(min(a.x, b.x, c.x).rounded(.down)))
            let maxX = min(w - 1, Int(max(a.x, b.x, c.x).rounded(.up)))
            let minY = max(0, Int(min(a.y, b.y, c.y).rounded(.down)))
            let maxY = min(h - 1, Int(max(a.y, b.y, c.y).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { continue }
            let area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            if abs(area) < 1 {
                // Sub-pixel triangle: splat its nearest depth.
                let x = min(w - 1, max(0, Int((a.x + b.x + c.x) / 3)))
                let y = min(h - 1, max(0, Int((a.y + b.y + c.y) / 3)))
                let z = min(a.z, b.z, c.z)
                if z < zbuf[y * w + x] { zbuf[y * w + x] = z }
                continue
            }
            for y in minY...maxY {
                let py = Float(y) + 0.5
                for x in minX...maxX {
                    let px = Float(x) + 0.5
                    let w0 = ((b.x - px) * (c.y - py) - (c.x - px) * (b.y - py)) / area
                    let w1 = ((c.x - px) * (a.y - py) - (a.x - px) * (c.y - py)) / area
                    let w2 = 1 - w0 - w1
                    guard w0 >= -0.01, w1 >= -0.01, w2 >= -0.01 else { continue }
                    let z = w0 * a.z + w1 * b.z + w2 * c.z
                    if z < zbuf[y * w + x] { zbuf[y * w + x] = z }
                }
            }
        }
        return zbuf
    }

    /// Adds a plane's area to the occlusion scene as small triangles (so planes crossing the camera still clip).
    func appendTessellated(_ s: PlanarSurface, to mesh: inout ReconMesh, cell: Float) {
        let nu = max(1, Int((s.size.x / cell).rounded(.up))), nv = max(1, Int((s.size.y / cell).rounded(.up)))
        let du = s.size.x / Float(nu), dv = s.size.y / Float(nv)
        for j in 0..<nv {
            for i in 0..<nu {
                let u0 = Float(i) * du, v0 = Float(j) * dv
                guard s.contains(SIMD2(u0 + du / 2, v0 + dv / 2)) else { continue }
                let base = UInt32(mesh.positions.count)
                mesh.positions += [s.world(SIMD2(u0, v0)), s.world(SIMD2(u0 + du, v0)),
                                   s.world(SIMD2(u0 + du, v0 + dv)), s.world(SIMD2(u0, v0 + dv))]
                mesh.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }
    }

    /// Chart color offsets from the color difference of the two photos along shared edges.
    private func levelCharts(mesh: ReconMesh, charts: [Chart], chartOf: [Int32], adjacency: [[Int32]]) -> [SIMD3<Float>] {
        // Sample points: midpoints of faces on chart borders, seen by both charts' photos.
        struct Pair: Hashable { var a: Int; var b: Int }
        var points: [(pair: Pair, point: SIMD3<Float>)] = []
        for f in 0..<mesh.triangleCount where chartOf[f] >= 0 {
            for nb in adjacency[f] where Int(nb) > f && chartOf[Int(nb)] >= 0 && chartOf[Int(nb)] != chartOf[f] {
                let ca = Int(chartOf[f]), cb = Int(chartOf[Int(nb)])
                guard charts[ca].camera != charts[cb].camera else { continue }
                let (a, b, c) = mesh.triangle(f)
                let (d, e, g) = mesh.triangle(Int(nb))
                let p = (mesh.positions[a] + mesh.positions[b] + mesh.positions[c]
                         + mesh.positions[d] + mesh.positions[e] + mesh.positions[g]) / 6
                points.append((Pair(a: min(ca, cb), b: max(ca, cb)), p))
            }
        }
        guard !points.isEmpty else { return Array(repeating: .zero, count: charts.count) }
        if points.count > 60_000 { points = Array(points.prefix(60_000)) }

        // Sample each point in both photos, grouped by photo.
        var colorA = [SIMD3<Float>?](repeating: nil, count: points.count)
        var colorB = [SIMD3<Float>?](repeating: nil, count: points.count)
        var byCamera: [Int: [(Int, Bool)]] = [:]   // camera → (point index, is side a)
        for (i, entry) in points.enumerated() {
            byCamera[charts[entry.pair.a].camera, default: []].append((i, true))
            byCamera[charts[entry.pair.b].camera, default: []].append((i, false))
        }
        for (ci, list) in byCamera {
            guard let img = image(ci) else { continue }
            let cam = cameras[ci]
            for (i, isA) in list {
                guard let px = project(points[i].point, cam, margin: 0) else { continue }
                let c = gains[ci] * sample(img, cam, px)
                if isA { colorA[i] = c } else { colorB[i] = c }
            }
        }
        var sums: [Pair: (SIMD3<Float>, Float)] = [:]
        for (i, entry) in points.enumerated() {
            guard let a = colorA[i], let b = colorB[i] else { continue }
            let prev = sums[entry.pair] ?? (.zero, 0)
            sums[entry.pair] = (prev.0 + (a - b), prev.1 + 1)
        }
        let constraints: [(Int, Int, SIMD3<Float>, Float)] = sums.map { (pair, v) in (pair.a, pair.b, v.0 / v.1, v.1) }
        return ViewSelection.levelPatches(patchCount: charts.count, constraints: constraints)
    }

    static func writeRGBA(_ bytes: [UInt8], width: Int, height: Int, to url: URL) -> Bool {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
