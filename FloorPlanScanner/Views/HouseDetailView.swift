import SwiftUI
import RoomPlan

/// One piece of furniture RoomPlan found, for the detail-capture list.
struct RoomObjectInfo: Identifiable, Hashable {
    let id: UUID
    let label: String
    let sizeCM: SIMD3<Int>
}

struct HouseDetailView: View {
    let houseID: UUID

    @EnvironmentObject private var store: HouseStore
    @EnvironmentObject private var builder: BuildController
    @EnvironmentObject private var scans: ScanStore
    @EnvironmentObject private var reconstructor: Reconstructor
    @Environment(\.dismiss) private var dismiss

    @State private var plan: UIImage?
    @State private var objects: [RoomObjectInfo] = []
    @State private var viewing: ViewTarget?
    @State private var shareItems: [Any] = []
    @State private var sharing = false
    @State private var exporting = false
    @State private var exportError: String?
    @State private var rescanning: HouseListView.ScanTarget?
    @State private var confirmRescan = false
    @State private var confirmDelete = false
    @State private var capturing: CaptureTarget?
    @State private var showTips = false

    struct ViewTarget: Identifiable {
        let url: URL
        let title: String
        var id: URL { url }
    }

    struct CaptureTarget: Identifiable {
        let scanID: UUID
        let objectID: UUID
        let label: String
        var id: UUID { scanID }
    }

    private var isBuildingThis: Bool { builder.activeHouseID == houseID }

    var body: some View {
        Group {
            if let house = store.house(houseID) {
                List {
                    overview(house)
                    buildSection(house)
                    furnitureSection(house)
                    shareSection(house)
                    manageSection(house)
                }
                .navigationTitle(house.name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("This scan was deleted", systemImage: "trash")
            }
        }
        .task(id: store.house(houseID)?.status) { await loadRoom() }
        .sheet(item: $viewing) { ModelViewer(url: $0.url, title: $0.title) }
        .sheet(isPresented: $sharing) { ShareSheet(items: shareItems) }
        .sheet(isPresented: $showTips) { NavigationStack { TrackingTipsView() } }
        .fullScreenCover(item: $rescanning) { target in
            RoomScanView(houseID: target.id, isNew: false) { _ in }
        }
        .fullScreenCover(item: $capturing) { target in
            CaptureView(scanID: target.scanID) { scanID in
                attachDetail(scanID: scanID, objectID: target.objectID, label: target.label)
            }
        }
        .confirmationDialog("Scan this house again?", isPresented: $confirmRescan, titleVisibility: .visible) {
            Button("Scan again", role: .destructive) { rescan() }
        } message: {
            Text("The current scan, photos and model are replaced. Furniture detail models are kept.")
        }
        .confirmationDialog("Delete this house?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if isBuildingThis { builder.cancel() }
                store.delete(id: houseID)
                dismiss()
            }
        }
    }

    // MARK: Sections

