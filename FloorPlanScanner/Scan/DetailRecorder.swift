import ARKit
import CoreImage
import simd

/// One LiDAR depth frame recorded during the detail pass (saved in depthframes.json), for depth fusion.
struct DepthFrame: Codable, Hashable {
    var index: Int
    /// Raw little-endian UInt16 millimetres, row-major, in DepthFrames/.
    var depth: String
    /// Raw UInt8 ARKit confidence (0 low, 1 medium, 2 high), same size, in DepthFrames/.
    var confidence: String?
    var width: Int
    var height: Int
    /// Camera-to-world, column-major 4×4 (ARKit convention).
    var transform: [Float]
    /// fx, fy, cx, cy scaled to the depth map's resolution.
    var intrinsics: [Float]
    var timestamp: Double
    var quality: Float? = nil
    /// Recorded just before tracking broke: the build skips it.
    var suspect: Bool? = nil
}

struct DepthFrameLog: Codable {
    var description = "LiDAR depth frames from the detail pass. depth = UInt16 millimetres (0 = unknown), confidence = UInt8 0/1/2, row-major. transform = camera-to-world (column-major, metres, Y up, camera looks down -Z). intrinsics = fx, fy, cx, cy at depth resolution."
    var frames: [DepthFrame] = []
    var losses: [[Float]]? = nil
}

/// Records the detail pass: dense LiDAR depth (for real 3D shapes) and 12 MP photos (for sharp textures),
/// in the same world coordinates as the RoomPlan scan before it.
@MainActor
final class DetailRecorder: ObservableObject {
    @Published private(set) var depthCount = 0
    @Published private(set) var photoCount = 0
    @Published private(set) var trackingOK = true
    /// When set, nothing is recorded unless tracking is good and steady.
    weak var monitor: TrackingMonitor?
    /// Live coverage, for the overlay.
    var coverage: CoverageGrid?

    static let maxPhotos = 400
    static let maxDepthFrames = 2500

    private var photoDir: URL?
    private var depthDir: URL?
    private var photoLogURL: URL?
    private var depthLogURL: URL?
    private var photoLog = KeyframeLog()
    private var depthLog = DepthFrameLog()

    private var lastDepthPosition: SIMD3<Float>?
    private var lastDepthForward: SIMD3<Float>?
    private var lastDepthTime: TimeInterval = 0
    private var lastPhotoPosition: SIMD3<Float>?
    private var lastPhotoForward: SIMD3<Float>?
    private var lastPhotoTime: TimeInterval = 0
    private var prevForward: SIMD3<Float>?
    private var prevTime: TimeInterval?
    private var photoInFlight = false
    private var depthInFlight = 0

    private let queue = DispatchQueue(label: "DetailRecorder.encode", qos: .userInitiated)
    private let context = CIContext()

    var photosFull: Bool { photoCount >= Self.maxPhotos }

