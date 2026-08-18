//
//  SettingsView.swift
//  RClick
//
//  Created by 李旭 on 2024/4/4.
//

import SwiftUI

enum Tabs: String, CaseIterable, Identifiable {
    case general = "General"
    case apps = "Apps"
    case actions = "Actions"
    case newFile = "New File"
    case cdirs = "Common Dir"
    case about = "About"

    var id: String { self.rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .apps: "app.badge"
        case .actions: "bolt.square"
        case .newFile: "doc.badge.plus"
        case .cdirs: "folder.badge.gearshape"
        case .about: "info.circle"
        }
    }
}

struct RightClickSettingsView: View {
    @State private var selectedTab: Tabs = .general
    @EnvironmentObject var appState: AppState

    @ViewBuilder var detailView: some View {
        // 右侧内容
        Group {
            switch self.selectedTab {
            case .general:
                GeneralSettingsTabView()
            case .apps:
                AppsSettingsTabView()
            case .actions:
                ActionSettingsTabView()
            case .newFile:
                NewFileSettingsTabView()
            case .cdirs:
                CommonDirsSettingTabView()
            case .about:
                AboutSettingsTabView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 450)
        .padding()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(appLocalized: "Right-click Menu")
                    .font(.system(size: 26, weight: .bold))
                Text(appLocalized: "Right-click Menu Subtitle")
                    .foregroundStyle(.secondary)
            }

            tabBar

            Divider()

            detailView
        }
        .padding(.horizontal, 36)
        .padding(.top, 30)
        .padding(.bottom, 30)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Tabs.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label {
                            Text(appLocalized: tab.rawValue)
                        } icon: {
                            Image(systemName: tab.icon)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func getAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return AppLocalization.localized("Unknown")
    }
}


#Preview {
    RightClickSettingsView()
}
