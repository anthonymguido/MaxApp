import SwiftUI
import UIKit

/// Thread-safe cancel flag shared with the background build.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Builds a house's textured 3D model in the background. One build runs at a time.
@MainActor
final class BuildController: ObservableObject {
    @Published private(set) var activeHouseID: UUID?
    @Published private(set) var fraction: Double = 0
    @Published private(set) var stage = ""

    var isRunning: Bool { activeHouseID != nil }

    private var flag = CancelFlag()

    func build(_ id: UUID, store: HouseStore, scans: ScanStore) {
        guard !isRunning, let house = store.house(id) else { return }
        guard store.hasRoom(id) else {
            store.mutate(id) { $0.errorMessage = "This house has no scan to build from. Scan it first." }
            return
        }
        let details = house.details.compactMap { d -> HouseModelBuilder.DetailModel? in
            guard scans.hasModel(d.scanID) else { return nil }
            return HouseModelBuilder.DetailModel(objectID: d.objectID, modelURL: scans.modelURL(for: d.scanID),
                                                 quarterTurns: d.quarterTurns)
        }
        let input = HouseModelBuilder.Input(roomURL: store.roomURL(for: id), frameLogURL: store.frameLogURL(for: id),
                                            framesDir: store.framesURL(for: id), depthDir: store.depthURL(for: id),
                                            texturesDir: store.texturesURL(for: id),
                                            highResDir: store.highResURL(for: id), highResLogURL: store.highResLogURL(for: id),
                                            outputURL: store.modelURL(for: id),
                                            includeCeilings: house.includeCeilings, details: details)
        let flag = CancelFlag()
        self.flag = flag
        activeHouseID = id
        fraction = 0
        stage = "Starting…"
        UIApplication.shared.isIdleTimerDisabled = true
        store.mutate(id) {
            $0.status = .building
            $0.errorMessage = nil
        }

        Task { @MainActor in
            let result: Result<HouseModelBuilder.Output?, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let output = try HouseModelBuilder.run(input, progress: { f, text in
                        Task { @MainActor [weak self] in
                            guard let self, self.activeHouseID == id else { return }
                            self.fraction = f
                            self.stage = text
                        }
                    }, isCancelled: { flag.isSet })
                    return .success(output)
                } catch {
                    return .failure(error)
                }
            }.value
            self.finish(id, store: store, result: result)
        }
    }

    func cancel() {
        flag.set()
    }

    private func finish(_ id: UUID, store: HouseStore, result: Result<HouseModelBuilder.Output?, Error>) {
        let hasModel = store.hasModel(id)
        store.mutate(id) {
            switch result {
            case .success(let output?):
                $0.status = .ready
                $0.errorMessage = nil
                $0.buildNote = output.note
            case .success(nil):
                $0.status = hasModel ? .ready : .scanned
                $0.errorMessage = "The build was cancelled."
            case .failure(let error):
                $0.status = hasModel ? .ready : .scanned
                $0.errorMessage = "The build failed: \(error.localizedDescription)"
            }
        }
        activeHouseID = nil
        fraction = 0
        stage = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
