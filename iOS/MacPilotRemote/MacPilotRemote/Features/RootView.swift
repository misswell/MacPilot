import SwiftUI

/// App shell. Three tabs keep the four control actions one tap from launch.
struct RootView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label(appModel.text("tabHome"), systemImage: "av.remote") }
            DevicesView()
                .tabItem { Label(appModel.text("tabDevices"), systemImage: "macbook.and.iphone") }
            RemoteSettingsView()
                .tabItem { Label(appModel.text("tabSettings"), systemImage: "gearshape") }
        }
        .tint(.accentColor)
        .sheet(item: $appModel.pairingPrompt) { prompt in
            PairingSheetView(prompt: prompt)
                .environmentObject(appModel)
        }
        .onChange(of: scenePhase) { _, phase in
            appModel.handleScenePhase(phase)
        }
    }
}
