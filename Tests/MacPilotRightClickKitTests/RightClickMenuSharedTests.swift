import Foundation
import Testing
@testable import MacPilotRightClickKit

struct RightClickMenuSharedTests {
    @Test func protectedFoldersMatchWithOrWithoutTrailingSlash() {
        #expect(Utils.isProtectedFolder("/Applications/"))
        #expect(Utils.isProtectedFolder("/Applications"))
        #expect(Utils.isProtectedFolder("/System"))
        #expect(Utils.isProtectedFolder(Utils.getRealHomeDir() + "/Desktop"))
        #expect(Utils.isProtectedFolder(Utils.getRealHomeDir() + "/Desktop/"))

        #expect(!Utils.isProtectedFolder("/Applications/Safari.app"))
        #expect(!Utils.isProtectedFolder("/Users/someone/Projects"))
        #expect(!Utils.isProtectedFolder("/tmp/build-output"))
    }

    @Test func legacyIconNamesResolveToSFSymbols() {
        #expect(FileTypeIconProvider.resolvedFallbackSymbol(for: "icon-file-json") == "curlybraces")
        #expect(FileTypeIconProvider.resolvedFallbackSymbol(for: "icon-file-txt") == "doc.text")
        #expect(FileTypeIconProvider.resolvedFallbackSymbol(for: "apps.iphone.badge.checkmark") == "square.grid.2x2")
        #expect(FileTypeIconProvider.resolvedFallbackSymbol(for: "folder") == "folder")
    }

    @Test func contentSnapshotEqualityDrivesConditionalPush() {
        let actions = [ActionMenuItem(id: "copy-path", name: "Copy Path", icon: "doc.on.doc", tag: 0)]
        let apps = [AppMenuItem(id: "com.apple.Terminal", name: "Terminal", icon: "app", tag: 0, appURL: nil)]
        let newFiles = [NewFileMenuItem(id: "txt", name: "TXT", ext: ".txt", icon: "doc.text")]
        let commonDirs = [CommonDirMenuItem(id: "desktop", name: "Desktop", icon: "desktopcomputer", url: nil)]

        let first = RightClickMenuConfigPublisher.ContentSnapshot(
            actions: actions,
            apps: apps,
            newFiles: newFiles,
            commonDirs: commonDirs,
            actionsCollapsed: false,
            appsCollapsed: false,
            newFilesCollapsed: true,
            commonDirsCollapsed: true
        )
        let identical = RightClickMenuConfigPublisher.ContentSnapshot(
            actions: actions,
            apps: apps,
            newFiles: newFiles,
            commonDirs: commonDirs,
            actionsCollapsed: false,
            appsCollapsed: false,
            newFilesCollapsed: true,
            commonDirsCollapsed: true
        )
        let collapsedActions = RightClickMenuConfigPublisher.ContentSnapshot(
            actions: actions,
            apps: apps,
            newFiles: newFiles,
            commonDirs: commonDirs,
            actionsCollapsed: true,
            appsCollapsed: false,
            newFilesCollapsed: true,
            commonDirsCollapsed: true
        )
        let differentActions = RightClickMenuConfigPublisher.ContentSnapshot(
            actions: [],
            apps: apps,
            newFiles: newFiles,
            commonDirs: commonDirs,
            actionsCollapsed: false,
            appsCollapsed: false,
            newFilesCollapsed: true,
            commonDirsCollapsed: true
        )

        #expect(first == identical)
        #expect(first != collapsedActions)
        #expect(first != differentActions)
    }
}
