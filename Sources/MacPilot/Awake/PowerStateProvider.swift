import Foundation
import IOKit.ps
import OSLog

protocol AwakePowerStateProviding: AnyObject {
    func currentPowerState() -> PowerState
    func startMonitoring(_ handler: @escaping @MainActor () -> Void)
    func stopMonitoring()
    @discardableResult
    func addMonitoringObserver(_ handler: @escaping @MainActor () -> Void) -> UUID
    func removeMonitoringObserver(_ id: UUID)
}

extension AwakePowerStateProviding {
    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {}
    func stopMonitoring() {}

    @discardableResult
    func addMonitoringObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        startMonitoring(handler)
        return UUID()
    }

    func removeMonitoringObserver(_ id: UUID) {
        stopMonitoring()
    }
}

private final class PowerSourceNotificationContext: @unchecked Sendable {
    weak var owner: PowerStateProvider?

    init(owner: PowerStateProvider) {
        self.owner = owner
    }
}

/// Reads the shared IOKit power-source snapshot. The session manager owns one
/// instance and refreshes it only while Awake has active work or after wake.
final class PowerStateProvider: AwakePowerStateProviding, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.Power")
    private let lock = NSLock()
    private var runLoopSource: CFRunLoopSource?
    private var notificationContext: PowerSourceNotificationContext?
    private var observers: [UUID: @MainActor () -> Void] = [:]

    private static let notificationCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
        guard let context else { return }
        let notificationContext = Unmanaged<PowerSourceNotificationContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        notificationContext.owner?.notifyObservers()
    }

    func currentPowerState() -> PowerState {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sourceType = String(describing: IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue())
        let onExternalPower = sourceType == kIOPMACPowerKey || sourceType == kIOPMUPSPowerKey

        let list = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as NSArray
        var batteryLevel: Double?
        var charging = false

        for source in list {
            let source = source as CFTypeRef
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? NSDictionary else {
                continue
            }

            if let isCharging = description[kIOPSIsChargingKey] as? NSNumber {
                charging = charging || isCharging.boolValue
            }

            guard let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                  maximum > 0 else {
                continue
            }
            let level = min(max(current / maximum * 100, 0), 100)
            if batteryLevel == nil || level < batteryLevel! {
                batteryLevel = level
            }
        }

        let state = PowerState(
            batteryLevel: batteryLevel,
            charging: charging,
            onExternalPower: onExternalPower
        )
        logger.debug("Power state: battery=\(state.batteryLevel ?? -1, privacy: .public), charging=\(state.charging, privacy: .public), external=\(state.onExternalPower, privacy: .public)")
        return state
    }

    @discardableResult
    func addMonitoringObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        var shouldAddSource = false
        if runLoopSource == nil {
            let context = PowerSourceNotificationContext(owner: self)
            guard let source = IOPSNotificationCreateRunLoopSource(
                Self.notificationCallback,
                Unmanaged.passUnretained(context).toOpaque()
            )?.takeRetainedValue() else {
                observers[id] = nil
                lock.unlock()
                logger.error("Could not create the IOKit power-source notification run-loop source")
                return id
            }
            notificationContext = context
            runLoopSource = source
            shouldAddSource = true
        }
        let source = runLoopSource
        lock.unlock()
        if shouldAddSource, let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        return id
    }

    func removeMonitoringObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        guard observers.isEmpty, let source = runLoopSource else {
            lock.unlock()
            return
        }
        runLoopSource = nil
        notificationContext = nil
        lock.unlock()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        _ = addMonitoringObserver(handler)
    }

    func stopMonitoring() {
        lock.lock()
        let source = runLoopSource
        observers.removeAll()
        runLoopSource = nil
        notificationContext = nil
        lock.unlock()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func notifyObservers() {
        lock.lock()
        let handlers = Array(observers.values)
        lock.unlock()
        for handler in handlers {
            Task { @MainActor in handler() }
        }
    }
}
