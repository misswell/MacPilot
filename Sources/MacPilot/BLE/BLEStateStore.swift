import CoreBluetooth
import Foundation

/// Presence observed on the reversed GATT link, keyed by the configured
/// logical device (`primaryUUID`), never by the phone's rotating BLE address.
///
/// The reverse link authenticates the phone and carries its own RSSI samples,
/// so it needs its own timers and evidence. It deliberately has no moving
/// average shared with the legacy scanner: mixing the two directions would let
/// one link's stale average authorise an unlock on the other.
enum BLEPresenceSignalSource: String, Equatable {
    case none
    case legacy
    case reverse
}

@MainActor
final class BLEReversePresenceRuntime {
    let primaryUUID: UUID
    /// Binding this evidence belongs to. A later bind/reconcile with a
    /// different client or fingerprint invalidates the runtime.
    let clientID: String
    let keyFingerprint: String
    var presence = false
    var lastRSSI: Int?
    var lastRSSISampledAt: TimeInterval?
    var lastAcceptedAt: Date?
    var sampleCount = 0
    var lastError: String?
    var proximityTimer: BackgroundTask?
    var proximityTimerGeneration: UInt64 = 0
    var signalTimer: BackgroundTask?
    var signalTimerGeneration: UInt64 = 0
    var signalTimerScheduledDeadline: TimeInterval?
    var signalTimeoutDeadline: TimeInterval?
    var signalObservationIsContinuous = false
    var verifyingSignalLoss = false

    init(primaryUUID: UUID, clientID: String, keyFingerprint: String) {
        self.primaryUUID = primaryUUID
        self.clientID = clientID
        self.keyFingerprint = keyFingerprint
    }

    func cancelProximityTimer() {
        proximityTimer?.stop()
        proximityTimer = nil
        proximityTimerGeneration &+= 1
    }

    func invalidateTimers() {
        cancelProximityTimer()
        signalTimer?.stop()
        signalTimer = nil
        signalTimerGeneration &+= 1
        signalTimerScheduledDeadline = nil
        signalTimeoutDeadline = nil
        signalObservationIsContinuous = false
        verifyingSignalLoss = false
    }

    func clearEvidence() {
        presence = false
        lastRSSI = nil
        lastRSSISampledAt = nil
        lastAcceptedAt = nil
    }
}

@MainActor
final class BLEMonitoredDeviceRuntime {
    let uuid: UUID
    var peripheral: CBPeripheral?
    var presence = false
    var lastRSSI: Int?
    var lastRSSISampledAt: TimeInterval?
    var activeMode = false
    var latestRSSIs: [Double] = []
    var rssiReadGate = BLERequestGate()
    var connectionRetryGate = BLEConnectionRetryGate()
    var proximityTimer: BackgroundTask?
    var proximityTimerGeneration: UInt64 = 0
    var signalTimer: BackgroundTask?
    var signalTimerGeneration: UInt64 = 0
    var signalTimerScheduledDeadline: TimeInterval?
    var signalTimeoutDeadline: TimeInterval?
    var signalObservationIsContinuous = false
    var verifyingSignalLoss = false
    var activeModeTimer: BackgroundTask?
    var connectionTimer: BackgroundTask?
    var rssiRequestTimeoutTimer: BackgroundTask?

    init(uuid: UUID) {
        self.uuid = uuid
    }

    func cancelProximityTimer() {
        proximityTimer?.stop()
        proximityTimer = nil
        proximityTimerGeneration &+= 1
    }

    func invalidateTimers() {
        cancelProximityTimer()
        signalTimer?.stop()
        signalTimer = nil
        signalTimerGeneration &+= 1
        signalTimerScheduledDeadline = nil
        signalTimeoutDeadline = nil
        signalObservationIsContinuous = false
        verifyingSignalLoss = false
        activeModeTimer?.stop()
        activeModeTimer = nil
        connectionTimer?.stop()
        connectionTimer = nil
        rssiRequestTimeoutTimer?.stop()
        rssiRequestTimeoutTimer = nil
        rssiReadGate.reset()
        connectionRetryGate.reset()
        activeMode = false
    }
}

