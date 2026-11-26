import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Projects the keyframes recorded during the scan onto each planar surface and writes one texture per surface.
///
/// For every 10 cm cell of a surface it picks the 3 best photos that actually see that spot (facing it,
/// close, sharp, not hidden behind another wall or piece of furniture). Every texel then blends those photos
/// (and the neighbouring cells' photos, so there are no hard seams), with a per-photo brightness
/// correction so auto-exposure differences don't show as patches.
final class TextureBaker {
    struct Options {
        /// Finest texture detail, metres per texel.
        var texelSize: Float = 0.01
        var maxTextureSize = 2048
        var cellSize: Float = 0.10
        var photosPerCell = 3
        /// Longest edge of the photos when decoded for baking (they're ~1920 px; 640 is still finer than 1 cm at room distances).
        var decodeSize = 640
        /// Photos kept decoded at once (each is about 1.2 MB at 640 px).
        var cacheCapacity = 180
        var maxDistance: Float = 7
    }

    struct BakedSurface {
        var textureURL: URL?
        /// Share of the surface's texels that a photo saw (0…1).
        var coverage: Float
        /// Average color, used when there's no texture.
        var averageColor: SIMD3<Float>
    }

    private struct Camera {
        let index: Int
        let imageURL: URL
        let depthURL: URL?
        let depthSize: (w: Int, h: Int)
        let position: SIMD3<Float>
        let worldToCamera: simd_float4x4
        let fx: Float, fy: Float, cx: Float, cy: Float
        let width: Float, height: Float
        let sharpness: Float
    }

    private struct DecodedImage {
        let pixels: [UInt8]   // RGBA8
        let width: Int
        let height: Int
        let depth: [UInt16]?
        let depthWidth: Int
        let depthHeight: Int
    }

    private struct Candidate {
        var camera: Int32
        var score: Float
    }

    private let options: Options
    private let cameras: [Camera]
    private let surfaces: [PlanarSurface]
    private let occluders: [Int]
    private var cache: [Int: DecodedImage] = [:]
    private var cacheOrder: [Int] = []
    /// Per-photo brightness correction.
    private var gains: [Float]
    /// Per-surface cell candidates, filled by `prepare`.
    private var cells: [[[Candidate]]] = []
    private var cellCounts: [(nu: Int, nv: Int)] = []

