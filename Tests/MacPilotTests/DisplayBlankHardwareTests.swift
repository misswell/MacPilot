import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import MacPilot

/// Opt-in only: briefly blanks the connected displays, then restores them.
/// The regular suite and CI must never darken a developer's screen.
struct DisplayBlankHardwareTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACPILOT_TEST_DISPLAY_BLANK"] == "1"))
    @MainActor func blankingDoesNotOverrideIdleSleepAndRestoresTheConnectedDisplays() async throws {
        // Do not overwrite a snapshot belonging to the running app.
        try #require(!FileManager.default.fileExists(atPath: DisplayBlankSnapshotStore.standard.fileURL.path))
        _ = NSApplication.shared
        let pid = ProcessInfo.processInfo.processIdentifier

        func displayAssertions() throws -> [[String: Any]] {
            var assertions: Unmanaged<CFDictionary>?
            try #require(IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess)
            let dictionary = try #require(assertions).takeRetainedValue() as NSDictionary
            let owned = dictionary[NSNumber(value: pid)] as? [[String: Any]] ?? []
            return owned.filter { ($0["AssertType"] as? String) == "PreventUserIdleDisplaySleep" }
        }

        try #require(displayAssertions().isEmpty)
        // Prove the query sees assertions owned by this test process before
        // using its empty result as the regression check.
        var fixture: IOPMAssertionID = 0
        try #require(IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacPilot display-blank regression probe" as CFString,
            &fixture
        ) == kIOReturnSuccess)
        var fixtureReleased = false
        defer { if !fixtureReleased { IOPMAssertionRelease(fixture) } }
        try #require(displayAssertions().count == 1)
        try #require(IOPMAssertionRelease(fixture) == kIOReturnSuccess)
        fixtureReleased = true

        var count: UInt32 = 0
        try #require(CGGetOnlineDisplayList(0, nil, &count) == .success)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        try #require(CGGetOnlineDisplayList(count, &displays, &count) == .success)
        let backlights = Dictionary(uniqueKeysWithValues: displays.prefix(Int(count)).compactMap { id in
            BrightnessDriver.shared?.current(id).map { (id, $0) }
        })
        let externalPowerModes = Dictionary(uniqueKeysWithValues: displays.prefix(Int(count)).compactMap { id in
            backlights[id] == nil ? DDCBacklight.shared?.powerMode(id).map { (id, $0) } : nil
        })

        defer { DisplayPower.unblankDisplay() }
        try #require(DisplayPower.blankDisplay())
        #expect(try displayAssertions().isEmpty)
        for id in displays.prefix(Int(count)) {
            let backlight = BrightnessDriver.shared?.current(id)
            let powerMode = backlight == nil ? DDCBacklight.shared?.powerMode(id) : nil
            print("Display blank hardware: id=\(id) brightness=\(String(describing: backlight)) powerMode=\(String(describing: powerMode)) overlay=\(ScreenBlankOverlay.shared.isShowing)")
            if let backlight {
                #expect(backlight == 0 || ScreenBlankOverlay.shared.isShowing)
            } else if let powerMode {
                #expect(DDCPacket.isPoweredDown(powerMode) || ScreenBlankOverlay.shared.isShowing)
            }
        }
        try await Task.sleep(for: .seconds(3))
        DisplayPower.unblankDisplay()
        #expect(try displayAssertions().isEmpty)
        for (id, original) in backlights {
            let restored = try #require(BrightnessDriver.shared?.current(id))
            #expect(abs(restored - original) <= 0.01)
            print("Display restored hardware: id=\(id) brightness=\(restored)")
        }
        for (id, original) in externalPowerModes where original == DDCPacket.powerOn {
            let restored = try #require(DDCBacklight.shared?.powerMode(id))
            #expect(restored == DDCPacket.powerOn)
            print("Display restored hardware: id=\(id) powerMode=\(restored)")
        }
    }
}
