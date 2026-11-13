import AppKit
import Testing
@testable import MacPilot

/// First-press behaviour: a cold cache must still put the switcher on screen
/// inside the same key press, a pending session must resolve within its bound,
/// and a session tap the system silently disabled must be repaired.
///
/// Every input here is injected: server records, application facts, and the tap
/// health host are all fakes. No test creates a real CGEvent tap, injects
/// keystrokes, opens a panel, or writes to the user's Diagnostics.log.
@MainActor
struct WindowSwitcherFirstPressTests {
    // MARK: - Window-server fallback inventory

    @Test func coldStartPresentsAWindowServerFallbackSessionWhenTheAccessibilityCacheIsEmpty() {
        let records = [
            record(windowID: 101, processID: 500, title: "Inbox", order: 0),
            record(windowID: 102, processID: 500, title: "Docs", order: 1),
            record(windowID: 201, processID: 600, title: "Notes", order: 2)
        ]
        let applications = [
            application(processID: 500, name: "Chrome", bundleIdentifier: "com.example.chrome"),
            application(processID: 600, name: "Notes", bundleIdentifier: "com.example.notes")
        ]

        let items = WindowSwitcherWindowServerInventory.snapshot(
            settings: WindowSwitcherSettings(),
            serverRecords: records,
            applications: applications
        )

        #expect(items.map(\.id) == ["window-101", "window-102", "window-201"])
        #expect(items.map(\.title) == ["Inbox", "Docs", "Notes"])
        #expect(items.map(\.processID) == [500, 500, 600])
        #expect(items.allSatisfy { $0.axWindow == nil }, "The fallback never queries Accessibility")
        #expect(items.allSatisfy { $0.preview == nil }, "The fallback never captures previews")
        #expect(items.allSatisfy { $0.canCapturePreview })
        // Identity continuity: the accessibility pass assigns the same
        // `window-<CGWindowID>` id to a matched server record, so the selection
        // survives the reconcile.
        #expect(items[0].windowID == 101)
        #expect(items[0].windowNumber == 101)

        #expect(WindowSwitcherSessionBootstrap.decision(
            cachedCount: 0,
            fallbackCount: items.count
        ) == .showWindowServerFallback(count: 3))
    }

    @Test func windowServerFallbackSkipsOffScreenExcludedAndHiddenWindows() {
        let records = [
            record(windowID: 301, processID: 700, title: "Visible", order: 0),
            record(windowID: 302, processID: 700, title: "OtherSpace", order: 1, isOnScreen: false),
            record(windowID: 303, processID: 701, title: "OwnerOverlay", order: 2),
            record(windowID: 304, processID: 702, title: "HiddenApp", order: 3),
            record(windowID: 305, processID: 700, title: "TooSmall", order: 4, frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        ]
        let applications = [
            application(processID: 700, name: "Visible"),
            application(processID: 701, name: "OverlayOwner"),
            application(processID: 702, name: "Hidden", isHidden: true)
        ]

        let items = WindowSwitcherWindowServerInventory.snapshot(
            settings: WindowSwitcherSettings(),
            serverRecords: records,
            applications: applications,
            excludedWindowIDs: [303]
        )

        #expect(items.map(\.id) == ["window-301"])

        var showingHidden = WindowSwitcherSettings()
        showingHidden.includeHiddenApplications = true
        let withHidden = WindowSwitcherWindowServerInventory.snapshot(
            settings: showingHidden,
            serverRecords: records,
            applications: applications,
            excludedWindowIDs: [303]
        )
        #expect(Set(withHidden.map(\.id)) == ["window-301", "window-304"])
    }

    @Test func windowServerFallbackHonoursTheConfiguredWindowGrouping() {
        var settings = WindowSwitcherSettings()
        settings.mergeApplicationBundleIdentifiers = ["com.example.chrome"]
        let records = [
            record(windowID: 401, processID: 800, title: "First", order: 0),
            record(windowID: 402, processID: 800, title: "Second", order: 1),
            record(windowID: 501, processID: 900, title: "Single", order: 2)
        ]
        let applications = [
            application(processID: 800, name: "Chrome", bundleIdentifier: "com.example.chrome"),
            application(processID: 900, name: "Terminal", bundleIdentifier: "com.example.terminal")
        ]

        let items = WindowSwitcherWindowServerInventory.snapshot(
            settings: settings,
            serverRecords: records,
            applications: applications
        )

        #expect(items.map(\.id) == ["window-401", "window-501"])
    }

    @Test func windowServerFallbackIgnoresApplicationsWithoutOnScreenWindows() {
        let records = [record(windowID: 601, processID: 1_000, title: "Only", order: 0)]
        let applications = [
            application(processID: 1_000, name: "Only"),
            application(processID: 1_001, name: "Background")
        ]

        let items = WindowSwitcherWindowServerInventory.snapshot(
            settings: WindowSwitcherSettings(),
            serverRecords: records,
            applications: applications
        )

        #expect(items.map(\.id) == ["window-601"])
    }

    // MARK: - Bounded pending session

    @Test func aPressedShortcutNeverWaitsForTheAXInventoryWithoutAFallback() {
        #expect(WindowSwitcherSessionBootstrap.decision(cachedCount: 0, fallbackCount: 1) == .showWindowServerFallback(count: 1))
        #expect(WindowSwitcherSessionBootstrap.decision(cachedCount: 3, fallbackCount: 3) == .showCachedInventory(count: 3))
        #expect(WindowSwitcherSessionBootstrap.decision(cachedCount: 0, fallbackCount: 0) == .waitForInventory)
    }

    @Test func pendingSessionFallsBackToTheWindowServerSnapshotAfterOneAndAHalfSeconds() {
        #expect(WindowSwitcherSessionBootstrap.pendingSessionFallbackMilliseconds == 1_500)
        #expect(WindowSwitcherSessionBootstrap.pendingSessionFallbackInterval == .milliseconds(1_500))
        #expect(WindowSwitcherSessionBootstrap.pendingResolution(
            inventoryCount: 0,
            windowServerCount: 12
        ) == .windowServerFallback(count: 12))
        #expect(WindowSwitcherSessionBootstrap.pendingResolution(
            inventoryCount: 4,
            windowServerCount: 12
        ) == .inventoryResolved(count: 4))
        #expect(WindowSwitcherSessionBootstrap.pendingResolution(
            inventoryCount: 0,
            windowServerCount: 0
        ) == .unresolved)
    }

    @Test func emptyAccessibilityCompletionKeepsPendingPressAndFallbackThenFallbackPresentsIt() throws {
        let lifecycle = WindowSwitcherPendingSessionLifecycle()
        lifecycle.begin(WindowSwitcherPendingSession(reverse: false, manual: false))
        let token = try #require(lifecycle.reserveFallbackToken())
        let fallbackTask = Task<Void, Never> { @MainActor in
            do { try await Task.sleep(for: .seconds(3_600)) } catch { }
        }
        lifecycle.armFallback(fallbackTask, token: token)

        let emptyAX: [WindowSwitcherItem] = []
        let fallback = WindowSwitcherWindowServerInventory.snapshot(
            settings: WindowSwitcherSettings(),
            serverRecords: [record(windowID: 901, processID: 1900, title: "Fallback", order: 0)],
            applications: [application(processID: 1900, name: "Fallback App")]
        )

        #expect(lifecycle.completeInventory(snapshot: emptyAX, cached: []) == nil)
        #expect(lifecycle.pending != nil, "The consumed shortcut remains pending after an empty AX result")
        #expect(lifecycle.isFallbackArmed, "The timeout that presents WindowServer fallback remains armed")
        #expect(!fallbackTask.isCancelled)

        guard case let .resolved(resolution)? = lifecycle.completeFallback(
            token: token,
            cached: [],
            windowServer: fallback
        ) else {
            Issue.record("The timeout should resolve the pending press using the WindowServer snapshot")
            return
        }
        #expect(resolution.pending.manual == false)
        #expect(resolution.snapshot.map(\.id) == ["window-901"])
        #expect(resolution.source == .windowServerFallback)
        #expect(lifecycle.pending == nil)
        #expect(!lifecycle.isFallbackArmed)
        #expect(fallbackTask.isCancelled)
        #expect(lifecycle.completeFallback(token: token, cached: [], windowServer: fallback) == nil)
    }

    @Test func unchangedInventoryCompletionCanResolveFromAUsableCache() throws {
        let lifecycle = WindowSwitcherPendingSessionLifecycle()
        lifecycle.begin(WindowSwitcherPendingSession(reverse: false, manual: true))
        let token = try #require(lifecycle.reserveFallbackToken())
        let fallbackTask = Task<Void, Never> { @MainActor in
            do { try await Task.sleep(for: .seconds(3_600)) } catch { }
        }
        lifecycle.armFallback(fallbackTask, token: token)
        let cached = WindowSwitcherWindowServerInventory.snapshot(
            settings: WindowSwitcherSettings(),
            serverRecords: [record(windowID: 902, processID: 1901, title: "Cached", order: 0)],
            applications: [application(processID: 1901, name: "Cached App")]
        )

        guard let resolution = lifecycle.completeInventory(snapshot: nil, cached: cached) else {
            Issue.record("A nil refresh with a usable cache should complete the pending press")
            return
        }
        #expect(resolution.snapshot.map(\.id) == ["window-902"])
        #expect(resolution.source == .accessibilityInventory)
        #expect(lifecycle.pending == nil)
        #expect(!lifecycle.isFallbackArmed)
        #expect(fallbackTask.isCancelled)
    }

    @Test func cancelledOrSupersededPendingSessionRejectsLateCallbacks() throws {
        let lifecycle = WindowSwitcherPendingSessionLifecycle()
        lifecycle.begin(WindowSwitcherPendingSession(reverse: false, manual: false))
        let oldToken = try #require(lifecycle.reserveFallbackToken())
        let oldTask = Task<Void, Never> { @MainActor in
            do { try await Task.sleep(for: .seconds(3_600)) } catch { }
        }
        lifecycle.armFallback(oldTask, token: oldToken)

        lifecycle.cancel()
        #expect(oldTask.isCancelled)
        #expect(lifecycle.completeInventory(snapshot: [], cached: []) == nil)
        #expect(lifecycle.completeFallback(token: oldToken, cached: [], windowServer: []) == nil)
        #expect(lifecycle.pending == nil)

        lifecycle.begin(WindowSwitcherPendingSession(reverse: true, manual: false))
        let currentToken = try #require(lifecycle.reserveFallbackToken())
        let currentTask = Task<Void, Never> { @MainActor in
            do { try await Task.sleep(for: .seconds(3_600)) } catch { }
        }
        lifecycle.armFallback(currentTask, token: currentToken)
        #expect(lifecycle.completeFallback(token: oldToken, cached: [], windowServer: []) == nil)
        #expect(lifecycle.pending?.reverse == true)
        #expect(lifecycle.isFallbackArmed)
        lifecycle.cancel()
        #expect(currentTask.isCancelled)
    }

    // MARK: - Event tap health

    @Test func aDeadTapIsReenabledInPlaceWithoutInstallingASecondTap() {
        let host = FakeTapHealthHost()
        host.tapEnabled = false
        let recorder = LogRecorder()
        let watchdog = WindowSwitcherTapHealthWatchdog(
            host: host,
            log: { recorder.lines.append($0) }
        )

        let outcome = watchdog.check(reason: "activation")

        #expect(outcome == .reenabled)
        #expect(host.reenableCount == 1)
        #expect(host.rebuildCount == 0)
        #expect(host.tapHealthInstallCount == 1, "Re-enabling must not duplicate the tap")
        #expect(host.tapEnabled)
        #expect(recorder.lines.contains { $0.contains("re-enabled in place") })
    }

    @Test func aMissingTapIsRebuiltExactlyOnce() {
        let host = FakeTapHealthHost()
        host.hasTap = false
        let recorder = LogRecorder()
        let watchdog = WindowSwitcherTapHealthWatchdog(
            host: host,
            log: { recorder.lines.append($0) }
        )

        let outcome = watchdog.check(reason: "wake")

        #expect(outcome == .rebuilt)
        #expect(host.tapHealthInstallCount == 2, "One install at start plus one rebuild")
        #expect(recorder.lines.contains { $0.contains("no tap installed; rebuild ok") })
    }

    @Test func aTapThatRefusesToReenableIsRebuiltAndLogged() {
        let host = FakeTapHealthHost()
        host.tapEnabled = false
        host.reenableSucceeds = false
        let recorder = LogRecorder()
        let watchdog = WindowSwitcherTapHealthWatchdog(
            host: host,
            log: { recorder.lines.append($0) }
        )

        let outcome = watchdog.check(reason: "periodic")

        #expect(outcome == .rebuilt)
        #expect(host.rebuildCount == 1)
        #expect(recorder.lines.contains { $0.contains("re-enable failed; rebuilt tap") })
    }

    @Test func aHealthyTapIsLeftAloneAndLogsNothing() {
        let host = FakeTapHealthHost()
        let recorder = LogRecorder()
        let watchdog = WindowSwitcherTapHealthWatchdog(
            host: host,
            log: { recorder.lines.append($0) }
        )

        #expect(watchdog.check(reason: "activation") == .healthy)
        #expect(host.reenableCount == 0)
        #expect(host.rebuildCount == 0)
        #expect(recorder.lines.isEmpty)
    }

    @Test func aStoppedOrDisabledFeatureIsNeverRepaired() {
        let host = FakeTapHealthHost()
        host.armed = false
        let watchdog = WindowSwitcherTapHealthWatchdog(
            host: host,
            log: { _ in Issue.record("An unarmed watchdog must not log") }
        )

        #expect(watchdog.check(reason: "periodic") == .notArmed)
        #expect(host.reenableCount == 0)
        #expect(host.rebuildCount == 0)
    }

    @Test func thePeriodicPassRepairsADeadTapAndStopsWithTheFeature() async throws {
        let host = FakeTapHealthHost()
        host.tapEnabled = false
        let watchdog = WindowSwitcherTapHealthWatchdog(host: host, interval: .milliseconds(40))

        watchdog.arm()
        watchdog.arm() // arming twice keeps exactly one periodic pass
        #expect(watchdog.isArmed)

        try await waitUntil { host.tapHealthIsTapEnabled() }
        #expect(host.tapHealthInstallCount == 1, "The periodic pass re-enabled the tap instead of reinstalling it")
        #expect(watchdog.checkCount >= 1)

        watchdog.stop()
        let checksAfterStop = watchdog.checkCount
        #expect(!watchdog.isArmed)
        try await Task.sleep(for: .milliseconds(200))
        #expect(watchdog.checkCount == checksAfterStop, "Stopping the feature must release the periodic timer")
    }

    @Test func disabledTapEventsAreRepairedBeforeAnyKeyRouting() {
        #expect(WindowSwitcherEventTapRouting.route(type: .tapDisabledByTimeout, keyCode: 0) == .tapDisabled)
        #expect(WindowSwitcherEventTapRouting.route(type: .tapDisabledByUserInput, keyCode: 0) == .tapDisabled)
        // Routing a disable event outranks the payload: a disable event is
        // repaired even though its key code is not one the switcher consumes.
        #expect(WindowSwitcherEventTapRouting.route(type: .tapDisabledByTimeout, keyCode: 48) == .tapDisabled)
        #expect(WindowSwitcherEventTapRouting.isTapDisabled(type: .tapDisabledByTimeout))
        #expect(WindowSwitcherEventTapRouting.isTapDisabled(type: .tapDisabledByUserInput))
        #expect(!WindowSwitcherEventTapRouting.isTapDisabled(type: .keyDown))
    }

    @Test func nonSwitcherKeysShortCircuitBeforeAnyModelWork() {
        // `.ignore` is returned without reaching the model, so ordinary typing
        // never triggers an inventory refresh or panel construction.
        #expect(WindowSwitcherEventTapRouting.route(type: .keyDown, keyCode: 0) == .ignore)
        #expect(WindowSwitcherEventTapRouting.route(type: .keyDown, keyCode: 12) == .ignore)
        #expect(WindowSwitcherEventTapRouting.route(type: .keyDown, keyCode: 44) == .ignore)
        #expect(WindowSwitcherEventTapRouting.route(type: .keyUp, keyCode: 44) == .ignore)
        #expect(WindowSwitcherEventTapRouting.route(type: .mouseMoved, keyCode: 48) == .ignore)
        #expect(!WindowSwitcherEventTapRouting.shouldInspect(type: .keyDown, keyCode: 44))
        #expect(WindowSwitcherEventTapRouting.route(type: .keyDown, keyCode: 48) == .inspect)
        #expect(WindowSwitcherEventTapRouting.route(type: .keyUp, keyCode: 53) == .inspect)
        #expect(WindowSwitcherEventTapRouting.route(type: .flagsChanged, keyCode: 0) == .inspect)
    }

    @Test func aRealHostWithAnInitiallyMissingGrantStillChecksForRecovery() {
        var checks = 0
        let model = WindowSwitcherModel(isTrusted: { checks += 1; return false })
        model.activateFromConfiguration()
        defer { model.shutdown() }
        #expect(!model.hasAccessibilityPermission)
        #expect(model.tapHealthIsArmed)
        let initialChecks = checks
        let watchdog = WindowSwitcherTapHealthWatchdog(host: model, log: { _ in })
        #expect(watchdog.check(reason: "periodic") == .repairFailed)
        #expect(checks > initialChecks)
        #expect(model.activeEventTapCount == 0)
        model.shutdown()
        let stoppedChecks = checks
        #expect(watchdog.check(reason: "periodic") == .notArmed)
        #expect(checks == stoppedChecks)
    }

    // MARK: - Fixtures

    private func record(
        windowID: CGWindowID,
        processID: pid_t,
        title: String,
        order: Int,
        isOnScreen: Bool = true,
        frame: CGRect = CGRect(x: 20, y: 40, width: 800, height: 500)
    ) -> WindowSwitcherServerRecord {
        WindowSwitcherServerRecord(
            windowID: windowID,
            processID: processID,
            title: title,
            frame: frame,
            order: order,
            isOnScreen: isOnScreen
        )
    }

    private func application(
        processID: pid_t,
        name: String,
        bundleIdentifier: String? = nil,
        isHidden: Bool = false
    ) -> WindowSwitcherFallbackApplication {
        WindowSwitcherFallbackApplication(
            processID: processID,
            name: name,
            bundleIdentifier: bundleIdentifier,
            isHidden: isHidden,
            icon: NSImage(size: NSSize(width: 1, height: 1))
        )
    }

    private func waitUntil(timeout: Int = 100, _ condition: () -> Bool) async throws {
        for _ in 0..<timeout {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "The watchdog did not repair the tap within the bounded wait")
    }
}

@MainActor
private final class LogRecorder {
    var lines: [String] = []
}

@MainActor
private final class FakeTapHealthHost: WindowSwitcherTapHealthHost {
    var armed = true
    var hasTap = true
    var tapEnabled = true
    var reenableSucceeds = true
    var reenableCount = 0
    var rebuildCount = 0
    var tapHealthInstallCount = 1

    var tapHealthIsArmed: Bool { armed }
    var tapHealthHasEventTap: Bool { hasTap }

    func tapHealthIsTapEnabled() -> Bool { hasTap && tapEnabled }

    func tapHealthReenableTap() -> Bool {
        reenableCount += 1
        guard hasTap else { return false }
        if reenableSucceeds { tapEnabled = true }
        return reenableSucceeds && tapEnabled
    }

    func tapHealthRebuildTap() -> Bool {
        rebuildCount += 1
        tapHealthInstallCount += 1
        hasTap = true
        tapEnabled = true
        return true
    }
}
