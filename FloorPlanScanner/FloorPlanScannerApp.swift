import SwiftUI
import RealityKit
import RoomPlan

@main
struct FloorPlanScannerApp: App {
    @StateObject private var houses = HouseStore()
    @StateObject private var builder = BuildController()
    // Furniture detail captures (ObjectScanner's capture and photogrammetry).
    @StateObject private var scans = ScanStore()
    @StateObject private var reconstructor = Reconstructor()

    var body: some SwiftUI.Scene {   // RealityKit also has a Scene type
        WindowGroup {
            HouseListView()
                .environmentObject(houses)
                .environmentObject(builder)
                .environmentObject(scans)
                .environmentObject(reconstructor)
        }
    }
}

enum DeviceSupport {
    /// RoomPlan needs a LiDAR scanner (iPhone 12 Pro or later Pro models, recent iPad Pro).
    @MainActor static var canScanRooms: Bool { RoomCaptureSession.isSupported }
    /// Object Capture (furniture detail) needs iOS 17+ and LiDAR.
    @MainActor static var canCaptureObjects: Bool { ObjectCaptureSession.isSupported }
}
