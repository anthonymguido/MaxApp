import Foundation
import SwiftUI

enum HouseStatus: String, Codable {
    case scanning   // the scanner is open (or the app quit mid-scan)
    case scanned    // RoomPlan result + photos saved, no textured model yet
    case building   // projecting photos onto the house
    case ready      // house.usdz exists
    case failed

    var title: String {
        switch self {
        case .scanning: return "Scanning"
        case .scanned: return "Scan ready"
        case .building: return "Building…"
        case .ready: return "Model ready"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .scanning, .building: return .orange
        case .scanned: return .blue
        case .ready: return .green
        case .failed: return .red
        }
    }

    var symbol: String {
        switch self {
        case .scanning: return "viewfinder"
        case .scanned: return "square.split.bottomrightquarter"
        case .building: return "gearshape.2"
        case .ready: return "house.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// A detailed photogrammetry model (from the furniture capture) that replaces one RoomPlan box.
struct FurnitureDetail: Codable, Hashable, Identifiable {
    /// The RoomPlan object's identifier.
    var objectID: UUID
    /// The object scan (in ScanStore) whose model.usdz is used.
    var scanID: UUID
    var label: String
    /// Extra rotation the user added, in 90° steps.
    var quarterTurns: Int = 0

    var id: UUID { objectID }
}

struct House: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var date = Date()
    var status: HouseStatus = .scanning
    var frameCount = 0
    var depthCount = 0
    var wallCount = 0
    var doorCount = 0
    var windowCount = 0
    var objectCount = 0
    var includeCeilings = false
    /// Detail pass: 12 MP photos and LiDAR depth frames recorded after the RoomPlan scan.
    var hasDetailPass = false
    var highResCount = 0
    var depthFrameCount = 0
    var details: [FurnitureDetail] = []
    var errorMessage: String?
    /// Something to know about the last build, shown on the house page.
    var buildNote: String?

    init(name: String) {
        self.name = name
    }

    // Tolerant decoding, so fields added later don't wipe older saves.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled house"
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        status = (try? c.decodeIfPresent(HouseStatus.self, forKey: .status)) ?? .scanned
        frameCount = try c.decodeIfPresent(Int.self, forKey: .frameCount) ?? 0
        depthCount = try c.decodeIfPresent(Int.self, forKey: .depthCount) ?? 0
        wallCount = try c.decodeIfPresent(Int.self, forKey: .wallCount) ?? 0
        doorCount = try c.decodeIfPresent(Int.self, forKey: .doorCount) ?? 0
        windowCount = try c.decodeIfPresent(Int.self, forKey: .windowCount) ?? 0
        objectCount = try c.decodeIfPresent(Int.self, forKey: .objectCount) ?? 0
        includeCeilings = try c.decodeIfPresent(Bool.self, forKey: .includeCeilings) ?? false
        hasDetailPass = try c.decodeIfPresent(Bool.self, forKey: .hasDetailPass) ?? false
        highResCount = try c.decodeIfPresent(Int.self, forKey: .highResCount) ?? 0
        depthFrameCount = try c.decodeIfPresent(Int.self, forKey: .depthFrameCount) ?? 0
        details = (try? c.decodeIfPresent([FurnitureDetail].self, forKey: .details)) ?? []
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        buildNote = try c.decodeIfPresent(String.self, forKey: .buildNote)
    }
}

/// One keyframe recorded during the RoomPlan scan (saved in frames.json).
struct Keyframe: Codable, Hashable {
    var index: Int
    /// Photo file name in Frames/.
    var image: String
    /// LiDAR depth file name in Depth/ (raw little-endian UInt16 millimetres), if the scanner provided depth.
    var depth: String?
    var depthWidth: Int?
    var depthHeight: Int?
    var imageWidth: Int
    var imageHeight: Int
    /// Camera-to-world transform, column-major 4×4 (ARKit convention: camera looks down −Z, +Y up).
    var transform: [Float]
    /// fx, fy, cx, cy in photo pixels.
    var intrinsics: [Float]
    var timestamp: Double
    /// How fast the phone was turning when the photo was taken, degrees per second (blur estimate).
    var turnRate: Float
}

struct KeyframeLog: Codable {
    var description = "Photos recorded during the LiDAR room scan. transform = camera-to-world (column-major, metres, Y up, ARKit camera looks down -Z). intrinsics = fx, fy, cx, cy in photo pixels. Depth = raw UInt16 millimetres, row-major."
    var frames: [Keyframe] = []
}
