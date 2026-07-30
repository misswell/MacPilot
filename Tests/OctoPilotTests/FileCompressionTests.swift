import Foundation
import Testing
@testable import OctoPilot

struct FileCompressionTests {
    @Test func migratesLegacySingleFolderCompressionSettings() throws {
        let json = """
        {
          "folderPath": "/tmp/legacy",
          "fileExtensions": ["log"],
          "minimumFileSize": 1024,
          "stableSeconds": 600,
          "minimumSavingsPercent": 10,
          "automaticallyCompress": true
        }
        """

        let settings = try JSONDecoder().decode(FolderCompressionSettings.self, from: Data(json.utf8))

        #expect(settings.folderPaths == ["/tmp/legacy"])
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(encoded["folderPaths"] as? [String] == ["/tmp/legacy"])
        #expect(encoded["folderPath"] == nil)
    }

    @Test func localizesStorageCompressionActions() {
        #expect(AppText.value("fileCompression", language: .simplifiedChinese) == "存储压缩")
        #expect(AppText.value("fileCompression", language: .english) == "Storage Compression")
        #expect(AppText.value("compressionRestoreFiles", language: .simplifiedChinese, 3) == "恢复 3 个文件")
        #expect(AppText.value("compressionRestoreFiles", language: .english, 3) == "Restore 3 Files")
        #expect(AppText.value("compressionFolderCount", language: .simplifiedChinese, 2) == "已添加 2 个文件夹")
        #expect(AppText.value("compressionFolderCount", language: .english, 2) == "Monitoring 2 folders")
        #expect(AppText.value("compressionRemoveFolderTitle", language: .simplifiedChinese) == "移除监控文件夹？")
        #expect(AppText.value("compressionRemoveFolderTitle", language: .english) == "Remove Monitored Folder?")
        #expect(AppText.value("compressionCompressing", language: .simplifiedChinese) == "正在压缩文件…")
        #expect(AppText.value("compressionRestoring", language: .simplifiedChinese) == "正在恢复文件…")
        #expect(AppText.value("compressionCompressing", language: .english) == "Compressing files…")
        #expect(AppText.value("compressionRestoring", language: .english) == "Restoring files…")
        #expect(AppText.value("compressionAutomaticInfo", language: .simplifiedChinese) == "自动扫描方式")
        #expect(AppText.value("compressionAutomaticInfo", language: .english) == "Automatic scanning")
        #expect(AppText.value("compressionAutomaticInfoBody", language: .simplifiedChinese).contains("每 24 小时"))
        #expect(AppText.value("compressionAutomaticInfoBody", language: .english).contains("every 24 hours"))
        #expect(AppText.value("compressionErrorMonitoringUnavailable", language: .simplifiedChinese).contains("文件夹变化监控"))
        #expect(AppText.value("compressionErrorMonitoringUnavailable", language: .english).contains("Folder change monitoring"))
        #expect(AppText.value("compressionViewAllCompressed", language: .simplifiedChinese, 32) == "查看全部 32 个已压缩文件")
        #expect(AppText.value("compressionViewAllCompressed", language: .english, 32) == "View All 32 Compressed Files")
        #expect(AppText.value("compressionSortLogicalSize", language: .simplifiedChinese) == "逻辑大小（从大到小）")
        #expect(AppText.value("compressionSortActualSize", language: .english) == "Actual Size (Largest First)")
    }

