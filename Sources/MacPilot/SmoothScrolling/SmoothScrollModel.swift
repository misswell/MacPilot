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
        refreshPermissionStatus()
    }

    func applyLoadedSettings(_ loaded: SmoothScrollSettings) {
        settings = loaded.clamped()
        refreshPermissionStatus()
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
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        controller.activate(settings: settings)
        persist?()
    }

    func setSmoothVertical(_ enabled: Bool) {
        settings.smoothVertical = enabled
        controller.activate(settings: settings)
        persist?()
    }

    func setSmoothHorizontal(_ enabled: Bool) {
        settings.smoothHorizontal = enabled
        controller.activate(settings: settings)
        persist?()
    }

    func setReverseScrollingEnabled(_ enabled: Bool) {
        settings.reverseScrollingEnabled = enabled
        controller.activate(settings: settings)
        persist?()
    }

    func setReverseVertical(_ enabled: Bool) {
        settings.reverseVertical = enabled
        controller.activate(settings: settings)
        persist?()
    }

    func setReverseHorizontal(_ enabled: Bool) {
        settings.reverseHorizontal = enabled
        controller.activate(settings: settings)
        persist?()
    }

    func setMinimumStep(_ value: Double) {
        settings.minimumStep = value.clamped(to: SmoothScrollSettings.stepRange)
        controller.activate(settings: settings)
        persist?()
    }

    func setSpeed(_ value: Double) {
        settings.speed = value.clamped(to: SmoothScrollSettings.speedRange)
        controller.activate(settings: settings)
        persist?()
    }

    func setDuration(_ value: Double) {
        settings.duration = value.clamped(to: SmoothScrollSettings.durationRange)
        controller.activate(settings: settings)
        persist?()
    }

    func setDeadZone(_ value: Double) {
        settings.deadZone = value.clamped(to: SmoothScrollSettings.deadZoneRange)
        controller.activate(settings: settings)
        persist?()
    }

    func setAdaptiveSpeedEnabled(_ enabled: Bool) {
        settings.adaptiveSpeedEnabled = enabled
        controller.activate(settings: settings)
        persist?()
    }

    func setAdaptiveSpeedMaximum(_ value: Double) {
        settings.adaptiveSpeedMaximum = value.clamped(to: SmoothScrollSettings.adaptiveSpeedRange)
        controller.activate(settings: settings)
        persist?()
    }

    func setBlockSmoothWhileCommandHeld(_ enabled: Bool) {
        settings.blockSmoothWhileCommandHeld = enabled
        controller.activate(settings: settings)
        persist?()
    }

    func setSimulatesTrackpadPhases(_ enabled: Bool) {
        settings.simulatesTrackpadPhases = enabled
        controller.activate(settings: settings)
        persist?()
    }

    func setExcludedApplication(_ bundleIdentifier: String, enabled: Bool) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        let canonicalIdentifier = SmoothScrollApplicationExclusions.canonicalIdentifier(identifier)

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
        controller.activate(settings: settings)
        persist?()
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
        controller.activate(settings: settings)
        persist?()
    }

    func requestAccessibility() {
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        controller.activate(settings: settings)
    }

    func refreshPermissionStatus() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        controller.activate(settings: settings)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
