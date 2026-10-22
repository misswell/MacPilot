import Foundation
import Testing
@testable import MacPilotRemoteTransport

struct ProximityGATTSessionTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func onlyOneProbeCanBeInFlightAndAMatchIsConsumedOnce() throws {
        var probe = ProximityGATTProbe()
        let result1 = probe.begin(at: now)
        let payload = try #require(result1)
        #expect(payload.count == 16)
        let result2 = probe.begin(at: now)
        #expect(result2 == nil)
        #expect(probe.sentBytes == 16)
        let result3 = probe.receive(payload, at: now.addingTimeInterval(0.1))
        #expect(result3 == 100)
        let result4 = probe.receive(payload, at: now.addingTimeInterval(0.2))
        #expect(result4 == nil)
        #expect(probe.verifiedCount == 1)
        #expect(probe.payload == nil)
        #expect(probe.receivedBytes == 32)
    }

    @Test func oldNotificationCannotCompleteANewerRequest() throws {
        var probe = ProximityGATTProbe()
        let result5 = probe.begin(at: now)
        let old = try #require(result5)
        probe.cancel()
        let result6 = probe.begin(at: now.addingTimeInterval(1))
        let current = try #require(result6)
        #expect(old != current)
        let result7 = probe.receive(old, at: now.addingTimeInterval(2))
        #expect(result7 == nil)
        #expect(probe.payload == current)
        let result8 = probe.receive(current, at: now.addingTimeInterval(2))
        #expect(result8 == 1_000)
        #expect(probe.verifiedCount == 1)
    }

    @Test func expiredAndMalformedResponsesNeverVerify() throws {
        var probe = ProximityGATTProbe()
        let result9 = probe.begin(at: now)
        let payload = try #require(result9)
        let result10 = probe.receive(Data(payload.prefix(15)), at: now.addingTimeInterval(1))
        #expect(result10 == nil)
        #expect(probe.payload == payload)
        let result11 = probe.receive(payload, at: now.addingTimeInterval(15))
        #expect(result11 == nil)
        #expect(probe.payload == nil)
        #expect(probe.verifiedCount == 0)
        let result12 = probe.begin(at: now.addingTimeInterval(16))
        #expect(result12 != nil)
    }

    @Test func queuedResponsesRemainBoundToTheirSubscriberAndAreNotOverwritten() {
        var queue = ProximityGATTEchoQueue(capacity: 2)
        let first = UUID(), second = UUID(), third = UUID()
        let a = Data(repeating: 1, count: 16), b = Data(repeating: 2, count: 16)
        let result13 = queue.enqueue(a, for: first, at: now)
        #expect(result13)
        let result14 = queue.enqueue(b, for: first, at: now)
        #expect(!result14)
        let result15 = queue.enqueue(b, for: second, at: now)
        #expect(result15)
        let result16 = queue.enqueue(a, for: third, at: now)
        #expect(!result16)
        // A full updateValue buffer leaves this exact entry for the ready callback.
        #expect(queue.entries.first?.centralID == first)
        #expect(queue.entries.first?.payload == a)
        queue.removeFirst()
        #expect(queue.entries.first?.centralID == second)
        #expect(queue.entries.first?.payload == b)
        queue.remove(centralID: second)
        #expect(queue.entries.isEmpty)
    }

    @Test func queueRejectsBadLengthsExpiresAndClearsBetweenSessions() {
        var queue = ProximityGATTEchoQueue()
        let id = UUID(), data = Data(repeating: 3, count: 16)
        let result17 = queue.enqueue(Data(), for: id, at: now)
        #expect(!result17)
        let result18 = queue.enqueue(data, for: id, at: now)
        #expect(result18)
        queue.discardExpired(at: now.addingTimeInterval(14.9))
        #expect(queue.entries.count == 1)
        queue.discardExpired(at: now.addingTimeInterval(15))
        #expect(queue.entries.isEmpty)
        let result19 = queue.enqueue(data, for: id, at: now.addingTimeInterval(16))
        #expect(result19)
        queue.reset()
        #expect(queue.entries.isEmpty)
        let result20 = queue.enqueue(data, for: id, at: now.addingTimeInterval(17))
        #expect(result20)
    }

    @Test func retryBackoffIsCappedEvenAfterManyFailuresAndResetsAfterSuccess() {
        var retry = ProximityGATTRetry()
        let initialDelays = (0..<8).map { _ in retry.nextDelay() }
        #expect(initialDelays == [1, 2, 4, 8, 16, 30, 30, 30])
        for _ in 0..<1_000 {
            let delay = retry.nextDelay()
            #expect(delay == 30)
        }
        retry.reset()
        let result21 = retry.nextDelay()
        #expect(result21 == 1)
    }
}