    @Test func selectsOnlyStableMatchingFiles() {
        let now = Date(timeIntervalSince1970: 10_000)
        let settings = FolderCompressionSettings(
            fileExtensions: [".LOG", " json "],
            minimumFileSize: 1_024,
            stableSeconds: 600
        )
        let policy = FileCompressionPolicy(settings: settings)

        let eligible = FileCompressionFacts(
            pathExtension: "log",
            logicalSize: 4_096,
            allocatedSize: 4_096,
            modifiedAt: now.addingTimeInterval(-601)
        )
        let wrongExtension = FileCompressionFacts(
            pathExtension: "zip",
            logicalSize: 4_096,
            allocatedSize: 4_096,
            modifiedAt: now.addingTimeInterval(-601)
        )
        let stillChanging = FileCompressionFacts(
            pathExtension: "json",
            logicalSize: 4_096,
            allocatedSize: 4_096,
            modifiedAt: now.addingTimeInterval(-599)
        )

        #expect(policy.eligibility(of: eligible, now: now) == .eligible)
        #expect(policy.eligibility(of: wrongExtension, now: now) == .excluded(.fileExtension))
        #expect(policy.eligibility(of: stillChanging, now: now) == .excluded(.recentlyModified))
    }

    @Test func excludesFilesWhoseIdentityOrStorageIsUnsafeToReplace() {
        let now = Date(timeIntervalSince1970: 10_000)
        let policy = FileCompressionPolicy(settings: FolderCompressionSettings(
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        ))
        let base = FileCompressionFacts(
            pathExtension: "log",
            logicalSize: 1_000_000,
            allocatedSize: 1_000_000,
            modifiedAt: now
        )

        var hardLinked = base
        hardLinked.linkCount = 2
        var cloudPlaceholder = base
        cloudPlaceholder.isCloudPlaceholder = true
        var sparse = base
        sparse.allocatedSize = 100_000
        var partiallySparse = base
        partiallySparse.allocatedSize = 999_999
        var dataless = base
        dataless.allocatedSize = 0

        #expect(policy.eligibility(of: hardLinked, now: now) == .excluded(.hardLinked))
        #expect(policy.eligibility(of: cloudPlaceholder, now: now) == .excluded(.cloudPlaceholder))
        #expect(policy.eligibility(of: sparse, now: now) == .excluded(.sparse))
        #expect(policy.eligibility(of: partiallySparse, now: now) == .excluded(.sparse))
        #expect(policy.eligibility(of: dataless, now: now) == .excluded(.sparse))
    }

    @Test func excludesFilesAboveTheMacOSFilesystemCompressionLimit() {
        let now = Date(timeIntervalSince1970: 10_000)
        let policy = FileCompressionPolicy(settings: FolderCompressionSettings(
            fileExtensions: ["json"],
            minimumFileSize: 1,
            stableSeconds: 0
        ))
        let maximum = FileCompressionPolicy.maximumCompressibleFileSize
        let supported = FileCompressionFacts(
            pathExtension: "json",
            logicalSize: maximum,
            allocatedSize: maximum,
            modifiedAt: now
        )
        let tooLarge = FileCompressionFacts(
            pathExtension: "json",
            logicalSize: maximum + 1,
            allocatedSize: maximum + 1,
            modifiedAt: now
        )

        #expect(policy.eligibility(of: supported, now: now) == .eligible)
        #expect(policy.eligibility(of: tooLarge, now: now) == .excluded(.tooLargeForSystemCompression))
    }

