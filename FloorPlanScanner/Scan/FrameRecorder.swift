import ARKit
import CoreImage
import simd

/// Records keyframes (photo + LiDAR depth + camera pose) from the RoomPlan scan's AR session.
/// These photos are later projected onto the walls, floors and furniture to give them real colors.
///
/// It only reads `currentFrame` on a timer and never becomes the session's delegate, so RoomPlan
/// keeps full control of its own session.
@MainActor
final class FrameRecorder: ObservableObject {
    @Published private(set) var count = 0
    @Published private(set) var depthCount = 0

    static let maxFrames = 800
    /// Keep a new photo after turning this far…
    private let minDegrees: Float = 12
    /// …or moving this far (metres) since the last one.
    private let minMetres: Float = 0.25
    /// Skip photos taken while turning faster than this (degrees per second): they'd be blurry.
    private let maxTurnRate: Float = 70

    var nearLimit: Bool { count >= Int(Double(Self.maxFrames) * 0.85) }
    var isFull: Bool { count >= Self.maxFrames }

    private var framesDir: URL?
    private var depthDir: URL?
    private var logURL: URL?
    private var log = KeyframeLog()

    private var lastKeptPosition: SIMD3<Float>?
    private var lastKeptForward: SIMD3<Float>?
    private var prevForward: SIMD3<Float>?
    private var prevTime: TimeInterval?
    private var lastTimestamp: TimeInterval = -1
    private var inFlight = 0

    private let queue = DispatchQueue(label: "FrameRecorder.encode", qos: .userInitiated)
    private let context = CIContext()

    func begin(framesDir: URL, depthDir: URL, logURL: URL) {
        self.framesDir = framesDir
        self.depthDir = depthDir
        self.logURL = logURL
        log = KeyframeLog()
        count = 0
        depthCount = 0
        lastKeptPosition = nil
        lastKeptForward = nil
        prevForward = nil
        prevTime = nil
        lastTimestamp = -1
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: depthDir, withIntermediateDirectories: true)
    }

    /// Call often (about 10 times a second) while scanning.
    func tick(session: ARSession?) {
        guard let framesDir, let depthDir, !isFull, let frame = session?.currentFrame else { return }
        guard frame.timestamp != lastTimestamp else { return }
        lastTimestamp = frame.timestamp

        guard case .normal = frame.camera.trackingState else {
            prevForward = nil
            prevTime = nil
            return
        }

        let t = frame.camera.transform
        let position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = simd_normalize(-SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))

        var turnRate: Float = 0
        if let pf = prevForward, let pt = prevTime, frame.timestamp > pt {
            turnRate = Self.degrees(between: pf, forward) / Float(frame.timestamp - pt)
        }
        prevForward = forward
        prevTime = frame.timestamp

        if let lp = lastKeptPosition, let lf = lastKeptForward {
            let turned = Self.degrees(between: lf, forward)
            let moved = simd_distance(lp, position)
            guard turned >= minDegrees || moved >= minMetres else { return }
        }
        guard turnRate < maxTurnRate, inFlight < 2 else { return }

        record(frame, turnRate: turnRate, framesDir: framesDir, depthDir: depthDir)
        lastKeptPosition = position
        lastKeptForward = forward
    }

    /// Writes frames.json. Call when the scan is done.
    func finish() {
        writeLog()
    }

    // MARK: Private

    private func record(_ frame: ARFrame, turnRate: Float, framesDir: URL, depthDir: URL) {
        let index = log.frames.count
        let stem = String(format: "%04d", index)
        let pixelBuffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let k = frame.camera.intrinsics
        let t = frame.camera.transform
        let transform: [Float] = [
            t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
        ]

        // Copy the small depth map now, so the AR frame isn't held on to.
        var depth: (data: Data, width: Int, height: Int)?
        if let sceneDepth = frame.sceneDepth ?? frame.smoothedSceneDepth {
            depth = Self.depthMillimetres(sceneDepth.depthMap)
        }

        var keyframe = Keyframe(index: index, image: stem + ".jpg", depth: nil, depthWidth: nil, depthHeight: nil,
                                imageWidth: width, imageHeight: height, transform: transform,
                                intrinsics: [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y],
                                timestamp: frame.timestamp, turnRate: turnRate)
        if let depth {
            keyframe.depth = stem + ".depth"
            keyframe.depthWidth = depth.width
            keyframe.depthHeight = depth.height
            depthCount += 1
        }
        log.frames.append(keyframe)
        count = log.frames.count

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let imageURL = framesDir.appendingPathComponent(keyframe.image)
        let depthURL = keyframe.depth.map { depthDir.appendingPathComponent($0) }
        let context = self.context
        inFlight += 1
        queue.async { [weak self] in
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]
            if let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) {
                try? jpeg.write(to: imageURL, options: .atomic)
            }
            if let depth, let depthURL {
                try? depth.data.write(to: depthURL, options: .atomic)
            }
            Task { @MainActor in
                guard let self else { return }
                self.inFlight -= 1
            }
        }

        // Save the log now and then, so a crash mid-scan keeps most of the photos usable.
        if count % 25 == 0 { writeLog() }
    }

    private func writeLog() {
        guard let logURL else { return }
        do {
            let data = try JSONEncoder().encode(log)
            try data.write(to: logURL, options: .atomic)
        } catch {
            print("Failed to save frames.json: \(error)")
        }
    }

    private static func degrees(between a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(min(1, max(-1, simd_dot(a, b)))) * 180 / .pi
    }

    /// Float32 metres → UInt16 millimetres (0 = unknown), row-major.
    private static func depthMillimetres(_ buffer: CVPixelBuffer) -> (data: Data, width: Int, height: Int)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let metres = row[x]
                if metres.isFinite, metres > 0 {
                    pixels[y * width + x] = UInt16(min(65535, (metres * 1000).rounded()))
                }
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return (data, width, height)
    }
}
