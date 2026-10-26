import Foundation
import CoreLocation
import Testing
@testable import MacPilot

@MainActor
private final class QuitWiFiAuthorizationProbe {
    var status: CLAuthorizationStatus

    init(status: CLAuthorizationStatus) {
        self.status = status
    }
}

struct QuitWiFiTests {
    @Test func namesAreExactAndMayContainCommasOrSpaces() {
        #expect(QuitWiFiPolicy.parse("Office\r\nHome, 5G\nOffice\n\n Guest ") == ["Office", "Home, 5G", " Guest "])
        #expect(QuitWiFiPolicy.matches(names: ["Office", "Home, 5G"], connectedNames: ["Home, 5G"]))
        #expect(!QuitWiFiPolicy.matches(names: ["Office"], connectedNames: ["office"]))
        #expect(!QuitWiFiPolicy.matches(names: ["Office"], connectedNames: ["Office Guest"]))
        #expect(!QuitWiFiPolicy.matches(names: ["Office"], connectedNames: []))
        #expect(!QuitWiFiPolicy.matches(names: nil, connectedNames: ["Office"]))
        #expect(!QuitWiFiPolicy.matches(names: [""], connectedNames: [""]))
    }

    @Test func legacyRulesDecodeWithoutWiFiAndKeepTheirActions() throws {
        let rule = QuitRule(appName: "Example", bundleIdentifier: "example.test", inactiveQuitMinutes: 10)
        let encoded = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(QuitRule.self, from: encoded)
        #expect(decoded.quitWiFiNames == nil)
        #expect(decoded.inactiveQuitMinutes == 10)
        #expect(decoded.hasAction)
    }

    @Test func wiFiOnlyRuleRoundTripsAndRetainsLegacyKeys() throws {
        let rule = QuitRule(appName: "Example", bundleIdentifier: "example.test", quitWiFiNames: ["Office", "Home"])
        let encoded = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(QuitRule.self, from: encoded)
        #expect(decoded == rule)
        #expect(decoded.hasAction)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys).isSuperset(of: ["id", "appName", "bundleIdentifier", "isEnabled", "quitWiFiNames"]))
    }

    @Test func bothLanguagesDescribeWiFiQuitting() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            for key in ["quitWiFi", "quitWiFiHint", "quitWiFiPermission", "quitWiFiAuthorize", "quitWiFiSettings"] {
                #expect(AppText.value(key, language: language) != key)
            }
        }
    }

    @MainActor
    @Test func pausedMonitorDoesNotReadWiFiNames() async {
        var readCount = 0
        let monitor = QuitWiFiMonitor(
            authorizationStatusProvider: { .authorizedAlways },
            connectedNamesReader: {
                readCount += 1
                return ["Office"]
            }
        )

        monitor.configure(enabled: false, onChange: {})
        await Task.yield()

        #expect(readCount == 0)
        #expect(monitor.connectedNames.isEmpty)
    }

    @MainActor
    @Test func stopDiscardsAnOutstandingWiFiRead() async throws {
        var readStarted = false
        var readReturned = false
        var pendingRead: CheckedContinuation<Set<String>, Never>?
        var changeCount = 0
        let monitor = QuitWiFiMonitor(
            authorizationStatusProvider: { .authorizedAlways },
            connectedNamesReader: {
                let names = await withCheckedContinuation { continuation in
                    pendingRead = continuation
                    readStarted = true
                }
                readReturned = true
                return names
            }
        )

        monitor.configure(enabled: true) { changeCount += 1 }
        for _ in 0..<100 where !readStarted { await Task.yield() }
        try #require(readStarted)

        monitor.stop()
        pendingRead?.resume(returning: ["Office"])
        pendingRead = nil
        for _ in 0..<100 where !readReturned { await Task.yield() }
        try #require(readReturned)
        for _ in 0..<10 { await Task.yield() }

        #expect(monitor.connectedNames.isEmpty)
        #expect(changeCount == 0)
    }

    @MainActor
    @Test func revokedAuthorizationDiscardsAnOutstandingWiFiRead() async throws {
        let authorization = QuitWiFiAuthorizationProbe(status: .authorizedAlways)
        var readStarted = false
        var readReturned = false
        var pendingRead: CheckedContinuation<Set<String>, Never>?
        var changeCount = 0
        let monitor = QuitWiFiMonitor(
            authorizationStatusProvider: { authorization.status },
            connectedNamesReader: {
                let names = await withCheckedContinuation { continuation in
                    pendingRead = continuation
                    readStarted = true
                }
                readReturned = true
                return names
            }
        )

        monitor.configure(enabled: true) { changeCount += 1 }
        for _ in 0..<100 where !readStarted { await Task.yield() }
        try #require(readStarted)

        authorization.status = .denied
        pendingRead?.resume(returning: ["Office"])
        pendingRead = nil
        for _ in 0..<100 where !readReturned { await Task.yield() }
        try #require(readReturned)
        for _ in 0..<10 { await Task.yield() }

        #expect(monitor.connectedNames.isEmpty)
        #expect(changeCount == 0)
        monitor.stop()
    }
}
