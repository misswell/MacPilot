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

    // noErr: consent already granted; errAEEventNotHandled: this event does
    // not require automation consent. Anything else means the graceful
    // terminate would surface the dialog, so fall back to SIGTERM.
    let consent = AEDeterminePermissionToAutomateTarget(
        &target,
        kCoreEventClass,
        kAEQuitApplication,
        false
    )
    if consent == noErr || consent == errAEEventNotHandled {
        application.terminate()
    } else {
        kill(pid, SIGTERM)
    }
}
