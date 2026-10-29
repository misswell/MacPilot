import Darwin
import Foundation

/// Durable idempotency boundary. One helper owns this ledger under its lifetime
/// recovery lock. Its separate lock lets status reads bypass the topology queue.
public final class DisplayOperationStore: @unchecked Sendable {
    public enum StoreError: Error { case unsafeFile, invalidRecord, full, conflict, missingOperation }
    private struct Record: Codable, Equatable {
        let request: DisplayControlRequest
        var response: DisplayControlResponse
    }
    private let lock = NSLock()
    public let fileURL: URL
    private let maximumRecords: Int
    private let maximumBytes = 4 * 1024 * 1024
    private var failedCompletions: [UUID: DisplayControlResponse] = [:]

    public init(fileURL: URL, maximumRecords: Int = 64) {
        self.fileURL = fileURL
        self.maximumRecords = max(1, maximumRecords)
    }

    public static var standard: DisplayOperationStore {
        DisplayOperationStore(fileURL: DisplayRecoveryJournalStore.standard.fileURL
            .deletingLastPathComponent().appendingPathComponent("DisplayControlOperations.json"))
    }

    /// Must commit successfully before either acknowledging or executing.
    public func accept(_ request: DisplayControlRequest, response: DisplayControlResponse) throws -> (response: DisplayControlResponse, isNew: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard request.isMutation, let id = request.operationID else { throw StoreError.invalidRecord }
        var records = try load()
        if let existing = records.first(where: { $0.request.operationID == id }) {
            guard existing.request == request else { throw StoreError.conflict }
            return (failedCompletions[id] ?? existing.response, false)
        }
        while records.count >= maximumRecords {
            // Keep every ID that could still authorize effects in this live
            // generation. Evicting it would let a delayed retry run again.
            if let index = records.firstIndex(where: {
                $0.response.operationStatus != .accepted
                    && ($0.request.command == .restore || $0.request.generation != response.generation)
            }) {
                records.remove(at: index)
            } else if request.command == .restore, records.count == maximumRecords {
                // One reserved slot always admits the recovery escape path.
                break
            } else { throw StoreError.full }
        }
        let accepted = response.operation(id, status: .accepted)
        records.append(Record(request: request, response: accepted))
        try save(records)
        return (accepted, true)
    }

    public func status(_ id: UUID) throws -> DisplayControlResponse? {
        lock.lock()
        defer { lock.unlock() }
        if let failed = failedCompletions[id] { return failed }
        return try load().first { $0.request.operationID == id }?.response
    }

    public func complete(_ id: UUID, response: DisplayControlResponse) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            var records = try load()
            guard let index = records.firstIndex(where: { $0.request.operationID == id }) else { throw StoreError.missingOperation }
            guard records[index].response.operationStatus == .accepted else { throw StoreError.conflict }
            records[index].response = response.operation(id, status: .completed)
            try save(records)
        } catch {
            failedCompletions[id] = DisplayControlResponse(displays: response.displays, state: .recoveryRequired,
                message: "recoveryIncomplete", generation: response.generation, helperReady: false,
                virtualDisplayUUID: response.virtualDisplayUUID, operationID: id, operationStatus: .interrupted,
                policy: response.policy, remoteSessionID: response.remoteSessionID)
            throw error
        }
    }

    /// Called only after startup recovery reconciles hardware with the journal.
    /// A process crash cannot turn a previously accepted create into another create.
    public func interruptPending(afterRecovery response: DisplayControlResponse) throws {
        lock.lock()
        defer { lock.unlock() }
        var records = try load()
        for index in records.indices where records[index].response.operationStatus == .accepted {
            let interrupted = DisplayControlResponse(displays: response.displays, state: .recoveryRequired,
                message: "operationInterrupted", generation: response.generation,
                helperReady: response.helperReady, virtualDisplayUUID: response.virtualDisplayUUID)
            records[index].response = interrupted.operation(records[index].request.operationID!, status: .interrupted)
        }
        if !records.isEmpty { try save(records) }
    }

    private func load() throws -> [Record] {
        var fileInfo = stat()
        guard lstat(fileURL.path, &fileInfo) == 0 else {
            if errno == ENOENT { return [] }
            throw StoreError.unsafeFile
        }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG, fileInfo.st_uid == getuid(),
              fileInfo.st_mode & 0o077 == 0, fileInfo.st_nlink == 1,
              fileInfo.st_size <= maximumBytes else { throw StoreError.unsafeFile }
        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == fileInfo.st_ino,
              opened.st_dev == fileInfo.st_dev else { throw StoreError.unsafeFile }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw StoreError.unsafeFile }
        let records = try JSONDecoder.displayControlDecoder.decode([Record].self, from: data)
        guard records.count <= maximumRecords + 1,
              Set(records.compactMap { $0.request.operationID }).count == records.count,
              records.allSatisfy({ $0.request.isMutation && $0.request.operationID != nil
                  && $0.request.operationID == $0.response.operationID && $0.response.operationStatus != nil }) else {
            throw StoreError.invalidRecord
        }
        return records
    }

    private func save(_ records: [Record]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw StoreError.unsafeFile }
        let data = try JSONEncoder.displayControlEncoder.encode(records)
        guard data.count <= maximumBytes else { throw StoreError.full }
        var template = Array(directory.appendingPathComponent(".display-operations-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw StoreError.unsafeFile }
        let temporary = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { close(fd); unlink(temporary) }
        guard fchmod(fd, 0o600) == 0 else { throw StoreError.unsafeFile }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.unsafeFile }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary, fileURL.path) == 0 else { throw StoreError.unsafeFile }
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw StoreError.unsafeFile }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0, try load() == records else { throw StoreError.unsafeFile }
    }
}