    init(surfaces: [PlanarSurface], frames: [Keyframe], framesDir: URL, depthDir: URL, options: Options = Options()) {
        self.options = options
        self.surfaces = surfaces
        self.occluders = surfaces.indices.filter { surfaces[$0].occludes }
        var cams: [Camera] = []
        for kf in frames {
            let url = framesDir.appendingPathComponent(kf.image)
            guard kf.transform.count == 16, kf.intrinsics.count == 4,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let t = kf.transform
            let m = simd_float4x4(SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                                  SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15]))
            var depthURL: URL?
            if let d = kf.depth, kf.depthWidth != nil {
                let u = depthDir.appendingPathComponent(d)
                if FileManager.default.fileExists(atPath: u.path) { depthURL = u }
            }
            cams.append(Camera(index: cams.count, imageURL: url, depthURL: depthURL,
                               depthSize: (kf.depthWidth ?? 0, kf.depthHeight ?? 0),
                               position: SIMD3(t[12], t[13], t[14]), worldToCamera: m.inverse,
                               fx: kf.intrinsics[0], fy: kf.intrinsics[1], cx: kf.intrinsics[2], cy: kf.intrinsics[3],
                               width: Float(kf.imageWidth), height: Float(kf.imageHeight),
                               sharpness: 1 / (1 + kf.turnRate / 25)))
        }
        cameras = cams
        gains = Array(repeating: 1, count: cams.count)
    }

    var photoCount: Int { cameras.count }

    // MARK: Pass 1: choose photos for every cell, and balance brightness between photos

    func prepare(progress: (Double) -> Void, isCancelled: () -> Bool) {
        cells = []
        cellCounts = []
        for (si, s) in surfaces.enumerated() {
            if isCancelled() { return }
            let nu = max(1, Int((s.size.x / options.cellSize).rounded(.up)))
            let nv = max(1, Int((s.size.y / options.cellSize).rounded(.up)))
            cellCounts.append((nu, nv))
            guard s.rendered, !cameras.isEmpty else {
                cells.append(Array(repeating: [], count: nu * nv))
                continue
            }
            let candidates = camerasSeeing(s)
            var grid = Array(repeating: [Candidate](), count: nu * nv)
            let cellSize = options.cellSize
            grid.withUnsafeMutableBufferPointer { buf in
                // Each row writes only its own slots.
                DispatchQueue.concurrentPerform(iterations: nv) { j in
                    for i in 0..<nu {
                        let p = SIMD2((Float(i) + 0.5) * cellSize, (Float(j) + 0.5) * cellSize)
                        buf[j * nu + i] = self.bestCameras(for: s.world(simd_min(p, s.size)), surface: s, among: candidates)
                    }
                }
            }
            cells.append(grid)
            progress(0.5 * Double(si + 1) / Double(surfaces.count))
        }
        if isCancelled() { return }
        balanceExposure(progress: { progress(0.5 + 0.5 * $0) }, isCancelled: isCancelled)
    }

    /// Photos that could see some of this surface (cheap test on its corners).
    private func camerasSeeing(_ s: PlanarSurface) -> [Int] {
        let corners = [SIMD2<Float>(0, 0), SIMD2(s.size.x, 0), SIMD2(s.size.x, s.size.y), SIMD2(0, s.size.y)].map(s.world)
        var result: [Int] = []
        for cam in cameras {
            // In front of the surface.
            guard simd_dot(cam.position - s.origin, s.normal) > 0.05 else { continue }
            // Close enough to some part of it.
            let lp = s.local(cam.position)
            let nearest = s.world(simd_clamp(lp, .zero, s.size))
            guard simd_distance(nearest, cam.position) < options.maxDistance else { continue }
            // Its corners' image bounding box overlaps the photo (any corner behind the camera: keep it).
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            var behind = false
            for c in corners {
                guard let px = project(c, cam, margin: -.greatestFiniteMagnitude) else { behind = true; break }
                lo = simd_min(lo, SIMD2(px.x, px.y))
                hi = simd_max(hi, SIMD2(px.x, px.y))
            }
            if !behind && (hi.x < 0 || hi.y < 0 || lo.x > cam.width || lo.y > cam.height) { continue }
            result.append(cam.index)
        }
        return result
    }

    private func bestCameras(for point: SIMD3<Float>, surface s: PlanarSurface, among list: [Int]) -> [Candidate] {
        var scored: [Candidate] = []
        for ci in list {
            let cam = cameras[ci]
            guard let w = weight(point, normal: s.normal, cam) else { continue }
            scored.append(Candidate(camera: Int32(ci), score: w))
        }
        scored.sort { $0.score > $1.score }
        var chosen: [Candidate] = []
        var tests = 0
        for c in scored {
            if chosen.count >= options.photosPerCell || tests >= 10 { break }
            tests += 1
            if !blocked(from: cameras[Int(c.camera)].position, to: point, group: s.group) {
                chosen.append(c)
            }
        }
        return chosen
    }

    /// How good a view this photo has of the point (nil = it doesn't see it).
    @inline(__always)
    private func weight(_ point: SIMD3<Float>, normal: SIMD3<Float>, _ cam: Camera) -> Float? {
        let toCam = cam.position - point
        let dist = simd_length(toCam)
        guard dist > 0.15, dist < options.maxDistance else { return nil }
        let facing = simd_dot(toCam / dist, normal)
        guard facing > 0.15, let px = project(point, cam, margin: 0.02) else { return nil }
        // Lower weight near the photo's edges, so seams fall where photos are weakest.
        let ex = min(px.x, cam.width - px.x) / (cam.width * 0.5)
        let ey = min(px.y, cam.height - px.y) / (cam.height * 0.5)
        let edge = min(1, min(ex, ey) * 3)
        return facing * facing * edge * cam.sharpness / (dist * dist + 0.3)
    }

    /// Pixel position (x, y) and depth along the camera axis, or nil if outside the photo.
    @inline(__always)
    private func project(_ p: SIMD3<Float>, _ cam: Camera, margin: Float) -> SIMD3<Float>? {
        let c = cam.worldToCamera * SIMD4(p.x, p.y, p.z, 1)
        let z = -c.z
        guard z > 0.05 else { return nil }
        let x = cam.fx * c.x / z + cam.cx
        let y = cam.fy * (-c.y) / z + cam.cy
        if margin > -1 {
            let mx = cam.width * margin, my = cam.height * margin
            guard x >= mx, y >= my, x < cam.width - mx, y < cam.height - my else { return nil }
        }
        return SIMD3(x, y, z)
    }

    /// Is the straight line from the camera to the point blocked by a wall or furniture (outside `group`)?
    private func blocked(from a: SIMD3<Float>, to b: SIMD3<Float>, group: Int) -> Bool {
        let d = b - a
        let len = simd_length(d)
        guard len > 0.05 else { return false }
        let tMax = 1 - 0.03 / len
        for oi in occluders {
            let s = surfaces[oi]
            if s.group == group { continue }
            let denom = simd_dot(d, s.normal)
            if abs(denom) < 1e-6 { continue }
            let t = simd_dot(s.origin - a, s.normal) / denom
            guard t > 0.01, t < tMax else { continue }
            let lp = s.local(a + d * t)
            if s.contains(lp) { return true }
        }
        return false
    }

    /// Estimates a brightness gain per photo so overlapping photos agree.
    private func balanceExposure(progress: (Double) -> Void, isCancelled: () -> Bool) {
        // Sample each cell centre in each of its photos.
        struct Sample { var cell: Int; var camera: Int; var luminance: Float; var weight: Float }
        var byCamera: [Int: [(cell: Int, point: SIMD3<Float>, weight: Float)]] = [:]
        var cellID = 0
        for (si, s) in surfaces.enumerated() {
            let (nu, nv) = cellCounts[si]
            for j in 0..<nv {
                for i in 0..<nu {
                    let list = cells[si][j * nu + i]
                    if list.count >= 2 {
                        let p = s.world(simd_min(SIMD2((Float(i) + 0.5) * options.cellSize, (Float(j) + 0.5) * options.cellSize), s.size))
                        for c in list { byCamera[Int(c.camera), default: []].append((cellID, p, c.score)) }
                    }
                    cellID += 1
                }
            }
        }
        var samples: [Sample] = []
        let keys = byCamera.keys.sorted()
        for (k, ci) in keys.enumerated() {
            if isCancelled() { return }
            guard let img = image(ci) else { continue }
            let cam = cameras[ci]
            for entry in byCamera[ci] ?? [] {
                guard let px = project(entry.point, cam, margin: 0) else { continue }
                let rgb = sample(img, cam, px)
                let lum = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                if lum > 0.03, lum < 0.97 { samples.append(Sample(cell: entry.cell, camera: ci, luminance: lum, weight: entry.weight)) }
            }
            if k % 20 == 0 { progress(Double(k) / Double(max(1, keys.count))) }
        }
        guard samples.count > 50 else { return }

        let samplesByCell = Dictionary(grouping: samples, by: \.cell)
        let samplesByCamera = Dictionary(grouping: samples, by: \.camera)
        for _ in 0..<4 {
            var target: [Int: Float] = [:]
            for (cell, list) in samplesByCell {
                var sum: Float = 0, wsum: Float = 0
                for s in list { sum += s.weight * gains[s.camera] * s.luminance; wsum += s.weight }
                if wsum > 0 { target[cell] = sum / wsum }
            }
            for (cam, list) in samplesByCamera {
                let ratios = list.compactMap { s in target[s.cell].map { $0 / s.luminance } }.sorted()
                guard !ratios.isEmpty else { continue }
                gains[cam] = min(2, max(0.5, ratios[ratios.count / 2]))
            }
            let sorted = gains.sorted()
            let median = sorted[sorted.count / 2]
            if median > 0 { gains = gains.map { $0 / median } }
        }
    }

    // MARK: Pass 2: bake each surface

    /// Bakes one surface into a JPEG in `directory`. Call `prepare` first.
    func bake(surfaceIndex si: Int, to directory: URL, isCancelled: () -> Bool) -> BakedSurface {
        let s = surfaces[si]
        guard si < cells.count else { return BakedSurface(textureURL: nil, coverage: 0, averageColor: s.defaultColor) }
        let texel = max(options.texelSize, max(s.size.x, s.size.y) / Float(options.maxTextureSize))
        let tw = max(4, Int((s.size.x / texel).rounded(.up)))
        let th = max(4, Int((s.size.y / texel).rounded(.up)))
        let (nu, nv) = cellCounts[si]
        let grid = cells[si]
        let cellSize = options.cellSize

        var color = [SIMD3<Float>](repeating: .zero, count: tw * th)
        var valid = [Bool](repeating: false, count: tw * th)
        var inside = [Bool](repeating: false, count: tw * th)

        // Work in bands of cell rows so only the photos one band needs are decoded at once.
        let bandRows = 6
        var band = 0
        while band < nv {
            if isCancelled() { return BakedSurface(textureURL: nil, coverage: 0, averageColor: s.defaultColor) }
            let b0 = band, b1 = min(nv, band + bandRows)
            var needed = Set<Int>()
            for j in max(0, b0 - 1)..<min(nv, b1 + 1) {
                for i in 0..<nu { for c in grid[j * nu + i] { needed.insert(Int(c.camera)) } }
            }
            let images = loadImages(needed)

            // Texel rows whose centres fall in this band (row 0 is the top of the texture = v max).
            let vLo = Float(b0) * cellSize, vHi = Float(b1) * cellSize
            let rowStart = max(0, Int(((s.size.y - vHi) / texel).rounded(.down)))
            let rowEnd = min(th, Int(((s.size.y - vLo) / texel).rounded(.up)) + 1)
            if rowStart < rowEnd {
                color.withUnsafeMutableBufferPointer { colorBuf in
                    valid.withUnsafeMutableBufferPointer { validBuf in
                        inside.withUnsafeMutableBufferPointer { insideBuf in
                            DispatchQueue.concurrentPerform(iterations: rowEnd - rowStart) { k in
                                let row = rowStart + k
                                let v = s.size.y - (Float(row) + 0.5) * texel
                                guard (v >= vLo || b0 == 0) && (v < vHi || b1 == nv) else { return }
                                for col in 0..<tw {
                                    let u = (Float(col) + 0.5) * texel
                                    let lp = SIMD2(min(u, s.size.x), max(v, 0))
                                    let idx = row * tw + col
                                    guard s.contains(lp) else { continue }
                                    insideBuf[idx] = true
                                    if let c = self.shade(s, lp, grid: grid, nu: nu, nv: nv, images: images) {
                                        colorBuf[idx] = c
                                        validBuf[idx] = true
                                    }
                                }
                            }
                        }
                    }
                }
            }
            band = b1
        }

        let insideCount = inside.filter { $0 }.count
        let seenCount = zip(valid, inside).filter { $0.0 && $0.1 }.count
        let coverage = insideCount > 0 ? Float(seenCount) / Float(insideCount) : 0

        // Average of what was seen, or the default color.
        var avg = SIMD3<Float>.zero
        if seenCount > 0 {
            for i in color.indices where valid[i] { avg += color[i] }
            avg /= Float(seenCount)
        } else {
            avg = s.defaultColor
        }
        guard seenCount > 0 else { return BakedSurface(textureURL: nil, coverage: 0, averageColor: avg) }

        // Grow seen texels into unseen ones (holes, edges, under furniture), then fill the rest.
        Self.dilate(&color, &valid, width: tw, height: th, passes: 16)
        for i in color.indices where !valid[i] { color[i] = avg }

        let url = directory.appendingPathComponent("\(s.name).jpg")
        let ok = Self.writeJPEG(color, width: tw, height: th, to: url)
        return BakedSurface(textureURL: ok ? url : nil, coverage: coverage, averageColor: avg)
    }

    /// Blended color of a texel from its cell's photos and its neighbours' (bilinear between cells).
    @inline(__always)
    private func shade(_ s: PlanarSurface, _ lp: SIMD2<Float>, grid: [[Candidate]], nu: Int, nv: Int,
                       images: [Int: DecodedImage]) -> SIMD3<Float>? {
        let point = s.world(lp)
        let fu = lp.x / options.cellSize - 0.5
        let fv = lp.y / options.cellSize - 0.5
        let i0 = Int(fu.rounded(.down)), j0 = Int(fv.rounded(.down))
        let tu = fu - Float(i0), tv = fv - Float(j0)
        var total = SIMD3<Float>.zero
        var totalW: Float = 0
        for dj in 0...1 {
            for di in 0...1 {
                let i = min(max(i0 + di, 0), nu - 1), j = min(max(j0 + dj, 0), nv - 1)
                let bw = (di == 0 ? 1 - tu : tu) * (dj == 0 ? 1 - tv : tv)
                guard bw > 1e-4 else { continue }
                var cellColor = SIMD3<Float>.zero
                var cellW: Float = 0
                for cand in grid[j * nu + i] {
                    let ci = Int(cand.camera)
                    guard let img = images[ci] else { continue }
                    let cam = cameras[ci]
                    guard let w = weight(point, normal: s.normal, cam),
                          let px = project(point, cam, margin: 0) else { continue }
                    if hiddenByDepth(px, img, cam) { continue }
                    cellColor += w * gains[ci] * sample(img, cam, px)
                    cellW += w
                }
                if cellW > 0 {
                    total += bw * (cellColor / cellW)
                    totalW += bw
                }
            }
        }
        guard totalW > 0 else { return nil }
        return simd_clamp(total / totalW, .zero, SIMD3(repeating: 1))
    }

    /// LiDAR says something is in front of this spot (it's hidden in this photo).
    @inline(__always)
    private func hiddenByDepth(_ px: SIMD3<Float>, _ img: DecodedImage, _ cam: Camera) -> Bool {
        guard let depth = img.depth, img.depthWidth > 0 else { return false }
        let dx = min(img.depthWidth - 1, max(0, Int(px.x / cam.width * Float(img.depthWidth))))
        let dy = min(img.depthHeight - 1, max(0, Int(px.y / cam.height * Float(img.depthHeight))))
        let mm = depth[dy * img.depthWidth + dx]
        guard mm > 0 else { return false }
        return Float(mm) / 1000 < px.z - 0.12
    }

    /// Bilinear color at a photo pixel position (photo pixels, scaled to the decoded size). Linear-ish 0…1.
    @inline(__always)
    private func sample(_ img: DecodedImage, _ cam: Camera, _ px: SIMD3<Float>) -> SIMD3<Float> {
        let x = px.x / cam.width * Float(img.width) - 0.5
        let y = px.y / cam.height * Float(img.height) - 0.5
        let x0 = min(max(Int(x.rounded(.down)), 0), img.width - 1)
        let y0 = min(max(Int(y.rounded(.down)), 0), img.height - 1)
        let x1 = min(x0 + 1, img.width - 1), y1 = min(y0 + 1, img.height - 1)
        let tx = min(max(x - Float(x0), 0), 1), ty = min(max(y - Float(y0), 0), 1)
        func at(_ xx: Int, _ yy: Int) -> SIMD3<Float> {
            let o = (yy * img.width + xx) * 4
            return SIMD3(Float(img.pixels[o]), Float(img.pixels[o + 1]), Float(img.pixels[o + 2])) / 255
        }
        let top = at(x0, y0) * (1 - tx) + at(x1, y0) * tx
        let bottom = at(x0, y1) * (1 - tx) + at(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    // MARK: Photo cache

    private func loadImages(_ needed: Set<Int>) -> [Int: DecodedImage] {
        var result: [Int: DecodedImage] = [:]
        for ci in needed.sorted() {
            if let img = image(ci, protecting: needed) { result[ci] = img }
        }
        return result
    }

    private func image(_ ci: Int, protecting: Set<Int> = []) -> DecodedImage? {
        if let hit = cache[ci] {
            if let k = cacheOrder.firstIndex(of: ci) { cacheOrder.remove(at: k) }
            cacheOrder.append(ci)
            return hit
        }
        guard let img = decode(cameras[ci]) else { return nil }
        while cache.count >= options.cacheCapacity,
              let k = cacheOrder.firstIndex(where: { !protecting.contains($0) }) {
            cache[cacheOrder[k]] = nil
            cacheOrder.remove(at: k)
        }
        cache[ci] = img
        cacheOrder.append(ci)
        return img
    }

    func releaseCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func decode(_ cam: Camera) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(cam.imageURL as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: options.decodeSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        var depth: [UInt16]?
        if let url = cam.depthURL, cam.depthSize.w > 0, cam.depthSize.h > 0,
           let data = try? Data(contentsOf: url), data.count == cam.depthSize.w * cam.depthSize.h * 2 {
            depth = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        }
        return DecodedImage(pixels: pixels, width: w, height: h, depth: depth,
                            depthWidth: depth == nil ? 0 : cam.depthSize.w,
                            depthHeight: depth == nil ? 0 : cam.depthSize.h)
    }

    // MARK: Image helpers

    static func dilate(_ color: inout [SIMD3<Float>], _ valid: inout [Bool], width: Int, height: Int, passes: Int) {
        for _ in 0..<passes {
            var changed = false
            var newColor = color
            var newValid = valid
            for y in 0..<height {
                for x in 0..<width where !valid[y * width + x] {
                    var sum = SIMD3<Float>.zero
                    var n: Float = 0
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < width, yy < height, valid[yy * width + xx] else { continue }
                        sum += color[yy * width + xx]
                        n += 1
                    }
                    if n > 0 {
                        newColor[y * width + x] = sum / n
                        newValid[y * width + x] = true
                        changed = true
                    }
                }
            }
            color = newColor
            valid = newValid
            if !changed { break }
        }
    }

    static func writeJPEG(_ color: [SIMD3<Float>], width: Int, height: Int, to url: URL) -> Bool {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in color.indices {
            let c = simd_clamp(color[i], .zero, SIMD3(repeating: 1)) * 255
            bytes[i * 4] = UInt8(c.x.rounded())
            bytes[i * 4 + 1] = UInt8(c.y.rounded())
            bytes[i * 4 + 2] = UInt8(c.z.rounded())
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
