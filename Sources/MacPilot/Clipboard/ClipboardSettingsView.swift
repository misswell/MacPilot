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

                if clipboard.settings.isEnabled {
                    SettingsCard {
                        Text(model.t("clipboardHotkey"))
                            .font(.headline)
                        ClipboardHotkeyRecorder(
                            binding: Binding(
                                get: { clipboard.settings.hotkey },
                                set: { clipboard.setHotkey($0) }
                            )
                        )

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

private struct ClipboardHotkeyRecorder: View {
    @Binding var binding: SmartCaptureShortcutBinding

    var body: some View {
        ClipboardHotkeyRecorderNSViewRepresentable(binding: $binding)
            .frame(width: 220, height: 34)
    }
}

private struct ClipboardHotkeyRecorderNSViewRepresentable: NSViewRepresentable {
    @Binding var binding: SmartCaptureShortcutBinding

    func makeNSView(context: Context) -> ClipboardHotkeyRecorderNSView {
        let view = ClipboardHotkeyRecorderNSView()
        view.binding = $binding
        view.onCapture = { keyCode, modifiers in
            let newBinding = SmartCaptureShortcutBinding(keyCode: keyCode, modifiers: modifiers)
            if newBinding.isValid {
                binding = newBinding
            }
        }
        return view
    }

    func updateNSView(_ nsView: ClipboardHotkeyRecorderNSView, context: Context) {
        nsView.displayText = binding.displayName.isEmpty ? "…" : binding.displayName
        nsView.needsDisplay = true
    }
}

@MainActor
private final class ClipboardHotkeyRecorderNSView: NSView {
    var binding: Binding<SmartCaptureShortcutBinding>?
    var onCapture: ((UInt16, InputSourceShortcutModifiers) -> Void)?
    var displayText: String = "…"

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        displayText = "…"
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let modifierKeys: Set<UInt16> = [
            UInt16(kVK_Shift), UInt16(kVK_RightShift), UInt16(kVK_Control), UInt16(kVK_RightControl),
            UInt16(kVK_Option), UInt16(kVK_RightOption), UInt16(kVK_Command), UInt16(kVK_RightCommand)
        ]
        guard !modifierKeys.contains(event.keyCode) else { return }
        let modifiers = InputSourceShortcutModifiers(event.modifierFlags)
        guard !modifiers.isEmpty else { return }
        onCapture?(event.keyCode, modifiers)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        let title = displayText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2),
            withAttributes: attributes
        )

        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
    }
}
