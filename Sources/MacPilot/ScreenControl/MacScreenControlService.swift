import ApplicationServices
import Foundation
import MacPilotRemoteProtocol

/// Which mechanism "turn off screen" uses, as a pure rule.
///
/// The two session states need opposite tools. An unlocked desktop must not
/// sleep the display, because the system's "require password after the display
/// turns off" policy would lock it. The lock screen must not use MacPilot's
/// black cover, because MacPilot's windows cannot draw above the login window
/// and the session's brightness seam is no longer frontmost there — while a
/// real display sleep, the way the lock screen itself goes dark, cannot lock
/// anything that is not already locked.
enum DisplayOffApproach: Equatable {
    /// Black the displays without sleeping them.
    case blankCover
    /// Ask the system to put the display to sleep (`pmset displaysleepnow`).
    case systemSleep

    static func forScreen(locked: Bool) -> DisplayOffApproach {
        locked ? .systemSleep : .blankCover
    }
}

/// The single owner of "make the Mac lock, sleep its display, wake it or type
/// the login password" behaviour.
///
/// Both control surfaces route here:
///
/// ```
/// BLEUnlockModel ─┐
///                 ├─▶ MacScreenControlService ─▶ ScreenUnlockExecutor ─▶ CGEvent
/// RemoteControlServer ─┘                       └▶ ScreenCredentialStore ─▶ Keychain
/// ```
///
/// It deliberately knows nothing about BLE RSSI, device discovery, proximity
/// timeouts or automatic-lock policy; those stay in `BLEUnlockModel`.
@MainActor
final class MacScreenControlService: ObservableObject {
    /// Checkpoints, in seconds from the start of an explicit remote unlock.
    /// Tighter than the BLE schedule because a user is waiting on the phone.
    nonisolated static let remoteUnlockCheckpoints: [TimeInterval] = [0.35, 0.8, 1.5, 2.5, 4]

    let credentials: ScreenCredentialStore
    let executor: ScreenUnlockExecutor

    /// Called immediately before a lock is triggered so the lock history owner
    /// can attribute the distributed lock notification to the right source.
    var willLock: (@MainActor (ScreenControlSource) -> Void)?
    /// Called after the service confirmed an unlock it caused.
    var didUnlock: (@MainActor (ScreenControlSource, Date) -> Void)?

    /// Notification derived display sleep flag. `isDisplaySleeping` prefers the
    /// live CoreGraphics and blank-state queries because this flag can go stale.
    @Published private(set) var displaySleeping = false
    @Published private(set) var systemSleeping = false

    /// Maintained from the distributed screen saver notifications.
    var screensaverActive = false

    /// Distributed screen-saver observers that keep `screensaverActive` fresh.
    ///
    /// They live here rather than in `BLEUnlockModel` because the remote unlock
    /// path also reads `screensaverActive`: keying them off the BLE switch alone
    /// would silently break remote unlock whenever BLE is switched off. The app
    /// model installs them only while BLE or the iPhone remote is enabled, so
    /// neither feature pays for them while both are off.
    private let screensaverObservers = ObserverBag()

    private let logHandler: (String) -> Void

    init(
        credentials: ScreenCredentialStore = ScreenCredentialStore(),
        log: @escaping (String) -> Void = { DiagnosticLog.write("ScreenControl", $0) }
    ) {
        self.credentials = credentials
        self.executor = ScreenUnlockExecutor(log: log)
        self.logHandler = log
    }

    private func log(_ message: @autoclosure () -> String) {
        logHandler(message())
    }

    // MARK: - State

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    var hasCredential: Bool { credentials.hasCredential }

    /// A screen MacPilot holds black counts as "off" for the remote UI even
    /// though the display itself never slept.
    var isDisplaySleeping: Bool { DisplayPower.isBlanked || ScreenLockStateReader.displayIsAsleep() }

    var isSystemSleeping: Bool { systemSleeping }

    func currentState() -> MacRemoteState {
        let lockState = ScreenLockStateReader.current()
        let credentialsPresent = credentials.hasCredential
        let trusted = accessibilityGranted
        let levels = MacOutputLevel.snapshot()
        return MacRemoteState(
            screenLocked: RemoteBooleanState(lockState == .unknown ? nil : lockState == .locked),
            canUnlock: RemoteBooleanState(trusted && credentialsPresent),
            hasCredential: RemoteBooleanState(credentialsPresent),
            accessibilityGranted: RemoteBooleanState(trusted),
            displaySleeping: RemoteBooleanState(isDisplaySleeping),
            brightness: levels.brightness,
            volume: levels.volume,
            volumeMuted: RemoteBooleanState(levels.muted)
        )
    }

