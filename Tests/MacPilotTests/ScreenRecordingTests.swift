import Foundation
import Carbon.HIToolbox
import Testing
@testable import MacPilot

struct ScreenRecordingTests {
    @Test func recordingShortcutDefaultIsUsableAndMigratesTheOldSystemConflict() throws {
        #expect(ScreenRecordingSettings.defaultShortcut.displayName == "⌥⌘5")
        #expect(SmartCaptureSystemShortcutDetector.conflicts(for: ScreenRecordingSettings.defaultShortcut).isEmpty)

        let explicitLegacyBinding = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_ANSI_5),
            modifiers: [.command, .shift]
        )
        #expect(ScreenRecordingSettings(shortcut: explicitLegacyBinding).shortcut == explicitLegacyBinding)

        let legacy = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: Data("{\"shortcut\":{\"keyCode\":23,\"modifiers\":9}}".utf8)
        )
        #expect(legacy.shortcut == ScreenRecordingSettings.defaultShortcut)
    }

    @Test func recordingCaptureModesHaveStableLabelsAndRoundTrip() throws {
        #expect(ScreenRecordingCaptureMode.allCases == [.area, .fullscreen, .application])
        #expect(ScreenRecordingCaptureMode.area.titleKey == "scRecordingArea")
        #expect(ScreenRecordingCaptureMode.fullscreen.titleKey == "scRecordingFullscreen")
        #expect(ScreenRecordingCaptureMode.application.titleKey == "scRecordingApplication")

        let settings = ScreenRecordingSettings(captureMode: .application)
        let decoded = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.captureMode == .application)
    }

    @Test @MainActor func areaRecordingRequestsASelectionBeforeStartingTheWriter() {
        let model = ScreenRecordingModel()
        model.setCaptureMode(.area)
        var requestedMode: ScreenRecordingCaptureMode?
        model.onRequestSelection = { requestedMode = $0 }

        model.start()

        #expect(requestedMode == .area)
        #expect(model.state == .idle)
    }

    @Test func recordingSettingsClampFrameRateAndRoundTrip() throws {
        let settings = ScreenRecordingSettings(
            outputFolder: "/tmp/recordings",
            format: .mp4,
            framesPerSecond: 120,
            showsCursor: false,
            capturesSystemAudio: true
        )

        #expect(settings.framesPerSecond == 60)
        let decoded = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)
    }

    @Test func recordingSettingsClampLowFrameRate() {
        #expect(ScreenRecordingSettings(framesPerSecond: 1).framesPerSecond == 5)
        #expect(ScreenRecordingSettings(framesPerSecond: 30).framesPerSecond == 30)
    }

    @Test func recordingSettingsDecodeLegacyPayloadWithSafeDefaults() throws {
        let settings = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: Data("{\"format\":\"mov\",\"framesPerSecond\":30}".utf8)
        )
        #expect(settings.captureMode == .area)
        #expect(settings.showsCursor)
        #expect(!settings.capturesSystemAudio)
    }

    @Test @MainActor func recordingModelPersistsPreferenceChanges() {
        let model = ScreenRecordingModel()
        var persisted = false
        model.persist = { persisted = true }

        model.setFormat(.mp4)
        model.setFramesPerSecond(24)
        model.setShowsCursor(false)
        model.setCapturesSystemAudio(true)

        #expect(model.settings.format == .mp4)
        #expect(model.settings.framesPerSecond == 24)
        #expect(!model.settings.showsCursor)
        #expect(model.settings.capturesSystemAudio)
        #expect(persisted)
    }

    @Test @MainActor func recordingShortcutRejectsScreenshotShortcutOutsideTheEditor() {
        let model = ScreenRecordingModel()
        let original = model.settings.shortcut
        let screenshotBinding = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_ANSI_R),
            modifiers: [.command, .option]
        )
        model.isShortcutInUse = { $0 == screenshotBinding }

        #expect(!model.setShortcut(screenshotBinding))
        #expect(model.settings.shortcut == original)
    }

    @Test func recordingErrorsExposeStableLocalizationKeys() {
        #expect(ScreenRecordingError.permissionRequired.messageKey == "scRecordingPermissionRequired")
        #expect(ScreenRecordingError.noVideoFrames.messageKey == "scRecordingNoVideoFrames")
    }
}
