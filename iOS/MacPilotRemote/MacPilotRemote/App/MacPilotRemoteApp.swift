import SwiftUI

@main
struct MacPilotRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel = RemoteAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .task { await appModel.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active || phase == .background {
                        ProximityBLECentral.shared.applicationStateChanged(isActive: phase == .active)
                    }
                }
        }
    }
}