    func noteDisplaySleeping(_ value: Bool) {
        if displaySleeping != value { displaySleeping = value }
    }

    func noteSystemSleeping(_ value: Bool) {
        if systemSleeping != value { systemSleeping = value }
    }

    /// Installs or removes the distributed screen-saver observers. Idempotent.
    func setScreensaverObservationEnabled(_ enabled: Bool) {
        if enabled {
            guard screensaverObservers.isEmpty else { return }
            let center = DistributedNotificationCenter.default()
            screensaverObservers.add(center.addObserver(
                forName: Notification.Name("com.apple.screensaver.didstart"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.screensaverActive else { return }
                    self.screensaverActive = true
                    self.log("screensaver started")
                }
            }, center: center)
            screensaverObservers.add(center.addObserver(
                forName: Notification.Name("com.apple.screensaver.didstop"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.screensaverActive else { return }
                    self.screensaverActive = false
                    self.log("screensaver stopped")
                }
            }, center: center)
            log("screensaver observation started")
        } else {
            guard !screensaverObservers.isEmpty else { return }
            screensaverObservers.removeAll()
            screensaverActive = false
            log("screensaver observation stopped")
        }
    }

    func shutdown() {
        setScreensaverObservationEnabled(false)
    }

    // MARK: - Lock

    /// A lock must be visible. Releasing a black screen first keeps the login
    /// window from appearing behind a display MacPilot is holding at zero
    /// brightness, and hands the display back to the system's own sleep policy.
    private func prepareForLock() {
        if DisplayPower.isBlanked { DisplayPower.unblankDisplay() }
    }

    /// Attributes an imminent lock to `source` without posting any event. Used
    /// by the BLE path, which triggers the lock through the screen saver.
    func markPendingLock(source: ScreenControlSource) {
        prepareForLock()
        willLock?(source)
    }

    /// Posts the lock shortcut synchronously. The BLE path uses this because its
    /// own presence policy already decided when to lock.
    func performLockShortcut(source: ScreenControlSource) {
        prepareForLock()
        willLock?(source)
        executor.lockScreenShortcut()
    }

    /// Delays **between** postings of the lock shortcut, in seconds. The first
    /// entry posts immediately; every later entry is the wait since the
    /// previous post before the shortcut is sent again.
    ///
    /// The schedule exists because loginwindow intermittently ignores a
    /// synthetic Control-Command-Q posted shortly after a display wake. Real
    /// device logs (2026-09-25): after 黑屏→亮屏, identical keystrokes failed
    /// to lock for 15-26 s and then worked on the first later attempt — the
    /// same keystroke confirmed in 117-400 ms outside that window. One post
    /// plus a 3 s confirmation turned "lock" into "the user must manually wait
    /// and tap again". The gaps are front-loaded so a settled session still
    /// confirms on the first keystroke, and the tail reaches past the measured
    /// swallow window so the recovery is automatic.
    nonisolated static let lockShortcutDelays: [TimeInterval] = [0, 0.8, 0.8, 1.0, 1.4, 2, 3, 4, 5, 6]
    /// Last chance for the final post to land before reporting failure.
    nonisolated static let lockConfirmationWindow: TimeInterval = 2.5
    /// How long a `willLock` attribution stays valid. Must cover the whole
    /// retry schedule: a lock that lands after the late reposts would else be
    /// misclassified as a manual lock in the history.
    nonisolated static let lockAttributionWindow: TimeInterval = 30

    /// Locks the screen and confirms the session actually became locked before
    /// reporting success.
    ///
    /// The shortcut is (re-)posted on `lockShortcutDelays` for as long as the
    /// session reports unlocked. The wait between posts doubles as the
    /// confirmation poll, so a settled session — where the very first
    /// keystroke locks in a few hundred milliseconds — returns after a single
    /// post exactly as before.
    func lockScreen(source: ScreenControlSource) async -> ScreenControlResult {
        let initial = currentState()
        guard initial.screenLocked != .yes else {
            log("lock skipped reason=alreadyLocked source=\(source.rawValue)")
            return .failure(.alreadyLocked, state: initial)
        }

        log("lock requested source=\(source.rawValue)")
        prepareForLock()
        willLock?(source)

        executor.lockScreenShortcut()
        var attempts = 1
        for gap in Self.lockShortcutDelays.dropFirst() {
            // The wait doubles as the confirmation poll: the moment the
            // session reports locked, no further keystroke is posted.
            let locked = await waitUntil(timeout: gap) {
                ScreenLockStateReader.current() == .locked
            }
            if locked {
                log("lock confirmed attempts=\(attempts) source=\(source.rawValue)")
                return .success(currentState())
            }
            attempts += 1
            log("lock reposted attempts=\(attempts) reason=sessionStillUnlocked source=\(source.rawValue)")
            executor.lockScreenShortcut()
        }
        let locked = await waitUntil(timeout: Self.lockConfirmationWindow) {
            ScreenLockStateReader.current() == .locked
        }
        guard locked else {
            log("lock failed reason=stateDidNotChange attempts=\(attempts) source=\(source.rawValue)")
            return .failure(.lockFailed, state: currentState())
        }
        log("lock confirmed attempts=\(attempts) source=\(source.rawValue)")
        return .success(currentState())
    }

