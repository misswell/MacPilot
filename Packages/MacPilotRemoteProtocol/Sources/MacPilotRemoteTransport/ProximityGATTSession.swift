import Foundation

/// Local bookkeeping only; none of these values change the GATT wire contract.
public struct ProximityGATTProbe: Sendable {
    public private(set) var payload: Data?
    public private(set) var sentAt: Date?
    public private(set) var lastSentAt: Date?
    public private(set) var lastReceivedAt: Date?
    public private(set) var sentBytes = 0
    public private(set) var receivedBytes = 0
    public private(set) var verifiedCount = 0
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) { self.timeout = timeout }

    /// A second probe cannot replace the live request. Each request gets a nonce.
    public mutating func begin(at now: Date = .now) -> Data? {
        guard payload == nil else { return nil }
        let value = ProximityGATTEcho.random()
        payload = value
        sentAt = now
        lastSentAt = now
        sentBytes += value.count
        return value
    }

    /// Consumes a match exactly once. Late, duplicate and foreign notifications
    /// never prove the current request succeeded.
    public mutating func receive(_ value: Data, at now: Date = .now) -> Int? {
        receivedBytes += value.count
        lastReceivedAt = now
        guard let payload, let sentAt else { return nil }
        guard now.timeIntervalSince(sentAt) < timeout else {
            cancel()
            return nil
        }
        guard ProximityGATTEcho.isValid(value, matching: payload) else { return nil }
        let milliseconds = max(0, Int(now.timeIntervalSince(sentAt) * 1000))
        cancel()
        verifiedCount += 1
        return milliseconds
    }

    public mutating func cancel() {
        payload = nil
        sentAt = nil
    }
}

/// Bounded, per-subscriber notification backpressure. Never broadcast one
/// phone's response to another, overwrite a queued response, or keep it forever.
public struct ProximityGATTEchoQueue: Sendable {
    public struct Entry: Sendable {
        public let centralID: UUID
        public let payload: Data
        public let expiresAt: Date
    }
    public private(set) var entries: [Entry] = []
    public let capacity: Int
    public init(capacity: Int = 8) { self.capacity = capacity }

    public mutating func enqueue(_ payload: Data, for centralID: UUID, at now: Date = .now) -> Bool {
        discardExpired(at: now)
        guard payload.count == ProximityGATTEcho.length,
              entries.count < capacity,
              !entries.contains(where: { $0.centralID == centralID }) else { return false }
        entries.append(Entry(centralID: centralID, payload: payload, expiresAt: now.addingTimeInterval(15)))
        return true
    }

    public mutating func discardExpired(at now: Date = .now) {
        entries.removeAll { $0.expiresAt <= now }
    }

    public mutating func remove(centralID: UUID) {
        entries.removeAll { $0.centralID == centralID }
    }

    public mutating func removeFirst() { if !entries.isEmpty { entries.removeFirst() } }
    public mutating func reset() { entries.removeAll() }
}

public struct ProximityGATTRetry: Sendable {
    private var index = 0
    public init() {}
    public mutating func nextDelay() -> Int {
        let delays = [1, 2, 4, 8, 16, 30]
        let delay = delays[index]
        index = min(index + 1, delays.count - 1)
        return delay
    }
    public mutating func reset() { index = 0 }
}
