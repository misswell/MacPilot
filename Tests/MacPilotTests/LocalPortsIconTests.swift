import Foundation
import MacPilotLocalPortsCore
import Testing
@testable import MacPilot

@MainActor
struct LocalPortsIconTests {
    @Test func faviconParserResolvesRelativeLinksAndIgnoresTemplates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPortIcon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let index = root.appendingPathComponent("index.html")
        try Data(#"<link rel="icon" href="assets/favicon.png">"#.utf8).write(to: index)
        #expect(
            LocalPortIconResolver.indexHTMLIconURL(projectRoot: root.path)?.path
                == root.appendingPathComponent("assets/favicon.png").path
        )

        try Data(#"<link rel="icon" href="%PUBLIC_URL%/favicon.ico">"#.utf8).write(to: index)
        #expect(LocalPortIconResolver.indexHTMLIconURL(projectRoot: root.path) == nil)
    }

    @Test func nodePackageIconCandidatesStayInsideThePackageDirectory() {
        let activity = LocalPortActivity(
            listener: LocalPortListener(
                pid: 42,
                command: "node",
                uid: 501,
                user: "me",
                port: 3000,
                addresses: ["127.0.0.1"]
            ),
            process: LocalPortProcess(
                pid: 42,
                ppid: nil,
                command: "node",
                executablePath: "/opt/homebrew/bin/node",
                uid: 501,
                user: "me",
                cwd: "/tmp/project"
            ),
            parentChain: [],
            project: nil,
            application: nil,
            scope: .local,
            owner: LocalPortOwner(
                label: "Demo",
                category: .service,
                confidence: .high,
                reason: .nodePackage(name: "demo", directory: "/tmp/node_modules/demo")
            )
        )

        let paths = LocalPortIconResolver.localIconURLs(for: activity).map(\.path)
        #expect(paths.contains("/tmp/node_modules/demo/icon.png"))
        #expect(paths.contains("/tmp/node_modules/demo/assets/icon.png"))
        #expect(paths.contains("/tmp/node_modules/demo/logo.png"))
    }
}
