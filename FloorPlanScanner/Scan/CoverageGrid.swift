import ARKit
import SceneKit
import SwiftUI
import simd

/// Which parts of the room have been captured well during the detail pass, on a 10 cm grid.
/// Updated from each recorded depth frame (and each 12 MP photo); read by the live coverage overlay.
final class CoverageGrid: @unchecked Sendable {
    enum Status { case missing, partial, good }

    let cell: Float = 0.1
    private var depthHits: [SIMD3<Int32>: UInt8] = [:]
    private var photoHits: [SIMD3<Int32>: UInt8] = [:]
    private let lock = NSLock()

    /// Adds the surface points a depth frame saw. `photo` = a 12 MP photo was taken at this moment too.
    func add(depth buffer: CVPixelBuffer, confidence: CVPixelBuffer?, intrinsics k: simd_float3x3,
             imageWidth: Int, cameraToWorld: simd_float4x4, photo: Bool) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let confBase = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRow = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let s = Float(w) / Float(imageWidth)
        let fx = k.columns.0.x * s, fy = k.columns.1.y * s, cx = k.columns.2.x * s, cy = k.columns.2.y * s

        var keys = Set<SIMD3<Int32>>()
        for v in stride(from: 4, to: h, by: 8) {
            let row = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float32.self)
            for u in stride(from: 4, to: w, by: 8) {
                if let confBase, confBase.advanced(by: v * confRow + u).assumingMemoryBound(to: UInt8.self).pointee < 1 { continue }
                let d = row[u]
                guard d.isFinite, d > 0.2, d < 4 else { continue }
                let pc = SIMD4<Float>((Float(u) - cx) / fx * d, -(Float(v) - cy) / fy * d, -d, 1)
                let p = cameraToWorld * pc
                keys.insert(SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)),
                                  Int32((p.z / cell).rounded(.down))))
            }
        }
        lock.lock()
        for key in keys {
            depthHits[key] = min(255, (depthHits[key] ?? 0) &+ 1)
            if photo { photoHits[key] = min(255, (photoHits[key] ?? 0) &+ 1) }
        }
        lock.unlock()
    }

    func status(_ p: SIMD3<Float>) -> Status {
        let key = SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)),
                        Int32((p.z / cell).rounded(.down)))
        lock.lock()
        let d = depthHits[key] ?? 0, ph = photoHits[key] ?? 0
        lock.unlock()
        if d >= 2 && ph >= 1 { return .good }
        if d >= 1 || ph >= 1 { return .partial }
        return .missing
    }
}

/// The detail pass camera view: ARKit's live LiDAR mesh drawn over the camera, coloured by coverage —
/// red = not captured yet, amber = partly (depth only or a single photo), green = well covered.
struct CoverageARView: UIViewRepresentable {
    let session: ARSession
    let grid: CoverageGrid
    /// Share of the visible mesh that is well covered (0…1), reported about once a second.
    var onCoverage: (Float) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(grid: grid, onCoverage: onCoverage) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        context.coordinator.view = view
        context.coordinator.startTimer()
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        coordinator.stopTimer()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let grid: CoverageGrid
        let onCoverage: (Float) -> Void
        weak var view: ARSCNView?
        private var timer: Timer?
        private var nodes: [UUID: SCNNode] = [:]

        init(grid: CoverageGrid, onCoverage: @escaping (Float) -> Void) {
            self.grid = grid
            self.onCoverage = onCoverage
        }

        func startTimer() {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recolor() }
        }

        func stopTimer() {
            timer?.invalidate()
            timer = nil
        }

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard anchor is ARMeshAnchor else { return nil }
            let node = SCNNode()
            DispatchQueue.main.async { self.nodes[anchor.identifier] = node }
            return node
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            DispatchQueue.main.async { self.nodes[anchor.identifier] = nil }
        }

        /// Rebuilds each mesh anchor's geometry with current coverage colours.
        private func recolor() {
            guard let frame = view?.session.currentFrame else { return }
            var good = 0, total = 0
            for case let anchor as ARMeshAnchor in frame.anchors {
                guard let node = nodes[anchor.identifier] else { continue }
                let (geometry, g, t) = Self.geometry(for: anchor, grid: grid)
                node.geometry = geometry
                good += g
                total += t
            }
            if total > 0 { onCoverage(Float(good) / Float(total)) }
        }

        private static func geometry(for anchor: ARMeshAnchor, grid: CoverageGrid) -> (SCNGeometry?, Int, Int) {
            let mesh = anchor.geometry
            let vertices = mesh.vertices
            let faces = mesh.faces
            guard vertices.count > 0, faces.count > 0, vertices.format == .float3 else { return (nil, 0, 0) }
            let vbase = vertices.buffer.contents().advanced(by: vertices.offset)
            var positions = [SCNVector3](repeating: SCNVector3Zero, count: vertices.count)
            var colors = [SIMD4<Float>](repeating: .zero, count: vertices.count)
            var good = 0
            let t = anchor.transform
            for i in 0..<vertices.count {
                let p = vbase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let local = SIMD3<Float>(p[0], p[1], p[2])
                positions[i] = SCNVector3(local.x, local.y, local.z)
                let w = t * SIMD4(local.x, local.y, local.z, 1)
                switch grid.status(SIMD3(w.x, w.y, w.z)) {
                case .good: colors[i] = SIMD4(0.1, 0.85, 0.3, 0.30); good += 1
                case .partial: colors[i] = SIMD4(1.0, 0.65, 0.0, 0.45)
                case .missing: colors[i] = SIMD4(1.0, 0.15, 0.15, 0.55)
                }
            }
            let indexBytes = faces.count * faces.indexCountPerPrimitive * faces.bytesPerIndex
            let indexData = Data(bytes: faces.buffer.contents(), count: indexBytes)
            let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: faces.count,
                                             bytesPerIndex: faces.bytesPerIndex)
            let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                                usesFloatComponents: true, componentsPerVector: 4,
                                                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                                dataStride: MemoryLayout<SIMD4<Float>>.stride)
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            material.isDoubleSided = true
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            material.transparency = 0.7
            geometry.materials = [material]
            return (geometry, good, vertices.count)
        }
    }
}
