import ARKit
import RoomPlan
import SwiftUI

/// Owns the RoomPlan scanner view and receives its results.
final class RoomScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    enum Phase {
        case scanning
        case processing
        case review(CapturedRoom)
        case failed(String)
    }

    @Published var phase: Phase = .scanning
    /// Bumped to throw away the scanner view and start a fresh scan.
    @Published var generation = 0
    /// Saved when the scan finishes, so the detail pass can line up with this scan.
    @Published var worldMap: ARWorldMap?
    private weak var captureView: RoomCaptureView?

    override init() { super.init() }

    // RoomCaptureViewDelegate inherits NSCoding; this object is never archived.
    nonisolated init?(coder: NSCoder) { return nil }
    nonisolated func encode(with coder: NSCoder) {}

    @MainActor func makeView() -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = self
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        captureView = view
        return view
    }

    @MainActor var arSession: ARSession? { captureView?.captureSession.arSession }

    @MainActor func finish() {
        phase = .processing
        guard let view = captureView else { return }
        // Grab the tracking map before stopping: the detail pass relocalizes into these coordinates.
        stopRequested = false
        view.captureSession.arSession.getCurrentWorldMap { [weak self] map, error in
            if let error { print("No world map: \(error)") }
            Task { @MainActor in
                self?.worldMap = map
                self?.stopOnce()
            }
        }
        // Don't wait forever for the map.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.stopOnce() }
    }

    private var stopRequested = false

    @MainActor private func stopOnce() {
        guard !stopRequested else { return }
        stopRequested = true
        captureView?.captureSession.stop()
    }

    @MainActor func rescan() {
        captureView?.captureSession.stop()
        phase = .scanning
        generation += 1
    }

    @MainActor func cancel() {
        captureView?.captureSession.stop()
    }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            let message = error.localizedDescription
            Task { @MainActor in self.phase = .failed(message) }
            return false
        }
        return true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message {
                self.phase = .failed(message)
            } else {
                self.phase = .review(processedResult)
            }
        }
    }
}

struct RoomCaptureRepresentable: UIViewRepresentable {
    let controller: RoomScanController

    func makeUIView(context: Context) -> RoomCaptureView { controller.makeView() }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: ()) {
        uiView.captureSession.stop()
    }
}

/// Full-screen LiDAR scan: tips → guided scan (recording photos as it goes) → review → saved house.
struct RoomScanView: View {
    let houseID: UUID
    /// True when the house was just created for this scan (cancelling removes it again).
    var isNew: Bool
    var onFinish: (UUID) -> Void

    @EnvironmentObject private var store: HouseStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = RoomScanController()
    @StateObject private var coach = ScanCoach()
    @StateObject private var recorder = FrameRecorder()
    @StateObject private var monitor = TrackingMonitor()
    @State private var introDone: Bool
    @State private var saving = false
    @State private var saveError: String?
    @State private var detailStage: DetailStage = .none
    @State private var detailNote: String?

    private enum DetailStage { case none, intro, recording }
    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private let photoTicker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    init(houseID: UUID, isNew: Bool, onFinish: @escaping (UUID) -> Void) {
        self.houseID = houseID
        self.isNew = isNew
        self.onFinish = onFinish
        _introDone = State(initialValue: UserDefaults.standard.bool(forKey: ScanGuideIntroView.skipKey))
    }

    private var isScanning: Bool {
        if case .scanning = controller.phase { return true }
        return false
    }

    var body: some View {
        if !introDone {
            ScanGuideIntroView(onStart: { introDone = true }, onCancel: { cancel() })
        } else if detailStage == .recording {
            // RoomPlan's view is gone (which releases the camera); the detail pass has its own session.
            DetailPassScreen(houseID: houseID) { finishAll() }
        } else {
            ZStack {
                RoomCaptureRepresentable(controller: controller)
                    .id(controller.generation)
                    .ignoresSafeArea()
                    .allowsHitTesting(detailStage == .none)

                if isScanning {
                    TrackingHUD(monitor: monitor, showsMessage: false)
                }

                if detailStage == .intro {
                    detailIntroLayer
                } else {
                VStack(spacing: 10) {
                    topBar
                    if isScanning && !recorder.photoPositions.isEmpty {
                        HStack {
                            Spacer()
                            ScanMiniMap(photoPositions: recorder.photoPositions,
                                        lossPositions: monitor.lossPositions.map { SIMD2($0.x, $0.z) },
                                        current: monitor.mapPosition, heading: monitor.mapHeading)
                                .frame(width: 110, height: 110)
                        }
                    }
                    if isScanning, let warning = coach.warning {
                        CoachBanner(message: warning)
                    } else if isScanning, recorder.nearLimit {
                        CoachBanner(message: CoachMessage(
                            text: recorder.isFull
                                ? "Photo limit reached. The rest of the scan still gets measured, but not photographed."
                                : "Nearly at the photo limit. Finish the last rooms soon.",
                            icon: "photo.stack", style: .hint))
                    }
                    Spacer()
                    bottomCard
                }
                .padding()
                .animation(.easeInOut(duration: 0.25), value: coach.warning)
                }
            }
            .onAppear { beginRecording() }
            .onReceive(ticker) { _ in
                if isScanning { coach.tick(session: controller.arSession) }
            }
            .onReceive(photoTicker) { _ in
                if isScanning {
                    monitor.tick(session: controller.arSession)
                    recorder.tick(session: controller.arSession)
                }
            }
        }
    }

