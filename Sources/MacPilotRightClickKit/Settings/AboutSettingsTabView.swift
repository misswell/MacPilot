//
//  AdvancedSettingsView.swift
//  RClick
//
//  Created by 李旭 on 2024/4/4.
//

import AppKit
import ExtensionFoundation
import ExtensionKit
import FinderSync
import SwiftUI

struct AboutSettingsTabView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RightClickSettingsCard {
                    VStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 96, height: 96)

                        VStack(spacing: 4) {
                            Text("MacPilot").font(.title)
                            Text(String(format: AppLocalization.localized("Version %@ (%@)"), getAppVersion(), getBuildVersion()))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                RightClickSettingsCard {
                    Text(appLocalized: "MacPilot's Finder context menu provides quick actions for opening folders, managing files, and creating new files.")
                        .font(.body)
                }

                RightClickSettingsCard {
                    Link(destination: URL(string: "https://github.com/misswell/MacPilot")!) {
                        Label("github.com/misswell/MacPilot", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .padding(.vertical, 20)
        }
    }

    func getAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return AppLocalization.localized("Unknown")
    }

    func getBuildVersion() -> String {
        if let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return buildVersion
        }
        return AppLocalization.localized("Unknown")
    }
}

#Preview {
    AboutSettingsTabView()
}
