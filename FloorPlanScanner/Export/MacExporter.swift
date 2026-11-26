import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Makes a .zip with everything needed to build a full-detail model of the house on a computer.
enum MacExporter {
    struct Input {
        let name: String
        let framesDir: URL
        let depthDir: URL
        let frameLog: URL
        let room: URL
        let roomModel: URL
        let houseModel: URL
    }

    /// Builds the zip on a background thread and returns its URL.
    static func export(_ input: Input) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try makeZip(input)
        }.value
    }

    private static func makeZip(_ input: Input) throws -> URL {
        let fm = FileManager.default
        let base = HouseStore.safeName(input.name, fallback: "House") + " scan data"
        let work = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        let folder = work.appendingPathComponent(base, isDirectory: true)
        let imagesDir = folder.appendingPathComponent("Images", isDirectory: true)
        let depthOut = folder.appendingPathComponent("Depth", isDirectory: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: depthOut, withIntermediateDirectories: true)

        var log = KeyframeLog()
        if let data = try? Data(contentsOf: input.frameLog),
           let decoded = try? JSONDecoder().decode(KeyframeLog.self, from: data) {
            log = decoded
        }

        var photos = 0
        var depths = 0
        for frame in log.frames {
            let src = input.framesDir.appendingPathComponent(frame.image)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: imagesDir.appendingPathComponent(frame.image))
            photos += 1
            if let d = frame.depth, let w = frame.depthWidth, let h = frame.depthHeight,
               let raw = try? Data(contentsOf: input.depthDir.appendingPathComponent(d)), raw.count == w * h * 2 {
                let png = depthOut.appendingPathComponent((frame.image as NSString).deletingPathExtension + "_depth.png")
                if writeDepthPNG(raw, width: w, height: h, to: png) { depths += 1 }
            }
        }

        // Camera poses in a widely used layout (one entry per photo, 4×4 camera-to-world, row-major).
        var cameras: [[String: Any]] = []
        for f in log.frames where f.transform.count == 16 && f.intrinsics.count == 4 {
            let t = f.transform
            let rows: [[Float]] = (0..<4).map { r in (0..<4).map { c in t[c * 4 + r] } }
            cameras.append([
                "file_path": "Images/\(f.image)",
                "depth_path": f.depth != nil
                    ? "Depth/\((f.image as NSString).deletingPathExtension)_depth.png" as Any
                    : NSNull() as Any,
                "transform_matrix": rows,
                "fl_x": f.intrinsics[0], "fl_y": f.intrinsics[1], "cx": f.intrinsics[2], "cy": f.intrinsics[3],
                "w": f.imageWidth, "h": f.imageHeight,
            ])
        }
        let transforms: [String: Any] = [
            "description": "Camera-to-world matrices (row-major, metres, Y up, ARKit camera: looks down -Z, +Y up, +X right). Same world as room.json.",
            "frames": cameras,
        ]
        let tData = try JSONSerialization.data(withJSONObject: transforms, options: [.prettyPrinted, .sortedKeys])
        try tData.write(to: folder.appendingPathComponent("transforms.json"))

        for (src, name) in [(input.frameLog, "frames.json"), (input.room, "room.json"),
                            (input.roomModel, "room_plain.usdz"), (input.houseModel, "house_textured.usdz")]
        where fm.fileExists(atPath: src.path) {
            try fm.copyItem(at: src, to: folder.appendingPathComponent(name))
        }

        try readme(photos: photos, depths: depths).write(to: folder.appendingPathComponent("README.txt"),
                                                         atomically: true, encoding: .utf8)

        // Zip the folder with the system's built-in zipper.
        let zip = work.appendingPathComponent(base + ".zip")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do { try fm.copyItem(at: zipped, to: zip) } catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        try? fm.removeItem(at: folder)
        return zip
    }

    /// 16-bit grayscale PNG, one value per pixel = distance from the camera in millimetres (0 = unknown).
    private static func writeDepthPNG(_ raw: Data, width: Int, height: Int, to url: URL) -> Bool {
        guard let provider = CGDataProvider(data: raw as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                                  bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func readme(photos: Int, depths: Int) -> String {
        """
        Floor Plan Scanner – house scan data
        ====================================

        Images/              \(photos) photos taken during the LiDAR scan (JPEG, 1920×1440, landscape sensor orientation).
        Depth/               \(depths) LiDAR depth maps, one per photo (16-bit PNG, millimetres, 0 = unknown, 256×192).
        transforms.json      Camera position and lens for every photo: 4×4 camera-to-world matrix (row-major,
                             metres, Y up; the camera looks down -Z with +Y up), focal length and centre in pixels.
        frames.json          The same, as the app stores it (column-major matrices).
        room.json            Apple RoomPlan result: walls, doors, windows, floors and furniture boxes, in the same
                             world coordinates as the cameras.
        room_plain.usdz      RoomPlan's own plain model.
        house_textured.usdz  The phone's textured model (if you built one).

        Building a more detailed model on a Mac
        ---------------------------------------
        1. Apple's photogrammetry (macOS 12+): run the "HelloPhotogrammetry" sample from Apple with the Images
           folder as input and detail "full" or "raw". Large houses work best one room at a time: copy the photos
           of one room into their own folder first.
        2. The cameras are already posed, so tools that accept known poses (for example Nerfstudio or other
           tools that read transforms.json, or COLMAP with known poses) can skip pose estimation, and the result
           lines up with room.json directly.
        3. Open house_textured.usdz or room_plain.usdz in Blender (File > Import > Universal Scene Description)
           to combine the detailed rooms with the plan.
        """
    }
}
