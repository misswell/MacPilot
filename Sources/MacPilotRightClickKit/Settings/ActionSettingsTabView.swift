//
//  ActionSettingsView.swift
//  RClick
//
//  Created by 李旭 on 2024/4/9.
//

import SwiftUI

struct ActionSettingsTabView: View {
    @EnvironmentObject var appState: AppState

    let messager = Messager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RightClickSettingsCard {
                    Toggle(isOn: $appState.foldActionsMenu) {
                        Text(appLocalized: "Collapse actions menu")
                    }
                        .onChange(of: appState.foldActionsMenu) {
                            NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                        }
                }

                RightClickSettingsCard {
                    List {
                        ForEach($appState.actions) { $item in
                            LabeledContent {
                                Toggle(AppLocalization.localized("Enabled"), isOn: $item.enabled)
                                    .toggleStyle(.switch)
                                    .onChange(of: item.enabled) {
                                        appState.toggleActionItem()
                                        messager.sendRunningNotification()
                                    }
                                    .labelsHidden()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundColor(.secondary)
                                    Label(item.displayName, systemImage: item.icon)
                                }
                            }
                        }
                        .onMove { source, destination in
                            appState.moveActions(from: source, to: destination)
                            messager.sendRunningNotification()
                        }
                    }
                    .rightClickListStyle()
                    .frame(minHeight: 180)

                    HStack {
                        Spacer()
                        Button(AppLocalization.localized("Restore Defaults")) {
                            appState.resetActionItems()
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
    }
}