    private func overview(_ house: House) -> some View {
        Section {
            if let plan {
                Image(uiImage: plan)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .accessibilityLabel("Floor plan")
            }
            Label(house.status.title, systemImage: house.status.symbol)
                .foregroundStyle(house.status.color)
            Text("\(house.wallCount) walls · \(house.doorCount) doors · \(house.windowCount) windows · \(house.objectCount) pieces of furniture")
                .font(.subheadline)
            Text("\(house.frameCount) photos" + (house.frameCount > 0 && house.depthCount == 0 ? " (no LiDAR depth: hiding behind furniture is worked out from the plan instead)" : ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let error = house.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func buildSection(_ house: House) -> some View {
        Section {
            if isBuildingThis {
                VStack(alignment: .leading, spacing: 8) {
                    Text(builder.stage).font(.subheadline.weight(.semibold))
                    ProgressView(value: builder.fraction)
                    Text("\(Int(builder.fraction * 100))%  ·  Keep the app open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel build", role: .destructive) { builder.cancel() }
            } else {
                if store.hasModel(houseID) {
                    Button {
                        viewing = ViewTarget(url: store.modelURL(for: houseID), title: house.name)
                    } label: {
                        Label("View in 3D / AR", systemImage: "arkit")
                    }
                }
                Button {
                    builder.build(houseID, store: store, scans: scans)
                } label: {
                    Label(store.hasModel(houseID) ? "Rebuild textured house" : "Build textured house",
                          systemImage: "paintbrush.pointed")
                }
                .disabled(!store.hasRoom(houseID) || builder.isRunning)
                Toggle("Include ceilings", isOn: Binding(
                    get: { store.house(houseID)?.includeCeilings ?? false },
                    set: { value in store.mutate(houseID) { $0.includeCeilings = value } }))
                if builder.isRunning {
                    Text("Another house is being built. Wait for it to finish.").font(.footnote).foregroundStyle(.secondary)
                }
                if let note = house.buildNote {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Textured 3D model")
        } footer: {
            Text("The photos from your scan are projected onto every wall, floor and piece of furniture, so the model shows your real paint, flooring and furniture colors. Ceilings are off by default so you can look down into the rooms.")
        }
    }

    @ViewBuilder
    private func furnitureSection(_ house: House) -> some View {
        if !objects.isEmpty {
            Section {
                ForEach(objects) { object in
                    furnitureRow(object, detail: house.details.first { $0.objectID == object.id })
                }
            } header: {
                Text("Furniture detail (photogrammetry)")
            } footer: {
                Text(DeviceSupport.canCaptureObjects
                     ? "Pieces start as colored boxes. Tap Capture detail and walk around a piece to build a detailed photogrammetry model of it. Rebuild the house afterwards to put it in place. Use Turn if it ends up facing the wrong way."
                     : "This device can't do detail captures.")
            }
        }
    }

    @ViewBuilder
    private func furnitureRow(_ object: RoomObjectInfo, detail: FurnitureDetail?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(object.label).font(.headline)
                    Text("\(object.sizeCM.x) × \(object.sizeCM.z) × \(object.sizeCM.y) cm")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let detail, let scan = scans.scan(detail.scanID) {
                    if reconstructor.activeScanID == detail.scanID {
                        ProgressView(value: reconstructor.fraction).frame(width: 70)
                    } else {
                        Label(scan.status.title, systemImage: scan.status.symbol)
                            .font(.caption).foregroundStyle(scan.status.color)
                    }
                }
            }
            HStack(spacing: 10) {
                if let detail, let scan = scans.scan(detail.scanID) {
                    if scan.status == .ready {
                        Button("Turn 90°") {
                            store.mutate(houseID) { h in
                                if let i = h.details.firstIndex(where: { $0.objectID == detail.objectID }) {
                                    h.details[i].quarterTurns = (h.details[i].quarterTurns + 1) % 4
                                }
                            }
                        }
                        Button("View") {
                            viewing = ViewTarget(url: scans.modelURL(for: detail.scanID), title: detail.label)
                        }
                    } else if scan.status == .captured {
                        Button("Build model") { reconstructor.build(detail.scanID, store: scans) }
                            .disabled(reconstructor.isRunning)
                    }
                    Button("Remove", role: .destructive) { removeDetail(detail) }
                    if let error = scan.errorMessage, scan.status != .ready {
                        Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                } else {
                    Button("Capture detail") { startCapture(object) }
                        .disabled(!DeviceSupport.canCaptureObjects || reconstructor.isRunning)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func shareSection(_ house: House) -> some View {
        Section("Share") {
            Button {
                if let url = store.shareableModelURL(for: houseID) { share([url]) }
            } label: {
                Label("Share textured model (.usdz)", systemImage: "square.and.arrow.up")
            }
            .disabled(!store.hasModel(houseID))
            Button {
                if let url = store.shareableModelURL(for: houseID, untextured: true) { share([url]) }
            } label: {
                Label("Share plain RoomPlan model", systemImage: "cube")
            }
            .disabled(!FileManager.default.fileExists(atPath: store.roomModelURL(for: houseID).path))
            if let plan {
                Button { share([plan]) } label: { Label("Share floor plan image", systemImage: "photo") }
            }
            Button {
                exportForMac(house)
            } label: {
                HStack {
                    Label("Export scan data for a computer", systemImage: "desktopcomputer")
                    if exporting { Spacer(); ProgressView() }
                }
            }
            .disabled(exporting || !store.hasRoom(houseID))
            if let exportError {
                Text(exportError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func manageSection(_ house: House) -> some View {
        Section {
            Button("Scan again") { confirmRescan = true }
                .disabled(isBuildingThis || !DeviceSupport.canScanRooms)
            Button("Tips for detail captures") { showTips = true }
            Button("Delete house", role: .destructive) { confirmDelete = true }
        } footer: {
            Text("Uses \(ByteCountFormatter.string(fromByteCount: store.diskSize(for: houseID), countStyle: .file)) on this phone.")
        }
    }

    // MARK: Actions

    private func loadRoom() async {
        let planURL = store.planURL(for: houseID)
        let roomURL = store.roomURL(for: houseID)
        let loaded = await Task.detached(priority: .utility) { () -> (UIImage?, [RoomObjectInfo]) in
            let image = UIImage(contentsOfFile: planURL.path)
            guard let data = try? Data(contentsOf: roomURL),
                  let room = try? JSONDecoder().decode(CapturedRoom.self, from: data) else { return (image, []) }
            var counts: [String: Int] = [:]
            let infos = room.objects.map { object -> RoomObjectInfo in
                let name = Self.name(for: object.category)
                counts[name, default: 0] += 1
                let d = object.dimensions * 100
                return RoomObjectInfo(id: object.identifier, label: "\(name) \(counts[name]!)",
                                      sizeCM: SIMD3(Int(d.x.rounded()), Int(d.y.rounded()), Int(d.z.rounded())))
            }
            return (image, infos)
        }.value
        plan = loaded.0
        objects = loaded.1
    }

    nonisolated static func name(for category: CapturedRoom.Object.Category) -> String {
        let raw = String(describing: category)
        // "sofa" → "Sofa", "washerDryer" → "Washer dryer"
        var out = ""
        for ch in raw {
            if ch.isUppercase { out += " " + ch.lowercased() } else { out.append(ch) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    private func startCapture(_ object: RoomObjectInfo) {
        let house = store.house(houseID)?.name ?? "House"
        let scan = scans.create(name: "\(house) – \(object.label)")
        capturing = CaptureTarget(scanID: scan.id, objectID: object.id, label: object.label)
    }

    private func attachDetail(scanID: UUID, objectID: UUID, label: String) {
        store.mutate(houseID) { h in
            h.details.removeAll { $0.objectID == objectID }
            h.details.append(FurnitureDetail(objectID: objectID, scanID: scanID, label: label))
        }
        // Let the camera screen close and release its memory before building.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            reconstructor.build(scanID, store: scans)
        }
    }

    private func removeDetail(_ detail: FurnitureDetail) {
        if reconstructor.activeScanID == detail.scanID { reconstructor.cancel() }
        store.mutate(houseID) { h in h.details.removeAll { $0.objectID == detail.objectID } }
        scans.delete(id: detail.scanID)
    }

    private func rescan() {
        store.clearScanData(for: houseID)
        store.mutate(houseID) {
            $0.status = .scanning
            $0.buildNote = nil
            $0.errorMessage = nil
        }
        plan = nil
        rescanning = HouseListView.ScanTarget(id: houseID)
    }

    private func share(_ items: [Any]) {
        shareItems = items
        sharing = true
    }

    private func exportForMac(_ house: House) {
        exporting = true
        exportError = nil
        let input = MacExporter.Input(name: house.name, framesDir: store.framesURL(for: houseID),
                                      depthDir: store.depthURL(for: houseID), frameLog: store.frameLogURL(for: houseID),
                                      room: store.roomURL(for: houseID), roomModel: store.roomModelURL(for: houseID),
                                      houseModel: store.modelURL(for: houseID))
        Task { @MainActor in
            do {
                let zip = try await MacExporter.export(input)
                share([zip])
            } catch {
                exportError = "Export failed: \(error.localizedDescription)"
            }
            exporting = false
        }
    }
}
