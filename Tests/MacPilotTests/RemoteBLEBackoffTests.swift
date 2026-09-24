import Foundation
import Testing
@testable import MacPilot

struct RemoteBLEBackoffTests {
    @Test func aHealthyAttemptWaitsExactlyTheBaseTimeout() {
        #expect(RemoteBLECentral.backoffTimeout(base: 12, stallCount: 0) == 12)
    }

    @Test func consecutiveStallsDoubleTheTimeoutUpToTheCap() {
        #expect(RemoteBLECentral.backoffTimeout(base: 12, stallCount: 1) == 24)
        #expect(RemoteBLECentral.backoffTimeout(base: 12, stallCount: 2) == 48)
        #expect(RemoteBLECentral.backoffTimeout(base: 12, stallCount: 3) == 96)
        #expect(RemoteBLECentral.backoffTimeout(base: 12, stallCount: 5) == 300)
    }

    @Test func theCapKeepsLongOutagesRetryingQuietly() {
        // A wedged radio used to restart discovery every 12 seconds forever;
        // after the cap the loop settles into one attempt per five minutes.
        for stalls in 6...40 {
            #expect(RemoteBLECentral.backoffTimeout(base: 12, stallCount: stalls) == 300)
        }
    }

    @Test func backoffIsMonotonicInStallCount() {
        var previous = RemoteBLECentral.backoffTimeout(base: 12, stallCount: 0)
        for stalls in 1...10 {
            let current = RemoteBLECentral.backoffTimeout(base: 12, stallCount: stalls)
            #expect(current >= previous)
            previous = current
        }
    }
}
