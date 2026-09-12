import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

/// Physical clamshell state.
enum LidState: Equatable, Sendable {
    case open
    case closed
    case unknown
}

/// Event-driven clamshell monitoring. There is no polling: the state comes
/// from the `IOPMrootDomain` registry property and an IOKit interest
/// notification.
@MainActor
protocol LidStateMonitoring: AnyObject {
    var currentState: LidState { get }

    func start(onChange: @escaping @MainActor (LidState) -> Void)
    func stop()
}

@MainActor
final class LidStateMonitor: LidStateMonitoring {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.LidState")
    private(set) var currentState: LidState = .unknown

    private var rootDomain: io_service_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@MainActor (LidState) -> Void)?

    func start(onChange: @escaping @MainActor (LidState) -> Void) {
        stop()
        handler = onChange
        openRootDomain()
        refresh(notify: true)
    }

    func stop() {
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            self.runLoopSource = nil
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        if rootDomain != 0 {
            IOObjectRelease(rootDomain)
            rootDomain = 0
        }
        handler = nil
        // Force the next `start` to report the (possibly changed) state.
        currentState = .unknown
    }

    /// Re-reads the registry property and reports a change to the observer.
    func refresh(notify: Bool) {
        let newState = Self.readLidState(rootDomain: rootDomain)
        let changed = newState != currentState
        currentState = newState
        if notify, changed || currentState == .unknown {
            handler?(currentState)
        }
    }

    private func openRootDomain() {
        guard let matching = IOServiceMatching("IOPMrootDomain") else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            logger.error("IOPMrootDomain not available")
            return
        }
        rootDomain = service

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("Could not create an IOKit notification port")
            return
        }
        notifyPort = port
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            logger.error("Could not obtain the notification run loop source")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            Self.interestCallback,
            context,
            &notification
        )
        guard result == kIOReturnSuccess else {
            logger.error("IOServiceAddInterestNotification failed: \(result, privacy: .public)")
            return
        }
    }

    nonisolated private static func readLidState(rootDomain: io_service_t) -> LidState {
        guard rootDomain != 0 else { return .unknown }
        guard let value = IORegistryEntryCreateCFProperty(
            rootDomain,
            kAppleClamshellStateKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            // Desktop Macs have no clamshell switch at all.
            return .unknown
        }
        guard let number = value as? NSNumber else { return .unknown }
        return number.boolValue ? .closed : .open
    }

    /// Bridges the C callback back onto the main actor.
    private static let interestCallback: IOServiceInterestCallback = { context, _, _, _ in
        guard let context else { return }
        let owner = Unmanaged<LidStateMonitor>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in
            owner.refresh(notify: true)
        }
    }
}
