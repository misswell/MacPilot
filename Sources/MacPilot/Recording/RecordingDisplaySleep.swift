//
//  RecordingDisplaySleep.swift
//  MacPilot
//
//  Holds an IOKit power assertion so the display (and with it the
//  recording) survives an idle timeout, releasing the assertion when the
//  recording ends.
//

import Foundation
import IOKit.pwr_mgt
import OSLog

/// Keeps the display awake while a recording is running by holding an IOKit
/// power assertion, releasing it when the recording ends.
final class DisplaySleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false

    func acquire(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isHeld else { return }
        var assertionID = IOPMAssertionID()
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            logger.error("Could not keep the display awake: \(result, privacy: .public)")
            return
        }
        self.assertionID = assertionID
        isHeld = true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard isHeld else { return }
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            assertionID = 0
            isHeld = false
        }
    }

    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "DisplaySleepAssertion")
}
