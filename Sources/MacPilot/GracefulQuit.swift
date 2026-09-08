//
//  GracefulQuit.swift
//  MacPilot
//
//  Terminating another app with `NSRunningApplication.terminate()` delivers
//  a quit Apple Event, and quit events are subject to the Automation
//  privacy consent on recent macOS releases — the first terminate after a
//  relaunch would otherwise pop the "wants to access data from other apps"
//  dialog. Ask the system for consent with `askUser = false` first: when
//  the event is exempt or already permitted use the graceful terminate,
//  otherwise fall back to SIGTERM, which needs no privacy grant between
//  same-user processes.
//

import AppKit
import ApplicationServices
import Darwin

enum AutomationQuitStrategy: Equatable {
    case graceful
    case signal
}

/// Only an explicit `noErr` proves that sending the quit Apple Event is safe.
/// Every other status must avoid `NSRunningApplication.terminate()`, including
/// statuses that are not normally expected from the permission preflight.
func automationQuitStrategy(for status: OSStatus) -> AutomationQuitStrategy {
    status == noErr ? .graceful : .signal
}

/// Quits `application` without surfacing the automation consent dialog.
@MainActor
func quitWithoutAutomationPrompt(_ application: NSRunningApplication) {
    let pid = application.processIdentifier
    guard pid > 0 else { return }

    var processID = pid
    var target = AEAddressDesc()
    guard AECreateDesc(
        typeKernelProcessID,
        &processID,
        MemoryLayout<pid_t>.size,
        &target
    ) == noErr else {
        kill(pid, SIGTERM)
        return
    }
    defer { AEDisposeDesc(&target) }

    // Only noErr means the quit event is already permitted. In particular,
    // errAEEventWouldRequireUserConsent and every unexpected status must use
    // SIGTERM so this path can never trigger an Automation prompt.
    let consent = AEDeterminePermissionToAutomateTarget(
        &target,
        kCoreEventClass,
        kAEQuitApplication,
        false
    )
    if automationQuitStrategy(for: consent) == .graceful {
        application.terminate()
    } else {
        kill(pid, SIGTERM)
    }
}
