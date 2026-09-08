//
//  GracefulQuit.swift
//  MacPilot
//
//  Terminating another app with `NSRunningApplication.terminate()` delivers
//  a quit Apple Event, and quit events are subject to the Automation
//  privacy consent on recent macOS releases — the first terminate after a
//  relaunch may otherwise request permission to control the target app.
//  This is distinct from App Group data-access consent.
//  Check with `askUser = false`: only when already permitted use graceful terminate,
//  otherwise fall back to SIGTERM, which needs no privacy grant between
//  same-user processes.
//

import AppKit
import ApplicationServices
import Darwin
import MacPilotRightClickKit

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
    PermissionDiagnostics.record("quit.preflight.begin targetPID=\(pid)")

    var processID = pid
    var target = AEAddressDesc()
    guard AECreateDesc(
        typeKernelProcessID,
        &processID,
        MemoryLayout<pid_t>.size,
        &target
    ) == noErr else {
        PermissionDiagnostics.record("quit.preflight.descriptor-failed targetPID=\(pid) strategy=signal")
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
    PermissionDiagnostics.record("quit.preflight.end targetPID=\(pid) status=\(consent) strategy=\(automationQuitStrategy(for: consent))")
    if automationQuitStrategy(for: consent) == .graceful {
        application.terminate()
    } else {
        kill(pid, SIGTERM)
    }
}
