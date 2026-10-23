import Foundation

/// Serialises the CoreBluetooth operations that back one reverse-presence
/// sample, so a late callback can never be charged to the challenge that
/// replaced it.
///
/// `CBPeripheral.readRSSI()` and `writeValue(_:for:type:)` cannot be cancelled
/// and carry no operation identifier: the delegate answers with the peripheral
/// and the characteristic only. When a read times out the call is still
/// outstanding, so a callback arriving afterwards would otherwise be consumed
/// by the next read — and `sendSample` would then sign the *new* nonce with an
/// RSSI that was measured *before* that nonce existed. The HMAC would still
/// verify, which is exactly why this cannot be left to the model.
///
/// Each operation is therefore queued with the nonce it was issued for.
/// CoreBluetooth answers calls in the order they were made, so the queue is
/// FIFO and `settle()` always describes the callback that just arrived.
public struct ReversePresenceOperationTracker: Sendable, Equatable {
    public struct Operation: Sendable, Equatable {
        /// The challenge this operation was started for. A measurement only
        /// describes the moment after its own challenge was delivered.
        public let nonce: Data
        /// Set when the operation timed out or the app left the foreground.
        /// The callback may still arrive and must be dropped.
        public var isInvalidated: Bool

        public init(nonce: Data, isInvalidated: Bool = false) {
            self.nonce = nonce
            self.isInvalidated = isInvalidated
        }
    }

    /// CoreBluetooth answers every call exactly once. A queue that grows past
    /// this means a callback was lost, so the link can no longer be trusted to
    /// pair callbacks with operations and has to be rebuilt.
    public static let maximumOutstanding = 4

    public private(set) var outstanding: [Operation] = []

    public init() {}

    /// True while an operation may still deliver a usable result. Invalidated
    /// operations do not count: a timed-out read must not stall the stream,
    /// otherwise one slow callback stops every later sample.
    public var isBusy: Bool {
        outstanding.contains { !$0.isInvalidated }
    }

    /// False once callbacks stopped arriving; the caller must rebuild the link.
    public var isSynchronised: Bool {
        outstanding.count < Self.maximumOutstanding
    }

    public mutating func begin(nonce: Data) {
        outstanding.append(Operation(nonce: nonce))
    }

    /// The oldest operation timed out. It stays queued: its callback can still
    /// arrive, and recognising it as stale is the whole point.
    public mutating func expireEarliest() {
        guard !outstanding.isEmpty else { return }
        outstanding[0].isInvalidated = true
    }

    /// The app left the foreground. Nothing started before that point may
    /// produce a sample, but the callbacks are still owed and still arrive.
    public mutating func invalidateAll() {
        for index in outstanding.indices {
            outstanding[index].isInvalidated = true
        }
    }

    /// Consumes the callback that just arrived. Returns `nil` when the
    /// peripheral answered something this tracker never started.
    public mutating func settle() -> Operation? {
        guard !outstanding.isEmpty else { return nil }
        return outstanding.removeFirst()
    }

    public mutating func reset() {
        outstanding.removeAll()
    }
}

/// Why a reverse-presence connection was given up, and how the central
/// recovers from it.
///
/// The production link has to survive the app being asleep in a pocket. A
/// rejection that simply forgets the device is unrecoverable in that state:
/// duplicate-filtered scanning reports each Mac once, so nothing will offer it
/// again until something explicitly asks for a fresh scan. Every rejection
/// therefore carries a recovery plan, and the plan is a pure function so it can
/// be tested without a radio.
public enum ReversePresenceRejection: String, Sendable, CaseIterable {
    /// `didFailToConnect` — the radio could not open the link.
    case connectFailed
    /// The service, characteristics or subscription never completed in time.
    case setupTimeout
    case serviceMissing
    case characteristicsMissing
    case characteristicPropertiesUnsupported
    case macInfoReadFailed
    case macInfoInvalid
    /// The Mac identified itself but this phone holds no key for it.
    case unknownOrDeletedMac
    case presenceCharacteristicLost
    case subscribeFailed
    case subscribeRefused
    /// The Mac rebuilt its GATT table.
    case serviceInvalidated
    /// CoreBluetooth stopped answering in order, so callbacks can no longer be
    /// paired with the operations that produced them.
    case callbacksLost
    case unknownPeripheralState
    /// The user removed the pairing; retrying could never succeed.
    case macForgotten
}

public struct ReversePresenceRecoveryPlan: Sendable, Equatable {
    /// How long the Mac stays out of consideration before the next attempt.
    public let cooldown: TimeInterval
    /// Whether the central retries without any user action.
    public let retriesAutomatically: Bool
    /// Duplicate-filtered scanning reports a Mac once per scan, so the central
    /// has to start a fresh scan to be offered it again.
    public let refreshesScan: Bool

    public init(cooldown: TimeInterval, retriesAutomatically: Bool, refreshesScan: Bool) {
        self.cooldown = cooldown
        self.retriesAutomatically = retriesAutomatically
        self.refreshesScan = refreshesScan
    }

    /// - Parameter hasPairingKey: whether this phone holds any pairing key at
    ///   all. That is the feature's own precondition, so it is also the honest
    ///   answer to "is the Mac that failed here one of ours". A connection that
    ///   has not read the Mac identity yet still gets retried: the failure was
    ///   in reaching it, not in recognising it.
    public static func plan(
        for reason: ReversePresenceRejection,
        hasPairingKey: Bool
    ) -> ReversePresenceRecoveryPlan {
        switch reason {
        case .macForgotten, .unknownOrDeletedMac:
            // Retrying cannot succeed: the key is gone. `handlePairedMac`
            // restarts discovery the moment the user pairs again.
            return ReversePresenceRecoveryPlan(
                cooldown: cooldown(for: reason),
                retriesAutomatically: false,
                refreshesScan: false
            )
        default:
            guard hasPairingKey else {
                return ReversePresenceRecoveryPlan(
                    cooldown: cooldown(for: reason),
                    retriesAutomatically: false,
                    refreshesScan: false
                )
            }
            return ReversePresenceRecoveryPlan(
                cooldown: cooldown(for: reason),
                retriesAutomatically: true,
                refreshesScan: true
            )
        }
    }

    /// A Mac that answered with unexpected GATT contents is not ours or is
    /// rebuilding; those wait longer than a link that merely dropped.
    public static func cooldown(for reason: ReversePresenceRejection) -> TimeInterval {
        switch reason {
        case .connectFailed, .serviceInvalidated, .callbacksLost: return 5
        case .macInfoReadFailed: return 10
        case .setupTimeout, .unknownPeripheralState: return 15
        case .macInfoInvalid, .unknownOrDeletedMac, .subscribeFailed, .subscribeRefused,
             .serviceMissing:
            return 30
        case .characteristicsMissing, .characteristicPropertiesUnsupported,
             .presenceCharacteristicLost:
            return 60
        case .macForgotten: return 0
        }
    }
}
