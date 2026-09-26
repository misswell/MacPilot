import Foundation
import Darwin
import CryptoKit

struct AppleFileCompressionEngine: Sendable {
    private static let managedCompressionAttribute = "com.misswell.macpilot.filesystem-compressed"
    private static let legacyManagedCompressionAttribute = "com.misswell.octopilot.filesystem-compressed"
    private static let managedCompressionAttributes = [
        managedCompressionAttribute,
        legacyManagedCompressionAttribute
    ]
    private static let compressionExtendedAttributes = managedCompressionAttributes + [
        "com.apple.decmpfs",
        "com.apple.ResourceFork"
    ]
    // macOS synthesizes provenance for the new inode and may regenerate an existing value.
    private static let systemGeneratedExtendedAttributes = [
        "com.apple.provenance"
    ]


    private struct MetadataSnapshot: Equatable {
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let flags: UInt32
        let birthNanoseconds: Int64
        let modificationNanoseconds: Int64
        let accessControlList: String?
        let extendedAttributes: [String: Data]
    }


    func compress(
        _ candidates: [FileCompressionCandidate],
        settings: FolderCompressionSettings
    ) -> FileCompressionOperationResult {
        var result = FileCompressionOperationResult()
        for candidate in candidates {
            do {
                let saved = try coordinatedWrite(at: candidate.url) { sourceURL in
                    try compress(
                        candidate,
                        sourceURL: sourceURL,
                        minimumSavingsPercent: settings.minimumSavingsPercent
                    )
                }
                result.compressedCount += 1
                result.bytesSaved += saved
            } catch AppleFileCompressionError.compressionUnavailable {
                result.skippedCount += 1
            } catch AppleFileCompressionError.fileInUse {
                result.skippedCount += 1
                result.retryableFiles.append(candidate.displayPath)
            } catch AppleFileCompressionError.recoveryCopyPreserved(let path) {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.recoveryFiles.append(path)
                result.failures.append(.recoveryCopyPreserved(path))
            } catch let error as AppleFileCompressionError {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.failures.append(error)
                switch error {
                case .fileChanged, .commandFailed, .coordinationFailed, .replacementFailed:
                    result.retryableFiles.append(candidate.displayPath)
                default:
                    break
                }
            } catch {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.failures.append(.commandFailed(error.localizedDescription))
                result.retryableFiles.append(candidate.displayPath)
            }
        }
        return result
    }

    func restore(_ candidates: [FileCompressionCandidate]) -> FileCompressionOperationResult {
        var result = FileCompressionOperationResult()
        for candidate in candidates {
            do {
                try coordinatedWrite(at: candidate.url) { sourceURL in
                    try restore(candidate, sourceURL: sourceURL)
                }
                result.restoredCount += 1
            } catch AppleFileCompressionError.recoveryCopyPreserved(let path) {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.recoveryFiles.append(path)
                result.failures.append(.recoveryCopyPreserved(path))
            } catch let error as AppleFileCompressionError {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.failures.append(error)
            } catch {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.failures.append(.commandFailed(error.localizedDescription))
            }
        }
        return result
    }

    private func compress(
        _ candidate: FileCompressionCandidate,
        sourceURL: URL,
        minimumSavingsPercent: Int
    ) throws -> Int64 {
        var sourceInfo = stat()
        guard lstat(sourceURL.path, &sourceInfo) == 0,
              matches(candidate, info: sourceInfo) else {
            throw AppleFileCompressionError.fileChanged
        }
        let sourceMetadata = try metadataSnapshot(at: sourceURL, info: sourceInfo, excludingCompressionArtifacts: true)
        let sourceAllocatedSize = Int64(sourceInfo.st_blocks * 512)
        let temporaryURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".macpilot-compression-\(UUID().uuidString)")
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        try runDitto(
            arguments: ["--hfsCompression", "--noclone", sourceURL.path, temporaryURL.path]
        )
        try restoreVisibleDates(from: sourceInfo, to: temporaryURL)
        try synchronizeExtendedAttributes(sourceMetadata.extendedAttributes, at: temporaryURL)

