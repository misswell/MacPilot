@preconcurrency import ApplicationServices
@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Foundation

/// Low-level presenter for smooth wheel scrolling.
///
/// A single CGEvent tap reads physical wheel events on the main run loop,
/// classifies them with `SmoothScrollGate`, feeds accepted deltas into a
/// CVDisplayLink-backed interpolator, then posts synthetic continuous scroll
/// events directly to the original target process.
@MainActor
final class SmoothScrollController {
    private let runtime = SmoothScrollRuntime()
    private var activeSettings = SmoothScrollSettings()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastPhysicalWheelTime: CFTimeInterval = 0
    private var commandHeld = false
    private var excludedBundleIdentifiers: Set<String> = []
    private var reversedExcludedBundleIdentifiers: Set<String> = []
    private var processBundleIdentifiers: [pid_t: String] = [:]
    private var excludedProcessIDs: Set<pid_t> = []
    private var reversedExcludedProcessIDs: Set<pid_t> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private(set) var isActive = false

    private let eventMask: CGEventMask = CGEventMask(
        (1 << CGEventType.scrollWheel.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    )

    func activate(settings: SmoothScrollSettings) {
        activeSettings = settings.clamped()
        let exclusionsChanged = refreshExcludedApplicationCacheIfNeeded()
        guard activeSettings.requiresInputTap else {
            deactivate()
            return
        }
        guard AXIsProcessTrusted() else {
            deactivate()
            return
        }
        if exclusionsChanged {
            runtime.stop()
            lastPhysicalWheelTime = 0
        }

        // Settings must reach the runtime before the tap can deliver its
        // first event; the runtime does not re-apply them per event.
        runtime.update(settings: activeSettings)

        if !isActive {
            guard let tap = CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap,
                place: .tailAppendEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: Self.eventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                return
            }
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isActive = true
            installWorkspaceObservers()
        }

        if activeSettings.isEnabled {
            runtime.start()
        } else {
            // Reversal-only mode still needs the event tap, but must not keep
            // a display link or a stale smooth-scroll buffer alive.
            runtime.stop()
        }
    }