    /// - Parameter append: keep what an earlier detail pass recorded and add to it (to fill gaps).
    func begin(photoDir: URL, depthDir: URL, photoLogURL: URL, depthLogURL: URL, append: Bool = false) {
        self.photoDir = photoDir
        self.depthDir = depthDir
        self.photoLogURL = photoLogURL
        self.depthLogURL = depthLogURL
        photoLog = KeyframeLog()
        depthLog = DepthFrameLog()
        lastDepthPosition = nil
        lastPhotoPosition = nil
        prevForward = nil
        prevTime = nil
        let fm = FileManager.default
        if append {
            let decoder = JSONDecoder()
            if let d = try? Data(contentsOf: photoLogURL), let l = try? decoder.decode(KeyframeLog.self, from: d) { photoLog = l }
            if let d = try? Data(contentsOf: depthLogURL), let l = try? decoder.decode(DepthFrameLog.self, from: d) { depthLog = l }
        }
        for d in [photoDir, depthDir] {
            if !append { try? fm.removeItem(at: d) }
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        depthCount = depthLog.frames.count
        photoCount = photoLog.frames.count
    }

    /// The detail pass's camera setup. With the room scan's world map, ARKit relocalizes into the same
    /// coordinates as the RoomPlan scan before tracking becomes normal (nothing is recorded until then).
    /// - Parameter simple: fallback without the high-resolution video format and the live mesh.
    static func configuration(worldMap: ARWorldMap?, simple: Bool) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = worldMap
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if !simple {
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }
            if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
                config.videoFormat = format
            }
        }
        return config
    }

    /// Call about 10 times a second during the detail pass.
    func tick(session: ARSession?) {
        guard let session, let frame = session.currentFrame, let depthDir, let photoDir else { return }
        guard case .normal = frame.camera.trackingState else {
            trackingOK = false
            prevForward = nil
            return
        }
        trackingOK = true
        if let monitor, !monitor.canRecord { prevForward = nil; return }
        let t = frame.camera.transform
        let position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = simd_normalize(-SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        var turnRate: Float = 0
        if let pf = prevForward, let pt = prevTime, frame.timestamp > pt {
            turnRate = FrameRecorder.degrees(between: pf, forward) / Float(frame.timestamp - pt)
        }
        prevForward = forward
        prevTime = frame.timestamp

        // Depth: after 4 cm or 3° of movement, at most 6 a second.
        if depthCount < Self.maxDepthFrames, depthInFlight < 3, frame.timestamp - lastDepthTime > 0.16,
           let sceneDepth = frame.sceneDepth {
            let moved = lastDepthPosition.map { simd_distance($0, position) } ?? .infinity
            let turned = lastDepthForward.map { FrameRecorder.degrees(between: $0, forward) } ?? .infinity
            if moved > 0.04 || turned > 3 {
                recordDepth(frame, sceneDepth, dir: depthDir)
                lastDepthPosition = position
                lastDepthForward = forward
                lastDepthTime = frame.timestamp
            }
        }

        // 12 MP photo: after 15° or 30 cm, at most one a second, only while holding fairly steady.
        if !photosFull, !photoInFlight, frame.timestamp - lastPhotoTime > 1.0, turnRate < 40 {
            let moved = lastPhotoPosition.map { simd_distance($0, position) } ?? .infinity
            let turned = lastPhotoForward.map { FrameRecorder.degrees(between: $0, forward) } ?? .infinity
            if moved > 0.3 || turned > 15 {
                lastPhotoPosition = position
                lastPhotoForward = forward
                lastPhotoTime = frame.timestamp
                capturePhoto(session, turnRate: turnRate, dir: photoDir)
                if let sceneDepth = frame.sceneDepth {
                    coverage?.add(depth: sceneDepth.depthMap, confidence: sceneDepth.confidenceMap,
                                  intrinsics: frame.camera.intrinsics, imageWidth: CVPixelBufferGetWidth(frame.capturedImage),
                                  cameraToWorld: frame.camera.transform, photo: true)
                }
            }
        }
    }

    func finish() {
        writeLogs()
    }

    /// Tracking broke at `time`: what was recorded in the second before may have drifted, so flag it.
    func trackingBroke(at time: TimeInterval, position: SIMD3<Float>?) {
        for i in depthLog.frames.indices where depthLog.frames[i].timestamp > time - 1.0 { depthLog.frames[i].suspect = true }
        for i in photoLog.frames.indices where photoLog.frames[i].timestamp > time - 1.0 { photoLog.frames[i].suspect = true }
        if let p = position { depthLog.losses = (depthLog.losses ?? []) + [[p.x, p.y, p.z]] }
    }

    // MARK: Private

    private func recordDepth(_ frame: ARFrame, _ sceneDepth: ARDepthData, dir: URL) {
        guard let depth = FrameRecorder.depthMillimetres(sceneDepth.depthMap) else { return }
        let confidence = sceneDepth.confidenceMap.flatMap(Self.bytes)
        let index = depthLog.frames.count
        let stem = String(format: "d%05d", index)
        let image = CVPixelBufferGetWidth(frame.capturedImage)
        let scale = Float(depth.width) / Float(image)
        let k = frame.camera.intrinsics
        let entry = DepthFrame(index: index, depth: stem + ".depth", confidence: confidence == nil ? nil : stem + ".conf",
                               width: depth.width, height: depth.height, transform: Self.flatten(frame.camera.transform),
                               intrinsics: [k.columns.0.x * scale, k.columns.1.y * scale, k.columns.2.x * scale, k.columns.2.y * scale],
                               timestamp: frame.timestamp, quality: monitor?.quality)
        depthLog.frames.append(entry)
        coverage?.add(depth: sceneDepth.depthMap, confidence: sceneDepth.confidenceMap,
                      intrinsics: k, imageWidth: image, cameraToWorld: frame.camera.transform, photo: false)
        depthCount = depthLog.frames.count
        depthInFlight += 1
        let depthURL = dir.appendingPathComponent(entry.depth)
        let confURL = entry.confidence.map { dir.appendingPathComponent($0) }
        queue.async { [weak self] in
            try? depth.data.write(to: depthURL)
            if let confidence, let confURL { try? confidence.write(to: confURL) }
            Task { @MainActor in self?.depthInFlight -= 1 }
        }
        if depthCount % 100 == 0 { writeLogs() }
    }

    private func capturePhoto(_ session: ARSession, turnRate: Float, dir: URL) {
        photoInFlight = true
        session.captureHighResolutionFrame { [weak self] frame, error in
            guard let self else { return }
            guard let frame else {
                Task { @MainActor in self.photoInFlight = false }
                if let error { print("High-res capture failed: \(error)") }
                return
            }
            Task { @MainActor in self.savePhoto(frame, turnRate: turnRate, dir: dir) }
        }
    }

    private func savePhoto(_ frame: ARFrame, turnRate: Float, dir: URL) {
        let index = photoLog.frames.count
        let name = String(format: "h%04d.heic", index)
        let buffer = frame.capturedImage
        let k = frame.camera.intrinsics
        let keyframe = Keyframe(index: index, image: name, depth: nil, depthWidth: nil, depthHeight: nil,
                                imageWidth: CVPixelBufferGetWidth(buffer), imageHeight: CVPixelBufferGetHeight(buffer),
                                transform: Self.flatten(frame.camera.transform),
                                intrinsics: [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y],
                                timestamp: frame.timestamp, turnRate: turnRate, quality: monitor?.quality)
        photoLog.frames.append(keyframe)
        photoCount = photoLog.frames.count
        let image = CIImage(cvPixelBuffer: buffer)
        let url = dir.appendingPathComponent(name)
        let context = self.context
        queue.async { [weak self] in
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]
            if let data = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: options) {
                try? data.write(to: url, options: .atomic)
            }
            Task { @MainActor in self?.photoInFlight = false }
        }
        if photoCount % 10 == 0 { writeLogs() }
    }

    private func writeLogs() {
        let encoder = JSONEncoder()
        if let url = photoLogURL, let data = try? encoder.encode(photoLog) { try? data.write(to: url, options: .atomic) }
        if let url = depthLogURL, let data = try? encoder.encode(depthLog) { try? data.write(to: url, options: .atomic) }
    }

    private static func flatten(_ t: simd_float4x4) -> [Float] {
        [t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
         t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
         t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
         t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w]
    }

    /// Copies a one-byte-per-pixel buffer (the confidence map).
    private static func bytes(_ buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var out = Data(capacity: width * height)
        for y in 0..<height {
            out.append(base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self), count: width)
        }
        return out
    }
}
