import Foundation
import IOKit.ps
import OSLog

protocol AwakePowerStateProviding: AnyObject {
    func currentPowerState() -> PowerState
    func startMonitoring(_ handler: @escaping @MainActor () -> Void)
    func stopMonitoring()
}

extension AwakePowerStateProviding {
    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {}
    func stopMonitoring() {}
}

private final class PowerSourceNotificationContext: @unchecked Sendable {
    let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }
}

/// Reads the shared IOKit power-source snapshot. The session manager owns one
/// instance and refreshes it only while Awake has active work or after wake.
final class PowerStateProvider: AwakePowerStateProviding, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.Power")
    private let lock = NSLock()
    private var runLoopSource: CFRunLoopSource?
    private var notificationContext: PowerSourceNotificationContext?

    private static let notificationCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
        guard let context else { return }
        let notificationContext = Unmanaged<PowerSourceNotificationContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        let handler = notificationContext.handler
        Task { @MainActor in handler() }
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

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        lock.lock()
        guard runLoopSource == nil else {
            lock.unlock()
            return
        }
        let context = PowerSourceNotificationContext(handler: handler)
        guard let source = IOPSNotificationCreateRunLoopSource(
            Self.notificationCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )?.takeRetainedValue() else {
            lock.unlock()
            logger.error("Could not create the IOKit power-source notification run-loop source")
            return
        }
        notificationContext = context
        runLoopSource = source
        lock.unlock()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func stopMonitoring() {
        lock.lock()
        guard let source = runLoopSource else {
            lock.unlock()
            return
        }
        runLoopSource = nil
        notificationContext = nil
        lock.unlock()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}