    func deactivate() {
        guard isActive || eventTap != nil else {
            runtime.stop()
            removeWorkspaceObservers()
            clearExcludedApplicationCache()
            return
        }
        isActive = false
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            if CFRunLoopContainsSource(CFRunLoopGetCurrent(), source, .commonModes) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            runLoopSource = nil
        }
        removeWorkspaceObservers()
        clearExcludedApplicationCache()
        commandHeld = false
        lastPhysicalWheelTime = 0
        runtime.stop()
    }

    func shutdown() {
        deactivate()
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<SmoothScrollController>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated {
            controller.handleTapEvent(type: type, event: event)
        }
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            runtime.stop()
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            let held = event.flags.contains(.maskCommand)
            if held { runtime.stop() }
            commandHeld = held
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.eventSourceUserData) != SmoothScrollRuntime.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        let settings = activeSettings
        let targetProcessID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let vertical = SmoothScrollWheelEventParser.axis(.vertical, in: event)
        let horizontal = SmoothScrollWheelEventParser.axis(.horizontal, in: event)
        let decision = SmoothScrollGate.decide(
            isExcludedTarget: shouldBypassSmoothing(for: targetProcessID),
            shouldReverseExcludedTarget: shouldReverseExcludedApplication(for: targetProcessID),
            isRemoteSmoothed: SmoothScrollWheelEventParser.isRemoteSmoothed(event),
            vertical: vertical,
            horizontal: horizontal,
            isTrackpadLike: SmoothScrollWheelEventParser.isTrackpadLike(event),
            settings: settings,
            commandBlocked: settings.blockSmoothWhileCommandHeld && commandHeld
        )

        switch decision.action {
        case .bypassExcluded(let reverse):
            // Excluded apps do not enter the smoothing pipeline, but their
            // independent reversal must also cover events carrying trackpad
            // phase metadata. Keep this before the normal input classification.
            if reverse {
                _ = SmoothScrollWheelEventParser.reverse(.vertical, in: event)
                _ = SmoothScrollWheelEventParser.reverse(.horizontal, in: event)
            }
            runtime.stop()
            lastPhysicalWheelTime = 0
            return Unmanaged.passUnretained(event)
        case .passThroughRemoteSmoothed, .passThroughInvalidAxes:
            return Unmanaged.passUnretained(event)
        case .smooth:
            reverseOriginalEvent(decision, in: event)
        case .passThroughTrackpadLike:
            // Some mouse drivers set the same continuous/phase fields as a
            // trackpad. They must bypass smoothing, but not independent reversal.
            reverseOriginalEvent(decision, in: event)
            return Unmanaged.passUnretained(event)
        case .passThroughSmoothingDisabled:
            reverseOriginalEvent(decision, in: event)
            runtime.stop()
            lastPhysicalWheelTime = 0
            return Unmanaged.passUnretained(event)
        case .passThroughCommandBlocked:
            reverseOriginalEvent(decision, in: event)
            runtime.stop()
            return Unmanaged.passUnretained(event)
        }

        let now = CFAbsoluteTimeGetCurrent()
        let velocityInterval = lastPhysicalWheelTime == 0 ? SmoothScrollVelocityBoost.slowInterval : now - lastPhysicalWheelTime
        let velocityBoost = SmoothScrollVelocityBoost.factor(
            interval: velocityInterval,
            enabled: settings.adaptiveSpeedEnabled,
            maximum: settings.adaptiveSpeedMaximum
        )
        let plan = SmoothScrollPlanner.plan(vertical: vertical, horizontal: horizontal, settings: settings)
        var boostedPlan = plan
        if plan.consumesAnyAxis {
            boostedPlan.verticalTarget *= velocityBoost
            boostedPlan.horizontalTarget *= velocityBoost
        }
        defer { lastPhysicalWheelTime = now }

        guard plan.consumesAnyAxis else { return Unmanaged.passUnretained(event) }

        let accepted = runtime.update(
            event: event,
            verticalTarget: boostedPlan.verticalTarget,
            horizontalTarget: boostedPlan.horizontalTarget
        )

        // A disabled axis keeps its physical delta on the original event so that
        // apps still receive real (non-synthetic) horizontal scrolling while the
        // vertical axis is being smoothed.
        if plan.passThroughVertical || plan.passThroughHorizontal {
            if boostedPlan.verticalTarget != 0 { SmoothScrollWheelEventParser.clear(.vertical, in: event) }
            if boostedPlan.horizontalTarget != 0 { SmoothScrollWheelEventParser.clear(.horizontal, in: event) }
            return Unmanaged.passUnretained(event)
        }
        return accepted ? nil : Unmanaged.passUnretained(event)
    }

    private func reverseOriginalEvent(_ decision: SmoothScrollGateDecision, in event: CGEvent) {
        if decision.reverseOriginalVertical {
            _ = SmoothScrollWheelEventParser.reverse(.vertical, in: event)
        }
        if decision.reverseOriginalHorizontal {
            _ = SmoothScrollWheelEventParser.reverse(.horizontal, in: event)
        }
    }

    /// Rebuilds the exclusion caches only when the configured bundle
    /// identifiers actually changed, so slider drags do not re-enumerate
    /// `NSWorkspace.shared.runningApplications` on every tick.
    private func refreshExcludedApplicationCacheIfNeeded() -> Bool {
        let excludedIdentifiers = Set(
            activeSettings.excludedApplicationBundleIdentifiers.map {
                SmoothScrollApplicationExclusions.canonicalIdentifier($0)
            }
        )
        let reversedIdentifiers = Set(
            activeSettings.excludedApplicationReverseBundleIdentifiers.map {
                SmoothScrollApplicationExclusions.canonicalIdentifier($0)
            }
        )
        guard excludedIdentifiers != excludedBundleIdentifiers
                || reversedIdentifiers != reversedExcludedBundleIdentifiers else {
            return false
        }
        excludedBundleIdentifiers = excludedIdentifiers
        reversedExcludedBundleIdentifiers = reversedIdentifiers
        rebuildProcessCaches()
        return true
    }

    private func rebuildProcessCaches() {
        processBundleIdentifiers.removeAll(keepingCapacity: true)
        excludedProcessIDs.removeAll(keepingCapacity: true)
        reversedExcludedProcessIDs.removeAll(keepingCapacity: true)

        guard !excludedBundleIdentifiers.isEmpty else { return }
        for application in NSWorkspace.shared.runningApplications {
            updateProcessCache(for: application)
        }
    }

    private func clearExcludedApplicationCache() {
        excludedBundleIdentifiers.removeAll(keepingCapacity: false)
        reversedExcludedBundleIdentifiers.removeAll(keepingCapacity: false)
        processBundleIdentifiers.removeAll(keepingCapacity: false)
        excludedProcessIDs.removeAll(keepingCapacity: false)
        reversedExcludedProcessIDs.removeAll(keepingCapacity: false)
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceApplicationChange(application, notificationName: name)
                }
            }
        }
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll(keepingCapacity: false)
    }

    private func handleWorkspaceApplicationChange(
        _ application: NSRunningApplication,
        notificationName: NSNotification.Name
    ) {
        if notificationName == NSWorkspace.didTerminateApplicationNotification {
            let processID = application.processIdentifier
            processBundleIdentifiers.removeValue(forKey: processID)
            excludedProcessIDs.remove(processID)
            reversedExcludedProcessIDs.remove(processID)
            return
        }

        updateProcessCache(for: application)
        if notificationName == NSWorkspace.didActivateApplicationNotification,
           excludedProcessIDs.contains(application.processIdentifier) {
            runtime.stop()
            lastPhysicalWheelTime = 0
        }
    }

    private func updateProcessCache(for application: NSRunningApplication) {
        let processID = application.processIdentifier
        guard processID > 0 else { return }
        guard let bundleIdentifier = application.bundleIdentifier else {
            processBundleIdentifiers.removeValue(forKey: processID)
            excludedProcessIDs.remove(processID)
            reversedExcludedProcessIDs.remove(processID)
            return
        }
        processBundleIdentifiers[processID] = bundleIdentifier
        let isExcluded = SmoothScrollApplicationExclusions.contains(bundleIdentifier, in: excludedBundleIdentifiers)
        if isExcluded {
            excludedProcessIDs.insert(processID)
        } else {
            excludedProcessIDs.remove(processID)
        }
        if isExcluded,
           SmoothScrollApplicationExclusions.contains(bundleIdentifier, in: reversedExcludedBundleIdentifiers) {
            reversedExcludedProcessIDs.insert(processID)
        } else {
            reversedExcludedProcessIDs.remove(processID)
        }
    }

    private func shouldBypassSmoothing(for processID: pid_t) -> Bool {
        guard processID > 0, !excludedBundleIdentifiers.isEmpty else { return false }
        if excludedProcessIDs.contains(processID) { return true }
        if let bundleIdentifier = processBundleIdentifiers[processID] {
            return SmoothScrollApplicationExclusions.contains(bundleIdentifier, in: excludedBundleIdentifiers)
        }
        // Never query NSWorkspace/NSRunningApplication from the event tap. A
        // just-launched process is covered by the workspace observer shortly;
        // until then, let the normal smoothing path continue without blocking
        // the input callback.
        return false
    }

    private func shouldReverseExcludedApplication(for processID: pid_t) -> Bool {
        guard processID > 0, !reversedExcludedBundleIdentifiers.isEmpty else { return false }
        if reversedExcludedProcessIDs.contains(processID) { return true }
        if let bundleIdentifier = processBundleIdentifiers[processID] {
            return SmoothScrollApplicationExclusions.contains(
                bundleIdentifier,
                in: reversedExcludedBundleIdentifiers
            )
        }
        return false
    }
}
