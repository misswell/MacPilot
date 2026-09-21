import Testing
@testable import MacPilotLocalPortsCore

struct LocalPortURLResolverTests {
    @Test func choosesLoopbackAndWildcardProbeHosts() {
        #expect(LocalPortURLResolver.probeHost(for: ["127.0.0.1", "[::1]"]) == "127.0.0.1")
        #expect(LocalPortURLResolver.probeHost(for: ["::"]) == "[::1]")
        #expect(LocalPortURLResolver.probeHost(for: ["0.0.0.0"]) == "127.0.0.1")
        #expect(LocalPortURLResolver.probeHost(for: ["192.168.1.20"]) == "192.168.1.20")
    }

    @Test func buildsHttpUrlsWithIpv6Brackets() {
        #expect(LocalPortURLResolver.url(port: 3000, addresses: ["127.0.0.1"])?.absoluteString == "http://127.0.0.1:3000/")
        #expect(LocalPortURLResolver.url(port: 3000, addresses: ["::1"])?.absoluteString == "http://[::1]:3000/")
        #expect(LocalPortURLResolver.url(port: 0, addresses: ["127.0.0.1"]) == nil)
    }
}