    // MARK: Detail pass

    private var detailIntroLayer: some View {
        VStack(spacing: 10) {
            Spacer()
            if let detailNote {
                Text(detailNote).font(.footnote).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            DetailIntroCard(onStart: { detailStage = .recording }, onSkip: { finishAll() })
        }
        .padding()
    }

    private func finishAll() {
        onFinish(houseID)
        dismiss()
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { cancel() }
                .buttonStyle(.bordered)
            Spacer()
            if isScanning {
                HStack(spacing: 8) {
                    Label(String(format: "%d:%02d", coach.elapsedSeconds / 60, coach.elapsedSeconds % 60),
                          systemImage: "timer")
                    Label("\(recorder.count)", systemImage: "camera.fill")
                }
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .accessibilityLabel("\(recorder.count) photos recorded")
                Spacer()
                Button("Done") { controller.finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var bottomCard: some View {
        switch controller.phase {
        case .scanning:
            ScanStepCard(coach: coach) { controller.finish() }

        case .processing:
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Measuring your rooms…").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding()
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))

        case .review(let room):
            reviewCard(room)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("The scan didn't work", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(message).font(.subheadline)
                HStack {
                    Spacer()
                    Button("Try again") { restart() }.buttonStyle(.borderedProminent)
                }
            }
            .foregroundStyle(.white)
            .padding()
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
            .environment(\.colorScheme, .dark)
        }
    }

    private func reviewCard(_ room: CapturedRoom) -> some View {
        let incomplete = room.walls.count < 3
        return VStack(alignment: .leading, spacing: 12) {
            if incomplete {
                Label("The scan looks incomplete", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("Only \(room.walls.count) wall\(room.walls.count == 1 ? "" : "s") found. Scanning again, slowly and with the lights on, usually helps.")
                    .font(.subheadline)
            } else {
                Label("Scan complete", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("Found \(room.walls.count) walls, \(room.doors.count) doors, \(room.windows.count) windows and \(room.objects.count) pieces of furniture, with \(recorder.count) photos for the textures.")
                    .font(.subheadline)
            }
            if let saveError {
                Text(saveError).font(.footnote).foregroundStyle(.orange)
            }
            HStack {
                Button("Rescan") { restart() }.buttonStyle(.bordered).disabled(saving)
                Spacer()
                if saving {
                    ProgressView().tint(.white)
                } else {
                    Button(incomplete ? "Use anyway" : "Use this scan") { use(room) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Actions

    private func beginRecording() {
        monitor.reset()
        recorder.monitor = monitor
        monitor.onTrackingBreak = { [weak recorder, weak monitor] time in
            recorder?.trackingBroke(at: time, position: monitor?.lossPositions.last)
        }
        recorder.begin(framesDir: store.framesURL(for: houseID),
                       depthDir: store.depthURL(for: houseID),
                       logURL: store.frameLogURL(for: houseID))
    }

    private func use(_ room: CapturedRoom) {
        saving = true
        saveError = nil
        recorder.finish()
        let id = houseID
        let roomURL = store.roomURL(for: id)
        let roomModelURL = store.roomModelURL(for: id)
        let planURL = store.planURL(for: id)
        let frames = recorder.count
        let depths = recorder.depthCount
        Task { @MainActor in
            let error: String? = await Task.detached(priority: .userInitiated) {
                do {
                    let data = try JSONEncoder().encode(room)
                    try data.write(to: roomURL, options: .atomic)
                } catch {
                    return "Couldn't save the scan: \(error.localizedDescription)"
                }
                // RoomPlan's own plain model, kept as a fallback and for sharing.
                do { try room.export(to: roomModelURL) } catch { print("RoomPlan export failed: \(error)") }
                if let jpeg = FloorPlanDrawer.image(from: room).jpegData(compressionQuality: 0.9) {
                    try? jpeg.write(to: planURL, options: .atomic)
                }
                return nil
            }.value
            if let error {
                saving = false
                saveError = error
                return
            }
            store.mutate(id) {
                $0.status = .scanned
                $0.errorMessage = nil
                $0.frameCount = frames
                $0.depthCount = depths
                $0.wallCount = room.walls.count
                $0.doorCount = room.doors.count
                $0.windowCount = room.windows.count
                $0.objectCount = room.objects.count
            }
            saving = false
            // Save the tracking map so the detail pass (now or later) lines up with this scan.
            if let map = controller.worldMap, store.saveWorldMap(map, for: id) {
                detailStage = .intro
            } else {
                // Without a map the detail pass can't line up with the room scan: finish with the room scan only.
                finishAll()
            }
        }
    }

    private func cancel() {
        controller.cancel()
        if isNew {
            store.delete(id: houseID)
        } else {
            store.mutate(houseID) {
                $0.status = .failed
                $0.errorMessage = "The scan was cancelled. Tap Scan again to start over."
            }
        }
        dismiss()
    }

    private func restart() {
        coach.reset()
        store.clearScanData(for: houseID)
        beginRecording()
        controller.rescan()
    }
}
