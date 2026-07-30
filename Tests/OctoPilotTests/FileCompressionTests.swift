import Foundation
import Testing
@testable import OctoPilot

struct FileCompressionTests {
    @Test func localizesStorageCompressionActions() {
        #expect(AppText.value("fileCompression", language: .simplifiedChinese) == "存储压缩")
        #expect(AppText.value("fileCompression", language: .english) == "Storage Compression")
        #expect(AppText.value("compressionRestoreFiles", language: .simplifiedChinese, 3) == "恢复 3 个文件")
        #expect(AppText.value("compressionRestoreFiles", language: .english, 3) == "Restore 3 Files")
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
            folderPath: root.path,
            fileExtensions: ["log", "json"],
            minimumFileSize: 1_024,
            stableSeconds: 600
        )
        let scan = try AppleFileCompressionEngine().scan(settings: settings)

        #expect(scan.candidates.map(\.relativePath).sorted() == ["eligible.log", "nested/data.json"])
        #expect(scan.compressedFiles.isEmpty)
        #expect(scan.candidateBytes == 4_096)
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
            folderPath: root.path,
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
            folderPath: root.path,
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
            folderPath: root.path,
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
            folderPath: root.path,
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
            folderPath: root.path,
            fileExtensions: ["log"],
            minimumFileSize: 1,
            stableSeconds: 0
        )
        let engine = AppleFileCompressionEngine()
        let initialScan = try engine.scan(settings: originalSettings)
        let compressionResult = engine.compress(initialScan.candidates, settings: originalSettings)
        #expect(compressionResult.compressedCount == 1, "\(compressionResult.failures)")
        let changedSettings = FolderCompressionSettings(
            folderPath: root.path,
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
            folderPath: root.path,
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
