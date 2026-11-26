import XCTest
import UIKit
import SceneKit
import SceneKit.ModelIO
import ModelIO
import ImageIO
import UniformTypeIdentifiers

/// Experiment (prints results, never fails): which way of writing a USDZ keeps JPEG textures as JPEG?
/// SceneKit re-encoded UIImage textures as PNG in the first real export, making the file 3–4× bigger.
final class ExportExperimentTests: XCTestCase {
    func testWhichExportKeepsJPEG() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usdz-exp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jpg = dir.appendingPathComponent("texture.jpg")
        XCTAssertTrue(Self.writeTestJPEG(to: jpg))

        func plane(_ contents: Any) -> SCNScene {
            let scene = SCNScene()
            let geometry = SCNPlane(width: 1, height: 1)
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = contents
            geometry.materials = [material]
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
            return scene
        }
        let variants: [(String, Any)] = [
            ("scenekit-url", jpg),
            ("scenekit-path", jpg.path),
            ("scenekit-uiimage", UIImage(contentsOfFile: jpg.path) as Any),
        ]
        for (name, contents) in variants {
            let out = dir.appendingPathComponent("\(name).usdz")
            let ok = plane(contents).write(to: out, options: nil, delegate: nil, progressHandler: nil)
            print("EXPERIMENT \(name): write=\(ok) entries=\(Self.zipEntries(out))")
        }

        // ModelIO export of the SceneKit scene.
        let asset = MDLAsset(scnScene: plane(jpg))
        let out = dir.appendingPathComponent("modelio.usdz")
        print("EXPERIMENT modelio-canExport-usdz=\(MDLAsset.canExportFileExtension("usdz"))")
        do {
            try asset.export(to: out)
            print("EXPERIMENT modelio: entries=\(Self.zipEntries(out))")
        } catch {
            print("EXPERIMENT modelio: failed \(error)")
        }
    }

    static func writeTestJPEG(to url: URL) -> Bool {
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = UInt8(i % 255); px[i * 4 + 1] = UInt8((i / w) * 4 % 255); px[i * 4 + 2] = 90 }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Names and sizes of the files in a zip (from its central directory).
    static func zipEntries(_ url: URL) -> [String] {
        guard let d = try? Data(contentsOf: url), d.count > 22 else { return ["(missing)"] }
        let b = [UInt8](d)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var eocd = b.count - 22
        while eocd >= 0 && u32(eocd) != 0x0605_4b50 { eocd -= 1 }
        guard eocd >= 0 else { return ["(no zip directory)"] }
        var o = u32(eocd + 16)
        var names: [String] = []
        for _ in 0..<u16(eocd + 10) {
            guard u32(o) == 0x0201_4b50 else { break }
            let size = u32(o + 24), nameLen = u16(o + 28), extra = u16(o + 30), comment = u16(o + 32)
            let name = String(decoding: b[(o + 46)..<(o + 46 + nameLen)], as: UTF8.self)
            names.append("\(name) (\(size) B)")
            o += 46 + nameLen + extra + comment
        }
        return names
    }
}
