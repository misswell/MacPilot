import Darwin
import Foundation
import Testing
@testable import MacPilotDisplayControlCore

struct DisplayOperationStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }
    private let managing = DisplayControlResponse(displays: [], state: .managing, helperReady: true)
    private let completed = DisplayControlResponse(displays: [], state: .active, helperReady: true)

    @Test func acceptedRequestIsDurableIdempotentAndConflictingPayloadCannotExecute() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("operations.json")
        let store = DisplayOperationStore(fileURL: file)
        let id = UUID()
        let request = DisplayControlRequest(command: .prepareVirtual, operationID: id,
            virtualSpec: .init(width: 1920, height: 1080))
        let accepted = try store.accept(request, response: managing)
        #expect(accepted.isNew)
        #expect(accepted.response.operationStatus == .accepted)
        let reopened = DisplayOperationStore(fileURL: file)
        #expect(try reopened.status(id)?.operationStatus == .accepted)
        #expect(try !reopened.accept(request, response: managing).isNew)
        #expect(throws: DisplayOperationStore.StoreError.self) {
            try reopened.accept(.init(command: .restore, operationID: id), response: managing)
        }
        try reopened.complete(id, response: completed)
        let duplicate = try reopened.accept(request, response: managing)
        #expect(!duplicate.isNew)
        #expect(duplicate.response.state == .active)
        #expect(duplicate.response.operationStatus == .completed)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func restartInterruptsPendingCreatesAfterRecoveryAndNeverReexecutes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("operations.json")
        let request = DisplayControlRequest(command: .prepareVirtual, operationID: UUID())
        let store = DisplayOperationStore(fileURL: file)
        _ = try store.accept(request, response: managing)
        let restarted = DisplayOperationStore(fileURL: file)
        try restarted.interruptPending(afterRecovery: .init(displays: [], state: .idle, helperReady: true))
        let replay = try restarted.accept(request, response: managing)
        #expect(!replay.isNew)
        #expect(replay.response.operationStatus == .interrupted)
        #expect(replay.response.state == .recoveryRequired)
    }

    @Test func fullLedgerNeverPrunesPendingOperations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DisplayOperationStore(fileURL: directory.appendingPathComponent("operations.json"), maximumRecords: 1)
        let first = DisplayControlRequest(command: .restore, operationID: UUID())
        let second = DisplayControlRequest(command: .disable, operationID: UUID())
        _ = try store.accept(first, response: managing)
        #expect(throws: DisplayOperationStore.StoreError.self) { try store.accept(second, response: managing) }
        #expect(try store.status(first.operationID!)?.operationStatus == .accepted)
        try store.complete(first.operationID!, response: completed)
        #expect(try store.accept(second, response: managing).isNew)
        #expect(try store.status(first.operationID!) == nil)
    }

    @Test func symlinkAndNonprivateFilesCannotAuthorizeOperations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("operations.json")
        let target = directory.appendingPathComponent("target")
        try Data("[]".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let store = DisplayOperationStore(fileURL: file)
        let request = DisplayControlRequest(command: .restore, operationID: UUID())
        #expect(throws: DisplayOperationStore.StoreError.self) { try store.accept(request, response: managing) }
        try FileManager.default.removeItem(at: file)
        try Data("[]".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: DisplayOperationStore.StoreError.self) { try store.accept(request, response: managing) }
    }

    @Test func liveGenerationIDsRemainIdempotentWhenLedgerIsFullAndRestoreHasAReservedSlot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DisplayOperationStore(fileURL: directory.appendingPathComponent("operations.json"), maximumRecords: 1)
        let generation = UUID()
        let request = DisplayControlRequest(command: .disable, operationID: UUID(), targetUUID: "two", generation: generation)
        let response = DisplayControlResponse(displays: [], state: .active, generation: generation, helperReady: true)
        _ = try store.accept(request, response: response)
        try store.complete(request.operationID!, response: response)
        #expect(throws: DisplayOperationStore.StoreError.self) {
            try store.accept(.init(command: .disable, operationID: UUID(), targetUUID: "three", generation: generation), response: response)
        }
        let replay = try store.accept(request, response: response)
        #expect(!replay.isNew)
        #expect(replay.response.operationStatus == .completed)
        let restoration = try store.accept(.init(command: .restore, operationID: UUID()), response: response)
        #expect(restoration.isNew)
        #expect(restoration.response.operationStatus == .accepted)
        #expect(try store.status(request.operationID!)?.operationStatus == .completed)
    }

    @Test func failedCompletionPersistenceReportsRecoveryInsteadOfPollingForever() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("operations.json")
        let store = DisplayOperationStore(fileURL: file)
        let id = UUID()
        let request = DisplayControlRequest(command: .restore, operationID: id)
        _ = try store.accept(request, response: managing)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: DisplayOperationStore.StoreError.self) { try store.complete(id, response: completed) }
        #expect(try store.status(id)?.operationStatus == .interrupted)
        #expect(try store.status(id)?.state == .recoveryRequired)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let duplicate = try store.accept(request, response: managing)
        #expect(!duplicate.isNew)
        #expect(duplicate.response.operationStatus == .interrupted)
        #expect(try DisplayOperationStore(fileURL: file).status(id)?.operationStatus == .accepted)
    }

    @Test func wireFieldsAreOptionalForLegacyPeers() throws {
        let request = try JSONDecoder().decode(DisplayControlRequest.self,
            from: Data("{\"command\":\"restore\",\"confirmed\":false}".utf8))
        #expect(request.operationID == nil)
        let response = try JSONDecoder().decode(DisplayControlResponse.self,
            from: Data("{\"displays\":[],\"state\":\"idle\",\"helperReady\":true}".utf8))
        #expect(response.operationID == nil)
        #expect(response.operationStatus == nil)
    }
}
