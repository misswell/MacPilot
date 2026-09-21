import Foundation
import Testing
@testable import MacPilotLocalPortsCore

struct LocalPortScannerTests {
    @Test func listenerParserMergesIPv4AndIPv6AndDeduplicatesEntries() {
        let output = """
        p42
        cnode
        u501
        Lsong
        n127.0.0.1:3000
        n[::1]:3000
        n127.0.0.1:3000
        p43
        cpython
        u501
        n*:8080
        n192.168.1.10:8081
        n*:bad
        """

        let listeners = LocalPortScanner.parseListeners(output)
        #expect(listeners.count == 3)
        #expect(listeners[0].addresses == ["127.0.0.1", "[::1]"])
        #expect(listeners[0].uid == 501)
        #expect(listeners[0].user == "song")
        #expect(listeners[1].port == 8080)
        #expect(LocalPortScanner.listenerScope(["127.0.0.1", "[::1]"]) == .local)
        #expect(LocalPortScanner.listenerScope(["127.0.0.1", "*"]) == .lan)
    }

    @Test func listenerParserRejectsEmptyAndInvalidPortRecords() {
        let output = """
        p42
        cnode
        n127.0.0.1:0
        n127.0.0.1:65536
        n127.0.0.1:not-a-port
        n127.0.0.1:3000
        """

        #expect(LocalPortScanner.parseListeners("").isEmpty)
        #expect(LocalPortScanner.parseListeners(output).map(\.port) == [3000])
        #expect(LocalPortScanner.listenerScope(["192.168.1.20"]) == .lan)
    }

    @Test func processTableParsesElapsedTimeAndLegacyRows() {
        let output = """
            1     0 01-16:20:00 /sbin/launchd
          500   200 02:15:30 /opt/local/bin/node
          600   500 00:30 python
        """
        let table = LocalPortScanner.parseProcessTable(output)
        #expect(table[1]?.uptime == "1d 16h")
        #expect(table[1]?.compactUptime == "1d")
        #expect(table[500]?.uptime == "2h 15m")
        #expect(table[600]?.uptime == "< 1m")

        let legacy = LocalPortScanner.parseProcessTable("1 0 /sbin/launchd")
        #expect(legacy[1]?.command == "launchd")
        #expect(legacy[1]?.uptime == nil)

        let legacyWithHyphen = LocalPortScanner.parseProcessTable("7 1 my-server")
        #expect(legacyWithHyphen[7]?.command == "my-server")
    }

    @Test func projectLocatorReadsPackageAndPythonNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPortProject-\(UUID().uuidString)")
        let child = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"name\": \"demo-service\"}".utf8)
            .write(to: root.appendingPathComponent("package.json"))

        let project = try #require(LocalPortProjectLocator.locate(cwd: child.path, homeDirectory: "/Users/test"))
        #expect(project.root == root.path)
        #expect(project.name == "demo-service")
        #expect(project.marker == "package.json")
    }

    @Test func projectLocatorRejectsDependencyAndAppPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPortProject-\(UUID().uuidString)")
        let dependencies = root.appendingPathComponent("node_modules/pkg")
        let app = root.appendingPathComponent("Demo.app/Contents")
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"name\": \"should-not-win\"}".utf8)
            .write(to: root.appendingPathComponent("package.json"))

        #expect(LocalPortProjectLocator.locate(cwd: dependencies.path, homeDirectory: "/Users/test") == nil)
        #expect(LocalPortProjectLocator.locate(cwd: app.path, homeDirectory: "/Users/test") == nil)
    }

    @Test func projectLocatorReadsPythonCargoAndGoMarkers() throws {
        let fixtures: [(String, String, String)] = [
            ("pyproject.toml", "[project]\nname = 'python-demo'\n", "python-demo"),
            ("Cargo.toml", "[package]\nname = 'cargo-demo'\n", "directory"),
            ("go.mod", "module example.com/demo\n", "directory"),
        ]

        for (marker, contents, expectedName) in fixtures {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalPortProject-\(UUID().uuidString)")
            let child = root.appendingPathComponent("Sources")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try Data(contents.utf8).write(to: root.appendingPathComponent(marker))

            let project = try #require(
                LocalPortProjectLocator.locate(cwd: child.path, homeDirectory: "/Users/test")
            )
            #expect(project.marker == marker)
            #expect(project.name == (expectedName == "directory" ? root.lastPathComponent : expectedName))
        }
    }
}
