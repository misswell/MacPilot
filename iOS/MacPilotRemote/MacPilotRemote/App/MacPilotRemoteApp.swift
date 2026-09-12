import SwiftUI

@main
struct MacPilotRemoteApp: App {
    @StateObject private var appModel = RemoteAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .task { await appModel.start() }
        }
    }
}