    // MARK: - Display power

    /// Blacks the display without locking the session.
    ///
    /// On an unlocked desktop a real display sleep is deliberately not a
    /// fallback: on a Mac that requires a password as soon as the display turns
    /// off (the default) it locks the session, which is what MacPilot's
    /// separate lock action is for. When no display can be blacked the action
    /// fails visibly instead of silently turning "turn off screen" into "lock".
    ///
    /// The lock screen is the exception picked by
    /// `DisplayOffApproach.forScreen(locked:)`: the black cover cannot reach a
    /// screen the login window owns, so there the action becomes the system's
    /// own darkening of a locked Mac — a plain display sleep — and confirms the
    /// display actually went down before reporting success.
    func sleepDisplay() async -> ScreenControlResult {
        if isDisplaySleeping {
            return .success(currentState())
        }
        switch DisplayOffApproach.forScreen(locked: ScreenLockStateReader.current() == .locked) {
        case .systemSleep:
            log("display off requested while locked; sleeping display instead of blanking")
            DisplayPower.sleepDisplay()
            let slept = await waitUntil(timeout: 4) { ScreenLockStateReader.displayIsAsleep() }
            guard slept else {
                log("display sleep failed reason=stillAwakeWhileLocked")
                return .failure(.displaySleepFailed, state: currentState())
            }
            noteDisplaySleeping(true)
            log("display slept while locked")
            return .success(currentState())
        case .blankCover:
            guard DisplayPower.turnOffScreen() else {
                log("display off failed reason=noDisplayCouldBeBlacked")
                return .failure(.displaySleepFailed, state: currentState())
            }
            log("display blacked without sleeping")
            noteDisplaySleeping(true)
            return .success(currentState())
        }
    }

    func wakeDisplay() async -> ScreenControlResult {
        if DisplayPower.isBlanked {
            log("display unblank requested")
            DisplayPower.unblankDisplay()
            noteDisplaySleeping(false)
            return .success(currentState())
        }
        if !ScreenLockStateReader.displayIsAsleep() {
            noteDisplaySleeping(false)
            return .success(currentState())
        }
        log("display wake requested")
        DisplayPower.wakeDisplay()
        let awake = await waitUntil(timeout: 3) { !ScreenLockStateReader.displayIsAsleep() }
        if awake { noteDisplaySleeping(false) }
        let state = currentState()
        guard awake else {
            log("display wake failed reason=displayStillAsleep")
            return .failure(.wakeFailed, state: state)
        }
        return .success(state)
    }

    // MARK: - Output levels

    /// Drives the panel backlight, and reports failure when no display on this
    /// Mac has a drivable one instead of pretending the level changed.
    ///
    /// A brightness change is a request to *see* the screen, so a held blank is
    /// released on the way in: otherwise the new level would be invisible and
    /// the phone would look broken.
    func setBrightness(_ value: Double) -> ScreenControlResult {
        guard DisplayPower.brightness() != nil else {
            log("brightness unavailable reason=noDrivableBacklight")
            return .failure(.brightnessUnavailable, state: currentState())
        }
        let wasBlanked = DisplayPower.isBlanked
        guard DisplayPower.setBrightness(value) else {
            log("brightness failed reason=displayRejectedValue")
            return .failure(.brightnessUnavailable, state: currentState())
        }
        if wasBlanked {
            log("display unblanked reason=brightnessChanged")
            noteDisplaySleeping(false)
        }
        log("brightness set value=\(String(format: "%.2f", value))")
        return .success(currentState())
    }

