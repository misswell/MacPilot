import Foundation
import Testing
@testable import MacPilotRightClickKit

@MainActor
struct RightClickOpenWithTests {
    @Test func submitsFiveSelectedFilesInOneRequestAndPreservesLiteralPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["my photo.jpg", "literal%20.png", "照片.heic", "anim.webp", "pages.pdf"].map {
            directory.appending(path: $0, directoryHint: .notDirectory)
        }
        for file in files { try Data().write(to: file) }
        let viewer = URL(filePath: "/Applications/MacPilot.app", directoryHint: .isDirectory)
        var batches: [[URL]] = []
        RightClickFileOperations.openSelection(files.map(\.path), with: viewer) { urls, app in
            #expect(app == viewer)
            batches.append(urls)
        }
        #expect(batches == [files])
        #expect(batches.flatMap { $0 }.allSatisfy { !$0.hasDirectoryPath })
    }

    @Test func anotherApplicationStillReceivesRealDirectoriesAndEmptySelectionDoesNotLaunchIt() {
        let app = URL(filePath: "/Applications/Other.app", directoryHint: .isDirectory)
        let directory = FileManager.default.temporaryDirectory
        RightClickFileOperations.openSelection([], with: app) { _, _ in
            Issue.record("An empty Finder selection must not launch an application")
        }
        RightClickFileOperations.openSelection([directory.path], with: app) { urls, target in
            #expect(target == app)
            #expect(urls.map(\.path) == [directory.path])
            #expect(urls.first?.hasDirectoryPath == true)
        }
    }
}
