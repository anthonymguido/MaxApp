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

/// During the detail pass: counters, a rotating tip and the Finish button.
struct DetailPassCard: View {
    @ObservedObject var recorder: DetailRecorder
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
            if !recorder.trackingOK {
                Label("Tracking is weak. Slow down and point at something with detail.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            } else if recorder.photosFull {
                Label("Photo limit reached. Depth is still being captured.", systemImage: "photo.stack")
                    .font(.footnote).foregroundStyle(.yellow)
            } else {
                Text(Self.tips[(elapsed / 8) % Self.tips.count]).font(.footnote)
            }
            HStack {
                Spacer()
                Button(action: onFinish) { Label("Finish", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }
}
