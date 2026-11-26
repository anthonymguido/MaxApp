import SwiftUI

struct HouseListView: View {
    @EnvironmentObject private var store: HouseStore
    @EnvironmentObject private var builder: BuildController

    @State private var path: [UUID] = []
    @State private var naming = false
    @State private var newName = ""
    @State private var scanning: ScanTarget?

    struct ScanTarget: Identifiable { let id: UUID }

    private var canScan: Bool { DeviceSupport.canScanRooms }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.houses.isEmpty {
                    emptyState
                } else {
                    List {
                        if !canScan {
                            Section { unsupportedNote }
                        }
                        ForEach(store.houses) { house in
                            NavigationLink(value: house.id) { HouseRow(house: house) }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Floor Plan Scanner")
            .navigationDestination(for: UUID.self) { HouseDetailView(houseID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startNaming() } label: { Image(systemName: "plus") }
                        .disabled(!canScan)
                        .accessibilityLabel("New house scan")
                }
            }
            .alert("New scan", isPresented: $naming) {
                TextField("e.g. Our house, ground floor", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Start") {
                    let house = store.create(name: newName)
                    scanning = ScanTarget(id: house.id)
                }
            } message: {
                Text("Name the home or floor you're about to scan.")
            }
            .fullScreenCover(item: $scanning) { target in
                RoomScanView(houseID: target.id, isNew: true) { id in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { path.append(id) }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No scans yet", systemImage: "house")
        } description: {
            Text(canScan
                 ? "Walk through your home with your phone. The LiDAR scanner measures every room while the camera photographs the walls, floors and furniture, then the app builds a textured 3D model of the whole floor."
                 : "This device can't scan. It needs a LiDAR scanner (iPhone 12 Pro or a later Pro model, or a recent iPad Pro).")
        } actions: {
            if canScan {
                Button("Scan a floor") { startNaming() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var unsupportedNote: some View {
        Label("This device has no LiDAR scanner, so it can't make new scans. You can still view and share existing models.",
              systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func startNaming() {
        newName = ""
        naming = true
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets where store.houses[i].id == builder.activeHouseID {
            builder.cancel()
        }
        store.delete(at: offsets)
    }
}

struct HouseRow: View {
    @EnvironmentObject private var store: HouseStore
    let house: House

    var body: some View {
        HStack(spacing: 12) {
            PlanThumbnail(url: store.planURL(for: house.id))
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(house.name).font(.headline)
                Label(house.status.title, systemImage: house.status.symbol)
                    .font(.subheadline)
                    .foregroundStyle(house.status.color)
                Text("\(house.date.formatted(date: .abbreviated, time: .shortened)) · \(house.wallCount) walls · \(house.frameCount) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A small preview of the 2D plan.
struct PlanThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "square.split.bottomrightquarter").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 160, height: 160))
            }.value
        }
    }
}
