import Foundation
import Testing
@testable import MacPilot

struct ImageViewerBrowserTests {
    @Test func scansOnlyVisibleCandidatesInTheSelectedDirectoryAndSortsNaturally() throws {
        try ImageViewerFixture.withFolder { folder in
            for name in ["image-10.png", "image-2.jpg", ".hidden.png", "unrelated.txt"] {
                try Data([0]).write(to: folder.appendingPathComponent(name))
            }
            let child = folder.appendingPathComponent("directory.png", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            try Data([0]).write(to: child.appendingPathComponent("nested.png"))
            let result = try ImageViewerFolderIndex.scan(folder, cancelled: { false })
            #expect(result.files.map(\.lastPathComponent) == ["image-2.jpg", "image-10.png"])
            #expect(!result.truncated)
            let capped = try ImageViewerFolderIndex.scan(folder, limit: 1, cancelled: { false })
            #expect(capped.files.count == 1)
            #expect(capped.truncated)
            #expect(throws: CancellationError.self) { try ImageViewerFolderIndex.scan(folder, cancelled: { true }) }
        }
    }

    @Test func navigationKeepsOtherWindowsOnTheirOwnSelectionAndResetsPageOnFileChange() {
        let files = ["a.pdf", "b.png", "c.jpg"].map { URL(fileURLWithPath: "/test/" + $0) }
        let index = ImageViewerFolderIndex(files: files, truncated: false)
        var left = ImageViewerBrowserStore(url: files[0])
        var right = ImageViewerBrowserStore(url: files[1])
        left.install(index)
        right.install(index)
        left.updatePageCount(10)
        let changedPage = left.go(to: 7)
        #expect(changedPage)
        let movedBeforeStart = left.move(-1)
        #expect(!movedBeforeStart)
        let movedToNext = left.move(1)
        #expect(movedToNext)
        let movedToLast = left.move(1)
        #expect(movedToLast)
        #expect(left.url == files[2])
        #expect(left.page == 1)
        #expect(right.url == files[1])
        let movedRightWindow = right.move(-1)
        #expect(movedRightWindow)
        #expect(right.url == files[0])
    }
}
