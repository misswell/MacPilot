import Foundation
import Testing
@testable import MacPilot

struct ScreenCaptureTests {

    @Test func screenCaptureResetUsesCurrentBundleIdentifier() {
        let command = ScreenCaptureResetCommand(bundleIdentifier: "com.misswell.macpilot")

        #expect(command.executableURL == URL(fileURLWithPath: "/usr/bin/tccutil"))
        #expect(command.arguments == ["reset", "ScreenCapture", "com.misswell.macpilot"])
    }

    // MARK: - Busy/idle hour detection

    @Test func normalRangeDetectsBusyHours() {
        let settings = ScreenCaptureSettings(busyStartHour: 9, busyEndHour: 18)
        #expect(settings.isBusyHour(9) == true)
        #expect(settings.isBusyHour(12) == true)
        #expect(settings.isBusyHour(17) == true)
        #expect(settings.isBusyHour(18) == false)
        #expect(settings.isBusyHour(8) == false)
        #expect(settings.isBusyHour(23) == false)
        #expect(settings.isBusyHour(0) == false)
    }

    @Test func wrapAroundMidnightDetectsBusyHours() {
        let settings = ScreenCaptureSettings(busyStartHour: 22, busyEndHour: 6)
        #expect(settings.isBusyHour(22) == true)
        #expect(settings.isBusyHour(23) == true)
        #expect(settings.isBusyHour(0) == true)
        #expect(settings.isBusyHour(3) == true)
        #expect(settings.isBusyHour(5) == true)
        #expect(settings.isBusyHour(6) == false)
        #expect(settings.isBusyHour(12) == false)
        #expect(settings.isBusyHour(21) == false)
    }

    @Test func equalStartAndEndMeansNoBusyPeriod() {
        let settings = ScreenCaptureSettings(busyStartHour: 9, busyEndHour: 9)
        for hour in 0..<24 {
            #expect(settings.isBusyHour(hour) == false, "Hour \(hour) should not be busy when start == end")
        }
    }

    // MARK: - Interval selection

    @Test func busyIntervalUsedDuringBusyHours() {
        let settings = ScreenCaptureSettings(
            busyStartHour: 9, busyEndHour: 18,
            busyIntervalMinutes: 5, idleIntervalMinutes: 30
        )
        let calendar = Calendar.current
        var busyDate = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        #expect(settings.currentIntervalMinutes(at: busyDate) == 5)

        busyDate = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: Date())!
        #expect(settings.currentIntervalMinutes(at: busyDate) == 5)
    }

    @Test func idleIntervalUsedDuringIdleHours() {
        let settings = ScreenCaptureSettings(
            busyStartHour: 9, busyEndHour: 18,
            busyIntervalMinutes: 5, idleIntervalMinutes: 30
        )
        let calendar = Calendar.current
        let idleDate = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        #expect(settings.currentIntervalMinutes(at: idleDate) == 30)
    }

    @Test func idleIntervalUsedAtBoundaryEnd() {
        let settings = ScreenCaptureSettings(
            busyStartHour: 9, busyEndHour: 18,
            busyIntervalMinutes: 5, idleIntervalMinutes: 30
        )
        let calendar = Calendar.current
        let boundaryDate = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        // 18:00 is the first idle hour (busy range is [9, 18))
        #expect(settings.currentIntervalMinutes(at: boundaryDate) == 30)
    }

    // MARK: - Defaults

    @Test func defaultsAreSensible() {
        let settings = ScreenCaptureSettings()
        #expect(settings.isEnabled == false)
        #expect(settings.outputFolder == "")
        #expect(settings.busyIntervalMinutes == 10)
        #expect(settings.idleIntervalMinutes == 30)
        #expect(settings.imageFormat == .heic)
        #expect(settings.quality == 0.7)
        #expect(settings.maxRetentionDays == 30)
        #expect(settings.captureAllDisplays == false)
        #expect(settings.showsCursor == true)
    }

    @Test func qualityIsClampedToValidRange() {
        let high = ScreenCaptureSettings(quality: 2.0)
        #expect(high.quality == 1.0)
        let low = ScreenCaptureSettings(quality: -1.0)
        #expect(low.quality == 0.05)
    }

    @Test func hoursAreClampedToValidRange() {
        let settings = ScreenCaptureSettings(busyStartHour: 30, busyEndHour: -5)
        #expect(settings.busyStartHour == 23)
        #expect(settings.busyEndHour == 0)
    }

    @Test func intervalsAreAtLeastOneMinute() {
        let settings = ScreenCaptureSettings(busyIntervalMinutes: 0, idleIntervalMinutes: -10)
        #expect(settings.busyIntervalMinutes == 1)
        #expect(settings.idleIntervalMinutes == 1)
    }

    // MARK: - Codable round-trip

    @Test func settingsRoundTripThroughCodable() throws {
        let original = ScreenCaptureSettings(
            isEnabled: true,
            outputFolder: "/tmp/screenshots",
            busyStartHour: 8,
            busyEndHour: 20,
            busyIntervalMinutes: 15,
            idleIntervalMinutes: 60,
            imageFormat: .jpeg,
            quality: 0.85,
            maxRetentionDays: 7,
            captureAllDisplays: true,
            showsCursor: false
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ScreenCaptureSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func settingsDecodeFromMinimalJSON() throws {
        // Simulates loading a config written before screen capture existed (all fields absent).
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: json)
        #expect(decoded.isEnabled == false)
        #expect(decoded.busyIntervalMinutes == 10)
        #expect(decoded.imageFormat == .heic)
        #expect(decoded.quality == 0.7)
    }

    // MARK: - Output folder validation

    @Test func emptyFolderIsInvalid() {
        let settings = ScreenCaptureSettings(outputFolder: "")
        #expect(settings.isOutputFolderValid == false)
    }

    @Test func whitespaceOnlyFolderIsInvalid() {
        let settings = ScreenCaptureSettings(outputFolder: "   ")
        #expect(settings.isOutputFolderValid == false)
    }

    @Test func nonexistentFolderIsInvalid() {
        let settings = ScreenCaptureSettings(outputFolder: "/this/path/should/not/exist/abcdef12345")
        #expect(settings.isOutputFolderValid == false)
    }

    @Test func tempFolderIsValid() {
        let settings = ScreenCaptureSettings(outputFolder: NSTemporaryDirectory())
        #expect(settings.isOutputFolderValid == true)
    }
}
