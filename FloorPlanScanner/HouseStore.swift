import ARKit
import SwiftUI
import UIKit

/// Saves the house list as JSON, plus one folder per house in the app's Documents folder:
///   Houses/<id>/Frames/       photos recorded during the scan
///   Houses/<id>/Depth/        LiDAR depth for each photo (raw UInt16 mm)
///   Houses/<id>/frames.json   camera position and lens for each photo
///   Houses/<id>/room.json     the RoomPlan result (walls, doors, windows, furniture)
///   Houses/<id>/room.usdz     RoomPlan's own untextured model
///   Houses/<id>/Textures/     textures made by the build
///   Houses/<id>/house.usdz    the finished textured house
@MainActor
final class HouseStore: ObservableObject {
    @Published private(set) var houses: [House] = []

    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("houses.json") }
    private let fm = FileManager.default

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Houses", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        load()
        recoverInterrupted()
    }

    func house(_ id: UUID) -> House? {
        houses.first { $0.id == id }
    }

    @discardableResult
    func create(name: String) -> House {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let house = House(name: trimmed.isEmpty ? "My house" : trimmed)
        try? fm.createDirectory(at: framesURL(for: house.id), withIntermediateDirectories: true)
        try? fm.createDirectory(at: depthURL(for: house.id), withIntermediateDirectories: true)
        houses.insert(house, at: 0)
        save()
        return house
    }

    func delete(at offsets: IndexSet) {
        for i in offsets { try? fm.removeItem(at: folder(for: houses[i].id)) }
        houses.remove(atOffsets: offsets)
        save()
    }

    func delete(id: UUID) {
        try? fm.removeItem(at: folder(for: id))
        houses.removeAll { $0.id == id }
        save()
    }

    func mutate(_ id: UUID, _ change: (inout House) -> Void) {
        guard let i = houses.firstIndex(where: { $0.id == id }) else { return }
        change(&houses[i])
        save()
    }

    // MARK: - Files

    func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func framesURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("Frames", isDirectory: true) }
    func depthURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("Depth", isDirectory: true) }
    func texturesURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("Textures", isDirectory: true) }
    func frameLogURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("frames.json") }
    func roomURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("room.json") }
    func roomModelURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("room.usdz") }
    func modelURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("house.usdz") }
    func planURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("plan.jpg") }
    // Detail pass.
    func highResURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("HighRes", isDirectory: true) }
    func highResLogURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("highres.json") }
    func depthFramesURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("DepthFrames", isDirectory: true) }
    func depthFrameLogURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("depthframes.json") }
    /// The room scan's ARKit world map: lets a detail pass (now or later) line up with the room scan.
    func worldMapURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("worldmap.arexperience") }

    func hasWorldMap(_ id: UUID) -> Bool { fm.fileExists(atPath: worldMapURL(for: id).path) }

    @discardableResult
    func saveWorldMap(_ map: ARWorldMap, for id: UUID) -> Bool {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
            try data.write(to: worldMapURL(for: id), options: .atomic)
            return true
        } catch {
            print("Failed to save world map: \(error)")
            return false
        }
    }

    func loadWorldMap(for id: UUID) -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL(for: id)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    func hasRoom(_ id: UUID) -> Bool { fm.fileExists(atPath: roomURL(for: id).path) }
    func hasModel(_ id: UUID) -> Bool { fm.fileExists(atPath: modelURL(for: id).path) }

    func planImage(for id: UUID) -> UIImage? { UIImage(contentsOfFile: planURL(for: id).path) }

    func loadFrameLog(for id: UUID) -> KeyframeLog? {
        guard let data = try? Data(contentsOf: frameLogURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(KeyframeLog.self, from: data)
    }

    /// Removes photos, depth and model files from an earlier scan of this house, before scanning again.
    func clearScanData(for id: UUID) {
        for url in [framesURL(for: id), depthURL(for: id), texturesURL(for: id), highResURL(for: id), depthFramesURL(for: id)] {
            try? fm.removeItem(at: url)
        }
        for url in [frameLogURL(for: id), roomURL(for: id), roomModelURL(for: id), modelURL(for: id), planURL(for: id),
                    highResLogURL(for: id), depthFrameLogURL(for: id), worldMapURL(for: id)] {
            try? fm.removeItem(at: url)
        }
        try? fm.createDirectory(at: framesURL(for: id), withIntermediateDirectories: true)
        try? fm.createDirectory(at: depthURL(for: id), withIntermediateDirectories: true)
    }

    /// Total size of everything in a house's folder, in bytes.
    func diskSize(for id: UUID) -> Int64 {
        guard let e = fm.enumerator(at: folder(for: id), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// A copy of a model named after the house, for sharing.
    func shareableModelURL(for id: UUID, untextured: Bool = false) -> URL? {
        let source = untextured ? roomModelURL(for: id) : modelURL(for: id)
        guard let house = house(id), fm.fileExists(atPath: source.path) else { return nil }
        let dir = fm.temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(Self.safeName(house.name, fallback: "house"))\(untextured ? " (plain)" : "").usdz")
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: source, to: dest)
            return dest
        } catch {
            print("Failed to prepare model for sharing: \(error)")
            return nil
        }
    }

    nonisolated static func safeName(_ name: String, fallback: String) -> String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        return safe.isEmpty ? fallback : safe
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        houses = (try? decoder.decode([House].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(houses).write(to: indexURL, options: .atomic)
        } catch {
            print("Failed to save houses: \(error)")
        }
    }

    /// If the app was closed during a scan or a build, put the house back in a state the user can act on.
    private func recoverInterrupted() {
        var changed = false
        for i in houses.indices {
            let id = houses[i].id
            switch houses[i].status {
            case .scanning:
                houses[i].status = hasRoom(id) ? .scanned : .failed
                houses[i].errorMessage = hasRoom(id) ? nil : "The scan was interrupted before it finished. Tap Scan again."
                changed = true
            case .building:
                houses[i].status = hasModel(id) ? .ready : (hasRoom(id) ? .scanned : .failed)
                houses[i].errorMessage = hasModel(id) ? nil : "The app was closed while building. Tap Build to try again."
                changed = true
            default:
                break
            }
        }
        if changed { save() }
    }
}
