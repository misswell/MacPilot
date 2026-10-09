import Foundation
import Testing
@testable import MacPilotRemoteProtocol

struct RemoteNavigationKeyTests {
    @Test func keysEncodeAsSingleWhitelistedBytes() throws {
        let cases: [(RemoteNavigationKey, UInt8)] = [
            (.pageUp, 1),
            (.pageDown, 2),
            (.home, 3),
            (.end, 4)
        ]

        for (key, byte) in cases {
            let payload = key.encoded()
            #expect(payload == Data([byte]))
            #expect(RemoteNavigationKey.decoded(from: payload) == key)
            #expect(try JSONDecoder().decode(RemoteNavigationKey.self, from: JSONEncoder().encode(key)) == key)
        }
    }

    @Test func malformedAndUnknownPayloadsAreRejected() {
        #expect(RemoteNavigationKey.decoded(from: nil) == nil)
        #expect(RemoteNavigationKey.decoded(from: Data()) == nil)
        #expect(RemoteNavigationKey.decoded(from: Data([1, 2])) == nil)
        #expect(RemoteNavigationKey.decoded(from: Data([0])) == nil)
        #expect(RemoteNavigationKey.decoded(from: Data([5])) == nil)
        #expect(RemoteNavigationKey.decoded(from: Data(repeating: 1, count: 64)) == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteNavigationKey.self, from: Data("255".utf8))
        }
    }
}
