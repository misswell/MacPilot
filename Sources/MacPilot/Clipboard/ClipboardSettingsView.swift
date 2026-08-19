//
//  ClipboardSettingsView.swift
//  MacPilot
//
//  剪切板设置面板。
//

import Carbon.HIToolbox
import SwiftUI

struct ClipboardSettingsView: View {
    @ObservedObject var clipboard: ClipboardModel
    @EnvironmentObject private var model: MacPilotModel
    @State private var showClearAllConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("clipboard")).font(.system(size: 30, weight: .bold))
                    Text(model.t("clipboardSubtitle")).foregroundStyle(.secondary)
                }

                SettingsCard {
                    Toggle(model.t("clipboardEnable"), isOn: Binding(
                        get: { clipboard.settings.isEnabled },
                        set: { clipboard.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    if !clipboard.settings.isEnabled {
                        Label(model.t("clipboardNotConfiguredHint"), systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if clipboard.settings.isEnabled {
                        permissionStatus
                    }
                }

                SettingsCard {
                    HStack(spacing: 12) {
                        Text(model.t("clipboardHotkey"))
                            .font(.subheadline)
                        Spacer()
                        ClipboardHotkeyRecorder(
                            binding: Binding(
                                get: { clipboard.settings.hotkey },
                                set: { clipboard.setHotkey($0) }
                            ),
                            help: model.t("clipboardHotkeyRecord")
                        )
                    }

                    Divider()

                    Picker(model.t("clipboardStorageLimit"), selection: Binding(
                        get: { clipboard.settings.storageLimit },
                        set: { clipboard.setStorageLimit($0) }
                    )) {
                        ForEach(ClipboardSettings.storageLimitOptions, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    Divider()

                    Toggle(model.t("clipboardPasteByDefault"), isOn: Binding(
                        get: { clipboard.settings.pasteByDefault },
                        set: { clipboard.setPasteByDefault($0) }
                    ))
                    Toggle(model.t("clipboardShowSearch"), isOn: Binding(
                        get: { clipboard.settings.showSearch },
                        set: { clipboard.setShowSearch($0) }
                    ))
                    Toggle(model.t("clipboardClearSystemClipboard"), isOn: Binding(
                        get: { clipboard.settings.clearSystemClipboardOnClear },
                        set: { clipboard.setClearSystemClipboardOnClear($0) }
                    ))
                    Toggle(model.t("clipboardPinsAtTop"), isOn: Binding(
                        get: { clipboard.settings.pinsAtTop },
                        set: { clipboard.setPinsAtTop($0) }
                    ))

                    Divider()

                    HStack {
                        Button(model.t("clipboardClearHistory")) {
                            clipboard.clearHistory()
                        }
                        Button(model.t("clipboardClearAllHistory"), role: .destructive) {
                            showClearAllConfirmation = true
                        }
                    }
                }
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
        .confirmationDialog(
            model.t("clipboardClearAllConfirm"),
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(model.t("clipboardClearAllHistory"), role: .destructive) {
                clipboard.clearAllHistory()
            }
            Button(model.t("cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        if clipboard.hasAccessibilityPermission {
            Label(model.t("clipboardAccessibilityReady"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(model.t("clipboardAccessibilityRequired"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                Button(model.t("clipboardGrantAccessibility")) {
                    clipboard.requestAccessibility()
                }
            }
        }
    }
}

// MARK: - Hotkey recorder

/// Pure SwiftUI hotkey recorder. Uses an `NSEvent` local monitor while
/// recording (instead of an `NSViewRepresentable`) so the control renders
/// correctly inside the frosted-glass `SettingsCard` scroll view.
/// Compact monospaced badge, consistent with the shortcut style used by the
/// screenshot and other feature pages.
private struct ClipboardHotkeyRecorder: View {
    @Binding var binding: SmartCaptureShortcutBinding
    var help: String = ""
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    private var displayText: String {
        if isRecording { return "…" }
        return binding.displayName.isEmpty ? "…" : binding.displayName
    }

    var body: some View {
        Button {
            isRecording = true
            installMonitor()
        } label: {
            Text(displayText)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(isRecording ? Color.accentColor : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isRecording
                        ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                        : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onDisappear(perform: removeMonitor)
    }

    private func installMonitor() {
        removeMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore presses that only toggle a modifier key.
            let modifierKeyCodes: Set<UInt16> = [
                UInt16(kVK_Shift), UInt16(kVK_RightShift), UInt16(kVK_Control), UInt16(kVK_RightControl),
                UInt16(kVK_Option), UInt16(kVK_RightOption), UInt16(kVK_Command), UInt16(kVK_RightCommand),
                UInt16(kVK_CapsLock), UInt16(kVK_Function)
            ]
            guard !modifierKeyCodes.contains(event.keyCode) else { return nil }
            // Escape cancels recording.
            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                removeMonitor()
                return nil
            }
            let candidate = SmartCaptureShortcutBinding(keyCode: event.keyCode, modifiers: InputSourceShortcutModifiers(event.modifierFlags))
            guard candidate.isValid else { return nil }
            binding = candidate
            isRecording = false
            removeMonitor()
            return nil
        }
    }

    private func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }
}
