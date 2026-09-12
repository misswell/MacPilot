import SwiftUI

/// The three top-level tabs. Named so `HomeView` can send the user to the
/// device list when it finds a Mac that still needs pairing.
enum RootTab: Hashable {
    case home
    case devices
    case settings
}

/// App shell. Three tabs keep the four control actions one tap from launch.
struct RootView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: RootTab = .home

    var body: some View {
        TabView(selection: $selection) {
            HomeView(selectedTab: $selection)
                .tabItem { Label(appModel.text("tabHome"), systemImage: "av.remote") }
                .tag(RootTab.home)
            DevicesView()
                .tabItem { Label(appModel.text("tabDevices"), systemImage: "macbook.and.iphone") }
                .tag(RootTab.devices)
            RemoteSettingsView()
                .tabItem { Label(appModel.text("tabSettings"), systemImage: "gearshape") }
                .tag(RootTab.settings)
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