    /// Drives the default output device's volume. `muted` is optional so moving
    /// the slider never changes the mute state by itself.
    func setVolume(_ value: Double, muted: Bool?) -> ScreenControlResult {
        guard MacOutputLevel.setVolume(value, muted: muted) else {
            log("volume unavailable reason=noSettableOutputDevice")
            return .failure(.volumeUnavailable, state: currentState())
        }
        let muteText = muted.map { $0 ? "true" : "false" } ?? "unchanged"
        log("volume set value=\(String(format: "%.2f", value)) muted=\(muteText)")
        return .success(currentState())
    }

    // MARK: - Unlock

    /// Unlocks an already visible lock screen.
    func unlock(source: ScreenControlSource) async -> ScreenControlResult {
        if ScreenLockStateReader.current() == .unlocked {
            return .failure(.alreadyUnlocked, state: currentState())
        }
        guard accessibilityGranted else {
            log("unlock rejected reason=accessibilityPermissionRequired")
            return .failure(.accessibilityPermissionRequired, state: currentState())
        }
        guard let password = credentials.loadPassword(warn: true) else {
            log("unlock rejected reason=credentialNotConfigured")
            return .failure(.credentialNotConfigured, state: currentState())
        }

        if isDisplaySleeping {
            log("unlock requested with display off; waking first")
            DisplayPower.wakeDisplay()
            DisplayPower.unblankDisplay()
            noteDisplaySleeping(false)
        }

        let unlocked = await runUnlockAttempts(password: password, source: source)
        let state = currentState()
        guard unlocked else {
            log("unlock failed source=\(source.rawValue)")
            return .failure(.unlockFailed, state: state)
        }
        didUnlock?(source, Date())
        log("unlock confirmed source=\(source.rawValue)")
        return .success(state)
    }

    /// Wakes a sleeping display and then unlocks. The display wake gets its own
    /// settling time because the login window password field is not ready the
    /// instant the display comes back.
    func wakeAndUnlock(source: ScreenControlSource) async -> ScreenControlResult {
        if ScreenLockStateReader.current() == .unlocked, !isDisplaySleeping {
            return .success(currentState())
        }
        guard accessibilityGranted else {
            log("wakeAndUnlock rejected reason=accessibilityPermissionRequired")
            return .failure(.accessibilityPermissionRequired, state: currentState())
        }
        guard let password = credentials.loadPassword(warn: true) else {
            log("wakeAndUnlock rejected reason=credentialNotConfigured")
            return .failure(.credentialNotConfigured, state: currentState())
        }

        if isDisplaySleeping {
            log("wakeAndUnlock waking display")
            DisplayPower.wakeDisplay()
            DisplayPower.unblankDisplay()
            noteDisplaySleeping(false)
        }

        if ScreenLockStateReader.current() == .unlocked {
            didUnlock?(source, Date())
            return .success(currentState())
        }

        let unlocked = await runUnlockAttempts(password: password, source: source)
        let state = currentState()
        guard unlocked else {
            log("wakeAndUnlock failed source=\(source.rawValue)")
            return .failure(.unlockFailed, state: state)
        }
        didUnlock?(source, Date())
        log("wakeAndUnlock confirmed source=\(source.rawValue)")
        return .success(state)
    }

    // MARK: - Internals

    /// Shared retry loop for the explicit remote unlock paths. It stops the
    /// moment the session reports unlocked instead of always sleeping for a
    /// fixed duration.
    private func runUnlockAttempts(
        password: String,
        source: ScreenControlSource
    ) async -> Bool {
        var previous: TimeInterval = 0
        let checkpoints: [TimeInterval] = [0] + Self.remoteUnlockCheckpoints
        for (index, checkpoint) in checkpoints.enumerated() {
            if index > 0 {
                let wait = checkpoint - previous
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
            previous = checkpoint
            if Task.isCancelled { return false }

            if ScreenLockStateReader.current() == .unlocked {
                log("unlock attempt stopped reason=alreadyUnlocked checkpoint=\(checkpoint)")
                return true
            }

            if isDisplaySleeping {
                // A key press can wake the display before the notification
                // arrives; make sure it is really on before typing.
                DisplayPower.wakeDisplay()
                DisplayPower.unblankDisplay()
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return false }
                if ScreenLockStateReader.current() == .unlocked { return true }
            }

            if screensaverActive {
                executor.dismissScreensaver()
            }

            log("posting unlock key events checkpoint=\(checkpoint) source=\(source.rawValue) accessibilityTrusted=\(AXIsProcessTrusted())")
            await executor.postPassword(password)

            if ScreenLockStateReader.current() == .unlocked {
                return true
            }
        }
        return ScreenLockStateReader.current() == .unlocked
    }

    private func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .seconds(interval))
        }
        return condition()
    }
}