        var compressedInfo = stat()
        guard lstat(temporaryURL.path, &compressedInfo) == 0,
              isCompressed(compressedInfo) else {
            throw AppleFileCompressionError.compressionUnavailable
        }
        let compressedMetadata = try metadataSnapshot(
            at: temporaryURL,
            info: compressedInfo,
            excludingCompressionArtifacts: true
        )
        guard preservedMetadataMatches(sourceMetadata, compressedMetadata) else {
            throw AppleFileCompressionError.verificationFailed
        }
        let compressedAllocatedSize = Int64(compressedInfo.st_blocks * 512)
        let savedBytes = sourceAllocatedSize - compressedAllocatedSize
        guard sourceAllocatedSize > 0,
              savedBytes > 0,
              savedBytes * 100 >= sourceAllocatedSize * Int64(max(0, minimumSavingsPercent)) else {
            throw AppleFileCompressionError.compressionUnavailable
        }
        guard try sha256(of: sourceURL) == sha256(of: temporaryURL) else {
            throw AppleFileCompressionError.verificationFailed
        }
        try setManagedCompressionAttribute(at: temporaryURL)

        var unchangedInfo = stat()
        guard lstat(sourceURL.path, &unchangedInfo) == 0,
              matches(candidate, info: unchangedInfo) else {
            throw AppleFileCompressionError.fileChanged
        }
        let unchangedMetadata = try metadataSnapshot(at: sourceURL, info: unchangedInfo)
        guard try !isOpenByAnotherProcess(sourceURL) else {
            throw AppleFileCompressionError.fileInUse
        }
        guard atomicExchange(sourceURL: sourceURL, replacementURL: temporaryURL) else {
            throw AppleFileCompressionError.replacementFailed
        }
        do {
            var displacedInfo = stat()
            guard lstat(temporaryURL.path, &displacedInfo) == 0,
                  matchesAfterExchange(before: unchangedInfo, after: displacedInfo),
                  try metadataSnapshot(at: temporaryURL, info: displacedInfo) == unchangedMetadata else {
                throw AppleFileCompressionError.fileChanged
            }
        } catch {
            guard atomicExchange(sourceURL: sourceURL, replacementURL: temporaryURL) else {
                shouldRemoveTemporary = false
                throw AppleFileCompressionError.recoveryCopyPreserved(temporaryURL.path)
            }
            throw error
        }
        return savedBytes
    }

    private func restore(_ candidate: FileCompressionCandidate, sourceURL: URL) throws {
        var sourceInfo = stat()
        guard lstat(sourceURL.path, &sourceInfo) == 0,
              matches(candidate, info: sourceInfo),
              isCompressed(sourceInfo) else {
            throw AppleFileCompressionError.fileChanged
        }
        let sourceMetadata = try metadataSnapshot(at: sourceURL, info: sourceInfo, excludingCompressionArtifacts: true)
        let temporaryURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".macpilot-restoration-\(UUID().uuidString)")
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        try runDitto(
            arguments: [
                "--nohfsCompression",
                "--nopreserveHFSCompression",
                "--noclone",
                sourceURL.path,
                temporaryURL.path
            ]
        )
        try restoreVisibleDates(from: sourceInfo, to: temporaryURL)
        try synchronizeExtendedAttributes(sourceMetadata.extendedAttributes, at: temporaryURL)

        var restoredInfo = stat()
        guard lstat(temporaryURL.path, &restoredInfo) == 0,
              !isCompressed(restoredInfo),
              try sha256(of: sourceURL) == sha256(of: temporaryURL) else {
            throw AppleFileCompressionError.verificationFailed
        }
        let restoredMetadata = try metadataSnapshot(
            at: temporaryURL,
            info: restoredInfo,
            excludingCompressionArtifacts: true
        )
        guard preservedMetadataMatches(sourceMetadata, restoredMetadata) else {
            throw AppleFileCompressionError.verificationFailed
        }
        try removeManagedCompressionAttribute(at: temporaryURL)
        var unchangedInfo = stat()
        guard lstat(sourceURL.path, &unchangedInfo) == 0,
              matches(candidate, info: unchangedInfo) else {
            throw AppleFileCompressionError.fileChanged
        }
        let unchangedMetadata = try metadataSnapshot(at: sourceURL, info: unchangedInfo)
        guard try !isOpenByAnotherProcess(sourceURL) else {
            throw AppleFileCompressionError.fileInUse
        }
        guard atomicExchange(sourceURL: sourceURL, replacementURL: temporaryURL) else {
            throw AppleFileCompressionError.replacementFailed
        }
        do {
            var displacedInfo = stat()
            guard lstat(temporaryURL.path, &displacedInfo) == 0,
                  matchesAfterExchange(before: unchangedInfo, after: displacedInfo),
                  try metadataSnapshot(at: temporaryURL, info: displacedInfo) == unchangedMetadata else {
                throw AppleFileCompressionError.fileChanged
            }
        } catch {
            guard atomicExchange(sourceURL: sourceURL, replacementURL: temporaryURL) else {
                shouldRemoveTemporary = false
                throw AppleFileCompressionError.recoveryCopyPreserved(temporaryURL.path)
            }
            throw error
        }
    }

    func isCompressed(_ info: stat) -> Bool {
        info.st_flags & UInt32(UF_COMPRESSED) != 0
    }

    private func matches(_ candidate: FileCompressionCandidate, info: stat) -> Bool {
        UInt64(info.st_dev) == candidate.deviceID
            && UInt64(info.st_ino) == candidate.inode
            && Int64(info.st_size) == candidate.logicalSize
            && modificationNanoseconds(info) == candidate.modificationNanoseconds
            && changeNanoseconds(info) == candidate.changeNanoseconds
            && info.st_nlink == 1
    }

    private func matchesAfterExchange(before: stat, after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_birthtimespec.tv_sec == after.st_birthtimespec.tv_sec
            && before.st_birthtimespec.tv_nsec == after.st_birthtimespec.tv_nsec
            && before.st_mode == after.st_mode
            && before.st_uid == after.st_uid
            && before.st_gid == after.st_gid
            && before.st_flags == after.st_flags
            && after.st_nlink == 1
    }

    func modificationNanoseconds(_ info: stat) -> Int64 {
        Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    func changeNanoseconds(_ info: stat) -> Int64 {
        Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
    }

    private func birthNanoseconds(_ info: stat) -> Int64 {
        Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec)
    }

    private func restoreVisibleDates(from info: stat, to url: URL) throws {
        let creationDate = Date(
            timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)
                + TimeInterval(info.st_birthtimespec.tv_nsec) / 1_000_000_000
        )
        let modificationDate = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        try FileManager.default.setAttributes(
            [.creationDate: creationDate, .modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
    }

    private func metadataSnapshot(
        at url: URL,
        info: stat,
        excludingCompressionArtifacts: Bool = false
    ) throws -> MetadataSnapshot {
        var flags = info.st_flags
        var attributes = try extendedAttributes(at: url)
        if excludingCompressionArtifacts {
            flags &= ~UInt32(UF_COMPRESSED)
            for name in Self.compressionExtendedAttributes { attributes[name] = nil }
        }
        return MetadataSnapshot(
            mode: info.st_mode,
            owner: info.st_uid,
            group: info.st_gid,
            flags: flags,
            birthNanoseconds: birthNanoseconds(info),
            modificationNanoseconds: modificationNanoseconds(info),
            accessControlList: accessControlListText(at: url),
            extendedAttributes: attributes
        )
    }

    private func preservedMetadataMatches(_ source: MetadataSnapshot, _ copy: MetadataSnapshot) -> Bool {
        source.mode == copy.mode
            && source.owner == copy.owner
            && source.group == copy.group
            && source.flags == copy.flags
            && abs(source.birthNanoseconds - copy.birthNanoseconds) <= 1_000
            && abs(source.modificationNanoseconds - copy.modificationNanoseconds) <= 1_000
            && source.accessControlList == copy.accessControlList
            && Self.preservedExtendedAttributesMatch(source: source.extendedAttributes, copy: copy.extendedAttributes)
    }

    static func preservedExtendedAttributesMatch(source: [String: Data], copy: [String: Data]) -> Bool {
        var normalizedSource = source
        var normalizedCopy = copy
        for name in Self.systemGeneratedExtendedAttributes {
            guard source[name] == nil || copy[name] != nil else { return false }
            normalizedSource[name] = nil
            normalizedCopy[name] = nil
        }
        return normalizedSource == normalizedCopy
    }

    func hasExtendedAttribute(_ name: String, at url: URL) -> Bool {
        getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private func extendedAttributes(at url: URL) throws -> [String: Data] {
        let byteCount = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard byteCount >= 0 else {
            throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
        }
        guard byteCount > 0 else { return [:] }
        var nameBuffer = [CChar](repeating: 0, count: byteCount)
        let actualByteCount = listxattr(url.path, &nameBuffer, nameBuffer.count, XATTR_NOFOLLOW)
        guard actualByteCount >= 0 else {
            throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
        }
        let nameBytes = nameBuffer.prefix(actualByteCount).map { UInt8(bitPattern: $0) }
        let names = nameBytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var result: [String: Data] = [:]
        for name in names {
            let valueSize = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard valueSize >= 0 else {
                throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
            }
            var value = Data(count: valueSize)
            let readSize = value.withUnsafeMutableBytes { bytes in
                getxattr(url.path, name, bytes.baseAddress, valueSize, 0, XATTR_NOFOLLOW)
            }
            guard readSize == valueSize else {
                throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
            }
            result[name] = value
        }
        return result
    }

    private func synchronizeExtendedAttributes(_ expected: [String: Data], at url: URL) throws {
        let preservedBySystem = Set(Self.compressionExtendedAttributes + Self.systemGeneratedExtendedAttributes)
        let current = try extendedAttributes(at: url)
        for name in current.keys where expected[name] == nil && !preservedBySystem.contains(name) {
            guard removexattr(url.path, name, XATTR_NOFOLLOW) == 0 || errno == ENOATTR else {
                throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
            }
        }
        for (name, value) in expected where !Self.systemGeneratedExtendedAttributes.contains(name) {
            let status = value.withUnsafeBytes { bytes in
                setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
            guard status == 0 else {
                throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
            }
        }
    }

    private func accessControlListText(at url: URL) -> String? {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private func isOpenByAnotherProcess(_ url: URL) throws -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--", url.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try Self.fileIsOpen(lsofStatus: process.terminationStatus, output: output)
    }

    static func fileIsOpen(lsofStatus: Int32, output: Data) throws -> Bool {
        let message = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch lsofStatus {
        case 0:
            return true
        case 1 where message.isEmpty:
            return false
        default:
            throw AppleFileCompressionError.commandFailed(message)
        }
    }

    func hasManagedCompressionAttribute(at url: URL) -> Bool {
        Self.managedCompressionAttributes.contains {
            getxattr(url.path, $0, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    private func setManagedCompressionAttribute(at url: URL) throws {
        let value = Array("1".utf8)
        let status = value.withUnsafeBytes { bytes in
            setxattr(
                url.path,
                Self.managedCompressionAttribute,
                bytes.baseAddress,
                bytes.count,
                0,
                XATTR_NOFOLLOW
            )
        }
        guard status == 0 else {
            throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
        }
    }

    private func removeManagedCompressionAttribute(at url: URL) throws {
        for attribute in Self.managedCompressionAttributes {
            let status = removexattr(url.path, attribute, XATTR_NOFOLLOW)
            guard status == 0 || errno == ENOATTR else {
                throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
            }
        }
    }

    private func sha256(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }

    private func runDitto(arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppleFileCompressionError.commandFailed(output)
        }
    }

    private func coordinatedWrite<T>(at url: URL, operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            operationResult = Result { try operation(coordinatedURL) }
        }
        if let coordinationError {
            throw AppleFileCompressionError.coordinationFailed(coordinationError.localizedDescription)
        }
        guard let operationResult else {
            throw AppleFileCompressionError.coordinationFailed("No coordinated file was provided.")
        }
        return try operationResult.get()
    }

    private func atomicExchange(sourceURL: URL, replacementURL: URL) -> Bool {
        replacementURL.path.withCString { replacementPath in
            sourceURL.path.withCString { sourcePath in
                renamex_np(replacementPath, sourcePath, UInt32(RENAME_SWAP)) == 0
            }
        }
    }
}
