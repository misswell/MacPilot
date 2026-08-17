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
        Form {
            Section {
                VStack(spacing: 12) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 96, height: 96)

                    VStack(spacing: 4) {
                        Text("MacPilot").font(.title)
                        Text(String(format: AppLocalization.localized("Version %@ (%@)"), getAppVersion(), getBuildVersion()))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            Section {
                Text(appLocalized: "MacPilot's Finder context menu provides quick actions for opening folders, managing files, and creating new files.")
                    .font(.body)
            }

            Section {
                Link(destination: URL(string: "https://github.com/wflixu/RClick")!) {
                    Label("github.com/wflixu/RClick", image: "github")
                }
            }
        }
        .formStyle(.grouped)
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