    @Test func onlyTransientFolderScanIssuesAreRetriedAutomatically() {
        let folderURL = URL(fileURLWithPath: "/tmp/monitored", isDirectory: true)

        #expect(FileCompressionFolderIssue(
            folderURL: folderURL,
            error: .folderUnavailable
        ).isRetryableForAutomaticCompression)
        #expect(FileCompressionFolderIssue(
            folderURL: folderURL,
            error: .scanFailed("Temporary I/O error")
        ).isRetryableForAutomaticCompression)
        #expect(!FileCompressionFolderIssue(
            folderURL: folderURL,
            error: .unsupportedFileSystem("exFAT")
        ).isRetryableForAutomaticCompression)
    }

    @Test func recursivelyScansOnlyEligibleFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let oldDate = Date(timeIntervalSinceNow: -3_600)

        try writeFile(named: "eligible.log", in: root, modifiedAt: oldDate)
        try writeFile(named: "archive.zip", in: root, modifiedAt: oldDate)
        try writeFile(named: "changing.log", in: root, modifiedAt: Date())
        try writeFile(named: "nested/data.json", in: root, modifiedAt: oldDate)
        try writeFile(named: "resource-fork.log", in: root, modifiedAt: oldDate)
        try runXattr(["-w", "com.apple.ResourceFork", "legacy", root.appendingPathComponent("resource-fork.log").path])

        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log", "json"],
            minimumFileSize: 1_024,
            stableSeconds: 600
        )
        let scan = try AppleFileCompressionEngine().scan(settings: settings)

        #expect(scan.candidates.map(\.relativePath).sorted() == ["eligible.log", "nested/data.json"])
        #expect(scan.compressedFiles.isEmpty)
        #expect(scan.candidateBytes == 4_096)
    }

    @Test func scansMultipleFoldersWithoutDuplicatingOverlappingFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let oldDate = Date(timeIntervalSinceNow: -3_600)
        try writeFile(named: "first.log", in: root, modifiedAt: oldDate)
        try writeFile(named: "nested/overlap.log", in: root, modifiedAt: oldDate)
        try writeFile(named: "second.log", in: secondRoot, modifiedAt: oldDate)
        let settings = FolderCompressionSettings(
            folderPaths: [root.path, nested.path, secondRoot.path],
            fileExtensions: ["log"],
            minimumFileSize: 1_024,
            stableSeconds: 600
        )

        let scan = try AppleFileCompressionEngine().scan(settings: settings)

        #expect(scan.folderURLs.count == 3)
        #expect(scan.folderIssues.isEmpty)
        #expect(Set(scan.candidates.map(\.url.lastPathComponent)) == ["first.log", "overlap.log", "second.log"])
        #expect(scan.candidates.count == 3)
    }

    @Test func incrementalScanOnlyExaminesChangedFilesAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("new-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let oldDate = Date(timeIntervalSinceNow: -3_600)
        try writeFile(named: "changed.log", in: root, modifiedAt: oldDate)
        try writeFile(named: "unchanged.log", in: root, modifiedAt: oldDate)
        try writeFile(named: "new-directory/new.log", in: root, modifiedAt: oldDate)
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        )

        let candidates = try AppleFileCompressionEngine().scanChangedPaths(
            [root.appendingPathComponent("changed.log").path, nested.path],
            settings: settings
        )

        #expect(Set(candidates.map(\.relativePath)) == ["changed.log", "new-directory/new.log"])
    }

    @Test func incrementalScanIgnoresDeletedAndOutsidePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try writeFile(named: "outside.log", in: outsideRoot, modifiedAt: .distantPast)
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        )

        let candidates = try AppleFileCompressionEngine().scanChangedPaths(
            [root.appendingPathComponent("deleted.log").path, outsideRoot.appendingPathComponent("outside.log").path],
            settings: settings
        )

        #expect(candidates.isEmpty)
    }

    @Test func incrementalScanHonorsFileStabilityWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modifiedAt = Date(timeIntervalSince1970: 1_000)
        try writeFile(named: "new.log", in: root, modifiedAt: modifiedAt)
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 600
        )
        let path = root.appendingPathComponent("new.log").path

        let tooEarly = try AppleFileCompressionEngine().scanChangedPaths(
            [path],
            settings: settings,
            now: Date(timeIntervalSince1970: 1_599)
        )
        let stable = try AppleFileCompressionEngine().scanChangedPaths(
            [path],
            settings: settings,
            now: Date(timeIntervalSince1970: 1_600)
        )

        #expect(tooEarly.isEmpty)
        #expect(stable.map(\.relativePath) == ["new.log"])
    }

    @Test func continuesScanningAvailableFoldersAndReportsUnavailableFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(named: "available.log", in: root, modifiedAt: Date(timeIntervalSinceNow: -3_600))
        let settings = FolderCompressionSettings(
            folderPaths: [missing.path, root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        )

        let scan = try AppleFileCompressionEngine().scan(settings: settings)

        #expect(scan.candidates.map(\.url.lastPathComponent) == ["available.log"])
        #expect(scan.folderIssues == [FileCompressionFolderIssue(
            folderURL: URL(
                fileURLWithPath: FileCompressionPath.canonical(missing.path),
                isDirectory: true
            ),
            error: .folderUnavailable
        )])
    }

    @Test func distinguishesSameNamedFilesFromDifferentFolders() throws {
        let firstParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-first-\(UUID().uuidString)", isDirectory: true)
        let secondParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-second-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = firstParent.appendingPathComponent("Logs", isDirectory: true)
        let secondRoot = secondParent.appendingPathComponent("Logs", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: firstParent)
            try? FileManager.default.removeItem(at: secondParent)
        }
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let oldDate = Date(timeIntervalSinceNow: -3_600)
        try writeFile(named: "same.log", in: firstRoot, modifiedAt: oldDate)
        try writeFile(named: "same.log", in: secondRoot, modifiedAt: oldDate)
        let settings = FolderCompressionSettings(
            folderPaths: [firstRoot.path, secondRoot.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        )

        let scan = try AppleFileCompressionEngine().scan(settings: settings)

        #expect(Set(scan.candidates.map(\.relativePath)) == ["same.log"])
        #expect(Set(scan.candidates.map(\.displayPath)).count == 2)
        #expect(scan.candidates.allSatisfy { $0.displayPath == $0.url.path })
    }

    @Test func deduplicatesFolderPathsThatResolveToTheSameDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let link = parent.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        let settings = FolderCompressionSettings(folderPaths: [root.path, link.path])

        #expect(settings.folderPaths == [root.path])
    }

    @Test @MainActor func modelAddsDeduplicatesAndRemovesFolders() {
        let model = FolderCompressionModel()
        let first = URL(fileURLWithPath: "/tmp/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/second", isDirectory: true)

        model.addFolders([first, first, second])
        #expect(model.settings.folderPaths == ["/tmp/first", "/tmp/second"])

        model.removeFolder(path: first.path)
        #expect(model.settings.folderPaths == ["/tmp/second"])
    }

    @Test func compressesWithoutChangingContentOrVisibleDates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("compressible.log")
        let content = Data(repeating: 65, count: 2_000_000)
        try content.write(to: sourceURL)
        let visibleDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: visibleDate, .modificationDate: visibleDate, .posixPermissions: 0o640],
            ofItemAtPath: sourceURL.path
        )
        try runXattr(["-w", "com.misswell.octopilot.test", "preserved", sourceURL.path])
        try runCommand("/bin/chmod", ["+a", "everyone allow read", sourceURL.path])
        let datesBefore = try sourceURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let accessControlBefore = try runCommand("/bin/ls", ["-lde", sourceURL.path])
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0,
            minimumSavingsPercent: 10
        )
        let engine = AppleFileCompressionEngine()
        let scan = try engine.scan(settings: settings)

        let result = engine.compress(scan.candidates, settings: settings)

        #expect(result.compressedCount == 1)
        #expect(result.failedCount == 0)
        #expect(result.bytesSaved > 1_000_000)
        #expect(try Data(contentsOf: sourceURL) == content)
        let scanAfter = try engine.scan(settings: settings)
        #expect(scanAfter.candidates.isEmpty)
        #expect(scanAfter.compressedFiles.map(\.relativePath) == ["compressible.log"])
        let datesAfter = try sourceURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        #expect(datesAfter.creationDate == datesBefore.creationDate)
        #expect(datesAfter.contentModificationDate == datesBefore.contentModificationDate)
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o640)
        #expect(try runXattr(["-p", "com.misswell.octopilot.test", sourceURL.path]) == "preserved")
        #expect(try runCommand("/bin/ls", ["-lde", sourceURL.path]) == accessControlBefore)
    }

    @Test func compressesDownloadedFilesWithoutChangingQuarantineMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("downloaded.json")
        let content = Data(repeating: 65, count: 2_000_000)
        try content.write(to: sourceURL)
        let quarantine = "0081;686d5080;Safari;A1B2C3D4-E5F6-47A8-9012-123456789ABC"
        try runXattr(["-w", "com.apple.quarantine", quarantine, sourceURL.path])
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["json"],
            minimumFileSize: 1,
            stableSeconds: 0,
            minimumSavingsPercent: 10
        )
        let engine = AppleFileCompressionEngine()
        let scan = try engine.scan(settings: settings)

        let result = engine.compress(scan.candidates, settings: settings)

        #expect(result.compressedCount == 1, "\(result.failures)")
        #expect(result.failedCount == 0)
        #expect(try Data(contentsOf: sourceURL) == content)
        #expect(try runXattr(["-p", "com.apple.quarantine", sourceURL.path]) == quarantine)
    }

    @Test func acceptsRegeneratedProvenanceButNeverAllowsItToDisappear() {
        let provenance = Data([1, 2, 3])
        let changedProvenance = Data([4, 5, 6])

        #expect(AppleFileCompressionEngine.preservedExtendedAttributesMatch(
            source: [:],
            copy: ["com.apple.provenance": provenance]
        ))
        #expect(AppleFileCompressionEngine.preservedExtendedAttributesMatch(
            source: ["com.apple.provenance": provenance],
            copy: ["com.apple.provenance": provenance]
        ))
        #expect(AppleFileCompressionEngine.preservedExtendedAttributesMatch(
            source: ["com.apple.provenance": provenance],
            copy: ["com.apple.provenance": changedProvenance]
        ))
        #expect(!AppleFileCompressionEngine.preservedExtendedAttributesMatch(
            source: ["com.apple.provenance": provenance],
            copy: [:]
        ))
    }

    @Test func preservesExistingSystemProvenanceMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seedURL = root.appendingPathComponent("seed.txt")
        let sourceURL = root.appendingPathComponent("downloaded.json")
        try Data(repeating: 65, count: 2_000_000).write(to: seedURL)
        try runXattr(["-w", "com.apple.quarantine", "0081;686d5080;Safari;fixture", seedURL.path])
        try runCommand("/usr/bin/ditto", ["--noclone", seedURL.path, sourceURL.path])
        try FileManager.default.removeItem(at: seedURL)
        let provenanceBefore = try runXattr(["-px", "com.apple.provenance", sourceURL.path])
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["json"],
            minimumFileSize: 1,
            stableSeconds: 0,
            minimumSavingsPercent: 10
        )
        let engine = AppleFileCompressionEngine()
        let scan = try engine.scan(settings: settings)

        let result = engine.compress(scan.candidates, settings: settings)

        #expect(result.compressedCount == 1, "\(result.failures)")
        #expect(try runXattr(["-px", "com.apple.provenance", sourceURL.path]) == provenanceBefore)
    }

    @Test func restoresACompressedFileWithoutChangingItsContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("restore.log")
        let content = Data(repeating: 66, count: 1_000_000)
        try content.write(to: sourceURL)
        let visibleDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: visibleDate, .modificationDate: visibleDate], ofItemAtPath: sourceURL.path)
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        )
        let engine = AppleFileCompressionEngine()
        let initialScan = try engine.scan(settings: settings)
        #expect(engine.compress(initialScan.candidates, settings: settings).compressedCount == 1)
        let compressedScan = try engine.scan(settings: settings)

        let result = engine.restore(compressedScan.compressedFiles)

        #expect(result.restoredCount == 1)
        #expect(result.failedCount == 0)
        #expect(try Data(contentsOf: sourceURL) == content)
        let restoredScan = try engine.scan(settings: settings)
        #expect(restoredScan.compressedFiles.isEmpty)
        #expect(restoredScan.candidates.map(\.relativePath) == ["restore.log"])
        let dates = try sourceURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        #expect(dates.creationDate == visibleDate)
        #expect(dates.contentModificationDate == visibleDate)
    }

    @Test func leavesLowSavingsFilesUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("random.log")
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        let bytes = (0..<1_000_000).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state >> 32)
        }
        let content = Data(bytes)
        try content.write(to: sourceURL)
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0,
            minimumSavingsPercent: 10
        )
        let engine = AppleFileCompressionEngine()
        let scan = try engine.scan(settings: settings)

        let result = engine.compress(scan.candidates, settings: settings)

        #expect(result.compressedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.failedCount == 0)
        #expect(result.retryableFiles.isEmpty)
        #expect(try Data(contentsOf: sourceURL) == content)
        #expect(try engine.scan(settings: settings).candidates.count == 1)
    }

    @Test func metadataChangesAfterScanningPreventReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("changed.log")
        let content = Data(repeating: 67, count: 1_000_000)
        try content.write(to: sourceURL)
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        )
        let engine = AppleFileCompressionEngine()
        let scan = try engine.scan(settings: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
        try runXattr(["-w", "com.misswell.octopilot.changed", "yes", sourceURL.path])

        let result = engine.compress(scan.candidates, settings: settings)

        #expect(result.compressedCount == 0)
        #expect(result.failedCount == 1)
        #expect(result.failedFiles == [scan.candidates[0].displayPath])
        #expect(try Data(contentsOf: sourceURL) == content)
        #expect(try engine.scan(settings: settings).candidates.count == 1)
    }

    @Test func restoreRemainsAvailableAfterCompressionRulesChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("managed.log")
        try Data(repeating: 68, count: 1_000_000).write(to: sourceURL)
        let originalSettings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        )
        let engine = AppleFileCompressionEngine()
        let initialScan = try engine.scan(settings: originalSettings)
        let compressionResult = engine.compress(initialScan.candidates, settings: originalSettings)
        #expect(compressionResult.compressedCount == 1, "\(compressionResult.failures)")
        let changedSettings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["json"],
            minimumFileSize: 10_000_000,
            stableSeconds: 86_400
        )

        let changedScan = try engine.scan(settings: changedSettings)

        #expect(changedScan.candidates.isEmpty)
        #expect(changedScan.compressedFiles.map(\.relativePath) == ["managed.log"])
        #expect(engine.restore(changedScan.compressedFiles).restoredCount == 1)
    }

    @Test func openFilesAreSkippedBeforeReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoPilotCompressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("open.log")
        let content = Data(repeating: 69, count: 1_000_000)
        try content.write(to: sourceURL)
        let settings = FolderCompressionSettings(
            folderPaths: [root.path],
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        )
        let engine = AppleFileCompressionEngine()
        let scan = try engine.scan(settings: settings)
        let openHandle = try FileHandle(forWritingTo: sourceURL)
        defer { try? openHandle.close() }

        let result = engine.compress(scan.candidates, settings: settings)

        #expect(result.compressedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.failedCount == 0)
        #expect(result.retryableFiles == [FileCompressionPath.canonical(sourceURL.path)])
        #expect(try Data(contentsOf: sourceURL) == content)
    }

    @Test func openFileProbeFailsClosedWhenLsofReportsAnError() throws {
        #expect(try !AppleFileCompressionEngine.fileIsOpen(lsofStatus: 1, output: Data()))

        do {
            _ = try AppleFileCompressionEngine.fileIsOpen(
                lsofStatus: 1,
                output: Data("permission denied".utf8)
            )
            Issue.record("An lsof diagnostic was treated as an empty result")
        } catch let error as AppleFileCompressionError {
            #expect(error == .commandFailed("permission denied"))
        }
    }

    private func writeFile(named name: String, in root: URL, modifiedAt: Date) throws {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 65, count: 2_048).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    @discardableResult
    private func runXattr(_ arguments: [String]) throws -> String {
        try runCommand("/usr/bin/xattr", arguments)
    }

    @discardableResult
    private func runCommand(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppleFileCompressionError.commandFailed(String(decoding: output, as: UTF8.self))
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
