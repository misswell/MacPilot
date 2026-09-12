import ApplicationServices
import Foundation
import MacPilotRemoteProtocol

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
    /// live CoreGraphics query because this flag can go stale.
    @Published private(set) var displaySleeping = false
    @Published private(set) var systemSleeping = false

    /// Maintained from the distributed screen saver notifications.
    var screensaverActive = false

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

    var isDisplaySleeping: Bool { ScreenLockStateReader.displayIsAsleep() }

    var isSystemSleeping: Bool { systemSleeping }

    func currentState() -> MacRemoteState {
        let lockState = ScreenLockStateReader.current()
        let credentialsPresent = credentials.hasCredential
        let trusted = accessibilityGranted
        return MacRemoteState(
            screenLocked: RemoteBooleanState(lockState == .unknown ? nil : lockState == .locked),
            canUnlock: RemoteBooleanState(trusted && credentialsPresent),
            hasCredential: RemoteBooleanState(credentialsPresent),
            accessibilityGranted: RemoteBooleanState(trusted),
            displaySleeping: RemoteBooleanState(ScreenLockStateReader.displayIsAsleep())
        )
    }

    func noteDisplaySleeping(_ value: Bool) {
        if displaySleeping != value { displaySleeping = value }
    }

    func noteSystemSleeping(_ value: Bool) {
        if systemSleeping != value { systemSleeping = value }
    }

    // MARK: - Lock

    /// Attributes an imminent lock to `source` without posting any event. Used
    /// by the BLE path, which triggers the lock through the screen saver.
    func markPendingLock(source: ScreenControlSource) {
        willLock?(source)
    }

    /// Posts the lock shortcut synchronously. The BLE path uses this because its
    /// own presence policy already decided when to lock.
    func performLockShortcut(source: ScreenControlSource) {
        willLock?(source)
        executor.lockScreenShortcut()
    }

    /// Locks the screen and confirms the session actually became locked before
    /// reporting success.
    func lockScreen(source: ScreenControlSource) async -> ScreenControlResult {
        let initial = currentState()
        guard initial.screenLocked != .yes else {
            log("lock skipped reason=alreadyLocked source=\(source.rawValue)")
            return .failure(.alreadyLocked, state: initial)
        }

        log("lock requested source=\(source.rawValue)")
        willLock?(source)
        executor.lockScreenShortcut()

        let locked = await waitUntil(timeout: 3) { ScreenLockStateReader.current() == .locked }
        let state = currentState()
        guard locked else {
            log("lock failed reason=stateDidNotChange source=\(source.rawValue)")
            return .failure(.lockFailed, state: state)
        }
        log("lock confirmed source=\(source.rawValue)")
        return .success(state)
    }

    // MARK: - Display power

    func sleepDisplay() async -> ScreenControlResult {
        if ScreenLockStateReader.displayIsAsleep() {
            return .success(currentState())
        }
        log("display sleep requested")
        DisplayPower.sleepDisplay()
        let asleep = await waitUntil(timeout: 2) { ScreenLockStateReader.displayIsAsleep() }
        if asleep { noteDisplaySleeping(true) }
        let state = currentState()
        guard asleep else {
            log("display sleep failed reason=displayStillAwake")
            return .failure(.displaySleepFailed, state: state)
        }
        return .success(state)
    }

    func wakeDisplay() async -> ScreenControlResult {
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

        if ScreenLockStateReader.displayIsAsleep() {
            log("unlock requested with display asleep; waking first")
            DisplayPower.wakeDisplay()
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
        if ScreenLockStateReader.current() == .unlocked, !ScreenLockStateReader.displayIsAsleep() {
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

        if ScreenLockStateReader.displayIsAsleep() {
            log("wakeAndUnlock waking display")
            DisplayPower.wakeDisplay()
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

            if ScreenLockStateReader.displayIsAsleep() {
                // A key press can wake the display before the notification
                // arrives; make sure it is really on before typing.
                DisplayPower.wakeDisplay()
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
