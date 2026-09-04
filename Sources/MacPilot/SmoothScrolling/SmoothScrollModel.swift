import ApplicationServices
import Foundation
import SwiftUI

@MainActor
final class SmoothScrollModel: ObservableObject {
    @Published private(set) var settings = SmoothScrollSettings()
    @Published private(set) var hasAccessibilityPermission = false

    let controller = SmoothScrollController()
    var persist: (() -> Void)?

    private var isActive = false

    init() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func applyLoadedSettings(_ loaded: SmoothScrollSettings) {
        settings = loaded.clamped()
        if isActive {
            controller.activate(settings: settings)
        }
    }

    func activateFromConfiguration() {
        guard !isActive else { return }
        isActive = true
        refreshPermissionStatus()
        controller.activate(settings: settings)
    }

    func shutdown() {
        controller.shutdown()
    }

    func setEnabled(_ enabled: Bool) {
        apply { $0.isEnabled = enabled }
    }

    func setSmoothVertical(_ enabled: Bool) {
        apply { $0.smoothVertical = enabled }
    }

    func setSmoothHorizontal(_ enabled: Bool) {
        apply { $0.smoothHorizontal = enabled }
    }

    func setReverseScrollingEnabled(_ enabled: Bool) {
        apply { $0.reverseScrollingEnabled = enabled }
    }

    func setReverseVertical(_ enabled: Bool) {
        apply { $0.reverseVertical = enabled }
    }

    func setReverseHorizontal(_ enabled: Bool) {
        apply { $0.reverseHorizontal = enabled }
    }

    func setMinimumStep(_ value: Double) {
        apply { $0.minimumStep = value.clamped(to: SmoothScrollSettings.stepRange) }
    }

    func setSpeed(_ value: Double) {
        apply { $0.speed = value.clamped(to: SmoothScrollSettings.speedRange) }
    }

    func setDuration(_ value: Double) {
        apply { $0.duration = value.clamped(to: SmoothScrollSettings.durationRange) }
    }

    func setDeadZone(_ value: Double) {
        apply { $0.deadZone = value.clamped(to: SmoothScrollSettings.deadZoneRange) }
    }

    func setAdaptiveSpeedEnabled(_ enabled: Bool) {
        apply { $0.adaptiveSpeedEnabled = enabled }
    }

    func setAdaptiveSpeedMaximum(_ value: Double) {
        apply { $0.adaptiveSpeedMaximum = value.clamped(to: SmoothScrollSettings.adaptiveSpeedRange) }
    }

    func setBlockSmoothWhileCommandHeld(_ enabled: Bool) {
        apply { $0.blockSmoothWhileCommandHeld = enabled }
    }

    func setSimulatesTrackpadPhases(_ enabled: Bool) {
        apply { $0.simulatesTrackpadPhases = enabled }
    }

    func setExcludedApplication(_ bundleIdentifier: String, enabled: Bool) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        let canonicalIdentifier = SmoothScrollApplicationExclusions.canonicalIdentifier(identifier)
        apply { settings in
            var identifiers = settings.excludedApplicationBundleIdentifiers
            if enabled {
                guard !identifiers.contains(where: {
                    SmoothScrollApplicationExclusions.canonicalIdentifier($0) == canonicalIdentifier
                }) else { return }
                identifiers.append(identifier)
            } else {
                identifiers.removeAll {
                    SmoothScrollApplicationExclusions.canonicalIdentifier($0) == canonicalIdentifier
                }
            }
            settings.excludedApplicationBundleIdentifiers = SmoothScrollApplicationExclusions
                .normalizedIdentifiers(identifiers)
            if !enabled {
                settings.excludedApplicationReverseBundleIdentifiers.removeAll {
                    SmoothScrollApplicationExclusions.canonicalIdentifier($0) == canonicalIdentifier
                }
            }
        }
    }

    func isExcludedApplicationReversed(_ bundleIdentifier: String) -> Bool {
        let canonicalIdentifier = SmoothScrollApplicationExclusions.canonicalIdentifier(bundleIdentifier)
        return settings.excludedApplicationReverseBundleIdentifiers.contains {
            SmoothScrollApplicationExclusions.canonicalIdentifier($0) == canonicalIdentifier
        }
    }

    func setExcludedApplicationReversed(_ bundleIdentifier: String, reversed: Bool) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        let canonicalIdentifier = SmoothScrollApplicationExclusions.canonicalIdentifier(identifier)
        apply { settings in
            guard settings.excludedApplicationBundleIdentifiers.contains(where: {
                SmoothScrollApplicationExclusions.canonicalIdentifier($0) == canonicalIdentifier
            }) else { return }

            var reversedIdentifiers = settings.excludedApplicationReverseBundleIdentifiers
            let wasReversed = reversedIdentifiers.contains {
                SmoothScrollApplicationExclusions.canonicalIdentifier($0) == canonicalIdentifier
            }
            guard wasReversed != reversed else { return }

            if reversed {
                reversedIdentifiers.append(identifier)
            } else {
                reversedIdentifiers.removeAll {
                    SmoothScrollApplicationExclusions.canonicalIdentifier($0) == canonicalIdentifier
                }
            }
            settings.excludedApplicationReverseBundleIdentifiers = SmoothScrollApplicationExclusions
                .normalizedIdentifiers(reversedIdentifiers)
        }
    }

    func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refreshPermissionStatus()
    }

    func refreshPermissionStatus() {
        let granted = AXIsProcessTrusted()
        guard granted != hasAccessibilityPermission else { return }
        hasAccessibilityPermission = granted
        // A newly granted (or revoked) permission changes whether the tap can
        // run; a settings change already re-evaluates it on its own.
        controller.activate(settings: settings)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Applies a settings change, then reconfigures the tap and persists.
    /// Transforms that leave the settings unchanged are no-ops.
    private func apply(_ transform: (inout SmoothScrollSettings) -> Void) {
        var updated = settings
        transform(&updated)
        guard updated != settings else { return }
        settings = updated
        controller.activate(settings: settings)
        persist?()
    }
}
