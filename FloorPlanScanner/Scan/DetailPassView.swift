import ARKit
import RealityKit
import SwiftUI

/// Camera view for the detail pass, on the same AR session the RoomPlan scan used.
/// The live LiDAR mesh is drawn over the camera so you can see what has been captured.
struct DetailARView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.debugOptions.insert(.showSceneUnderstanding)
        view.renderOptions.insert(.disableMotionBlur)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Before the detail pass: what it's for and how to do it.
struct DetailIntroCard: View {
    var onStart: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Rooms measured. Now add detail", systemImage: "sparkles")
                .font(.headline)
            Text("Walk through again for 1–2 minutes per room. The LiDAR scanner captures the real shape of your furniture and objects, and the camera takes sharp 12-megapixel photos for the textures.")
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 6) {
                tip("arrow.up.and.down", "Sweep each piece of furniture from high, middle and low")
                tip("hand.point.up.left", "Get within about 1 m of shelves and detailed things")
                tip("arrow.down.to.line", "Tilt down and cover the whole floor, including where you stood")
                tip("tortoise", "Move slowly; the mesh shows what's been captured")
            }
            HStack {
                Button("Skip", action: onSkip).buttonStyle(.bordered)
                Spacer()
                Button(action: onStart) { Label("Start detail pass", systemImage: "viewfinder") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label { Text(text).font(.footnote) } icon: { Image(systemName: icon).foregroundStyle(.yellow) }
    }
}

/// Owns the detail pass's own AR session (separate from RoomPlan's), and watches that the camera starts.
@MainActor
final class DetailSession: ObservableObject {
    enum Status: Equatable {
        case starting
        case aligning(seconds: Int)
        case recording
        case failed(String)
    }

    let arSession = ARSession()
    @Published private(set) var status: Status = .starting

    private var worldMap: ARWorldMap?
    private var simple = false
    private var startedAt = Date()
    private var alignSince: Date?

    func start(worldMap: ARWorldMap) {
        self.worldMap = worldMap
        run(simple: false)
    }

    func stop() {
        arSession.pause()
    }

    private func run(simple: Bool) {
        self.simple = simple
        startedAt = Date()
        alignSince = nil
        status = .starting
        arSession.run(DetailRecorder.configuration(worldMap: worldMap, simple: simple),
                      options: [.resetTracking, .removeExistingAnchors])
    }

    /// Call often. Retries with a simpler camera setup if no frames arrive.
    func tick() {
        if case .failed = status { return }
        guard let frame = arSession.currentFrame else {
            let waited = Date().timeIntervalSince(startedAt)
            if !simple && waited > 4 {
                run(simple: true)
            } else if simple && waited > 6 {
                status = .failed("The camera didn't start. Close the app completely, open it again and use Add detail pass on the house page.")
            }
            return
        }
        if case .normal = frame.camera.trackingState {
            status = .recording
            alignSince = nil
        } else {
            if alignSince == nil { alignSince = Date() }
            status = .aligning(seconds: Int(Date().timeIntervalSince(alignSince ?? Date())))
        }
    }
}

/// The detail pass: its own camera session, relocalized into the room scan's coordinates with the saved world map.
/// Used right after the room scan and from the house page (Add detail pass).
struct DetailPassScreen: View {
    let houseID: UUID
    var onDone: () -> Void

    @EnvironmentObject private var store: HouseStore
    @StateObject private var session = DetailSession()
    @StateObject private var recorder = DetailRecorder()
    @State private var started = Date()
    @State private var elapsed = 0
    @State private var confirmCancel = false
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DetailARView(session: session.arSession).ignoresSafeArea()
            VStack {
                HStack {
                    Button("Cancel") {
                        if recorder.depthCount > 0 { confirmCancel = true } else { close(save: false) }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .environment(\.colorScheme, .dark)
                Spacer()
                DetailPassCard(recorder: recorder, status: session.status, elapsed: elapsed) { close(save: true) }
            }
            .padding()
        }
        .statusBarHidden()
        .onAppear(perform: begin)
        .onDisappear { session.stop() }
        .onReceive(ticker) { _ in
            session.tick()
            if session.status == .recording { recorder.tick(session: session.arSession) }
            elapsed = Int(Date().timeIntervalSince(started))
        }
        .confirmationDialog("Stop without saving the detail pass?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard detail pass", role: .destructive) { close(save: false) }
        }
    }

    private func begin() {
        guard let map = store.loadWorldMap(for: houseID) else {
            close(save: false)
            return
        }
        recorder.begin(photoDir: store.highResURL(for: houseID), depthDir: store.depthFramesURL(for: houseID),
                       photoLogURL: store.highResLogURL(for: houseID), depthLogURL: store.depthFrameLogURL(for: houseID))
        started = Date()
        session.start(worldMap: map)
    }

    private func close(save: Bool) {
        session.stop()
        if save {
            recorder.finish()
            let photos = recorder.photoCount, depths = recorder.depthCount
            store.mutate(houseID) {
                $0.highResCount = photos
                $0.depthFrameCount = depths
                $0.hasDetailPass = photos > 0 || depths > 0
            }
        }
        onDone()
    }
}

/// During the detail pass: status, counters, a rotating tip and the Finish button.
struct DetailPassCard: View {
    @ObservedObject var recorder: DetailRecorder
    var status: DetailSession.Status
    var elapsed: Int
    var onFinish: () -> Void

    private static let tips = [
        "Sweep furniture from high, middle and low.",
        "Get close (about 1 m) to shelves, the TV stand and other detailed things.",
        "Tilt down and cover the floor, including where you were standing.",
        "Go around tables and chairs so their sides and legs are seen.",
        "Point at the corners where walls meet the floor and ceiling.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Label("\(recorder.photoCount)", systemImage: "camera.fill")
                Label("\(recorder.depthCount)", systemImage: "cube.transparent")
                Label(String(format: "%d:%02d", elapsed / 60, elapsed % 60), systemImage: "timer")
                Spacer()
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            statusLine
            HStack {
                Spacer()
                Button(action: onFinish) { Label("Finish", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.depthCount == 0 && recorder.photoCount == 0)
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .starting:
            Label("Starting the camera…", systemImage: "camera").font(.footnote)
        case .aligning(let seconds):
            Label(seconds < 12
                  ? "Lining up with your room scan: point at a wall or furniture you already scanned and hold still."
                  : "Still lining up. Go back to where you started the room scan and slowly look around.",
                  systemImage: "scope")
                .font(.footnote).foregroundStyle(.yellow)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
        case .recording:
            if recorder.photosFull {
                Label("Photo limit reached. Depth is still being captured.", systemImage: "photo.stack")
                    .font(.footnote).foregroundStyle(.yellow)
            } else {
                Label(Self.tips[(elapsed / 8) % Self.tips.count], systemImage: "checkmark.circle")
                    .font(.footnote)
            }
        }
    }
}
