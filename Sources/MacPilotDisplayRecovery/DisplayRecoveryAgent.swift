import AppKit
import ApplicationServices
import Carbon
import Darwin
import Foundation
import MacPilotDisplayControlCore
import Security
import ServiceManagement

private let displayHotKeyID = EventHotKeyID(signature: OSType(0x4D504443), id: 9)
nonisolated(unsafe) private weak var activeDisplayRecoveryAgent: DisplayRecoveryAgent?

private func displayHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard result == noErr, identifier.id == displayHotKeyID.id else { return OSStatus(eventNotHandledErr) }
    activeDisplayRecoveryAgent?.emergencyRestore()
    return noErr
}

final class DisplayRecoveryAgent: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let shared = DisplayRecoveryAgent()

    private let listener: NSXPCListener
    private let operations = DispatchQueue(label: "com.misswell.macpilot.display-recovery.operations", qos: .userInitiated)
    private let timerQueue = DispatchQueue(label: "com.misswell.macpilot.display-recovery.lease", qos: .utility)
    private let controller = DisplayTopologyController()
    private var listenerReady = false
    private var journalLockFD: Int32 = -1
    private var terminationRequested = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let heartbeatTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    private var terminationSignals: [DispatchSourceSignal] = []
    private let statusCache = DisplayRecoveryStatusCache()
    private let operationStore = DisplayOperationStore.standard
    private let admissionLock = NSLock()

    private override init() {
        listener = NSXPCListener(machServiceName: DisplayRecoveryService.serviceName)
        super.init()
        activeDisplayRecoveryAgent = self
    }

    @MainActor func run() -> Never {
        guard acquireJournalLock() else { exit(EXIT_FAILURE) }
        operations.sync {
            controller.recoverAtStartup()
            do { try operationStore.interruptPending(afterRecovery: controller.response()) }
            catch { NSLog("Display operation recovery ledger unavailable: %@", String(describing: error)) }
        }
        let hotKeyReady = registerEmergencyHotKey()
        let authenticationReady = isAuthenticHelper()
        operations.sync {
            controller.setEmergencyHotKeyReady(hotKeyReady && listenerReady)
            controller.setAuthenticationReady(authenticationReady)
        }
        statusCache.update(controller.response())

        listener.delegate = self
        listener.resume()
        listenerReady = true
        operations.sync { controller.setEmergencyHotKeyReady(hotKeyReady && listenerReady) }
        statusCache.update(controller.response())

        heartbeatTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        heartbeatTimer.setEventHandler(handler: DisplayRecoveryEventHandler.enqueue(on: operations) { @Sendable [weak self] in
            guard let self else { return }
            if self.terminationRequested {
                self.controller.restoreAll()
                if self.controller.response().state == .idle { exit(EXIT_SUCCESS) }
            } else {
                self.controller.expireLeases()
            }
            self.statusCache.update(self.controller.response())
        })
        heartbeatTimer.resume()

        for signalNumber in [SIGTERM, SIGINT] {
            _ = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: timerQueue)
            source.setEventHandler(handler: DisplayRecoveryEventHandler.enqueue(on: operations) { @Sendable [weak self] in
                guard let self else { return }
                self.terminationRequested = true
                self.controller.setEmergencyHotKeyReady(false)
                self.controller.restoreAll()
                if self.controller.response().state == .idle { exit(EXIT_SUCCESS) }
            })
            terminationSignals.append(source)
            source.resume()
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.run()
        fatalError("The display recovery agent event loop unexpectedly exited.")
    }

    private func acquireJournalLock() -> Bool {
        let directory = DisplayRecoveryJournalStore.standard.fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let directoryValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard directoryValues.isSymbolicLink != true,
                  let owner = directoryAttributes[.ownerAccountID] as? NSNumber,
                  let permissions = directoryAttributes[.posixPermissions] as? NSNumber,
                  owner.uint32Value == getuid(), permissions.intValue & 0o077 == 0 else { return false }

            let lockURL = directory.appendingPathComponent("DisplayControlRecovery.lock")
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return false }
            var fileInfo = stat()
            guard fstat(descriptor, &fileInfo) == 0,
                  (fileInfo.st_mode & S_IFMT) == S_IFREG,
                  fileInfo.st_uid == getuid(), (fileInfo.st_mode & 0o077) == 0,
                  flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                return false
            }
            journalLockFD = descriptor
            return true
        } catch {
            return false
        }
    }

    func emergencyRestore() {
        operations.async {
            self.controller.restoreAll()
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isAuthorizedCaller(connection.processIdentifier, effectiveUserID: connection.effectiveUserIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: DisplayRecoveryXPC.self)
        connection.exportedObject = DisplayRecoveryProxy(controller: controller, queue: operations, cache: statusCache, operationStore: operationStore, admissionLock: admissionLock)
        connection.invalidationHandler = {}
        connection.resume()
        return true
    }

    private func registerEmergencyHotKey() -> Bool {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            displayHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else { return false }
        var reference: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_9),
            UInt32(controlKey | optionKey | cmdKey),
            displayHotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard registerStatus == noErr, let reference else {
            if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
            return false
        }
        hotKeyRef = reference
        return true
    }

    private func isAuthorizedCaller(_ pid: pid_t, effectiveUserID: uid_t) -> Bool {
        guard pid > 0,
              effectiveUserID == getuid() else { return false }
        var guestCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else { return false }
        let identifiers = ["com.misswell.macpilot", "com.misswell.macpilot.display-recovery"]
        return identifiers.contains { identifier in
            isTeamSigned(guestCode, identifier: identifier)
        }
    }

    private func isAuthenticHelper() -> Bool {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return false }
        return isTeamSigned(selfCode, identifier: "com.misswell.macpilot.display-recovery")
    }

    private func isTeamSigned(_ code: SecCode, identifier: String) -> Bool {
        let requirementText = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = U8U443D7ZL"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}

private final class DisplayRecoveryProxy: NSObject, DisplayRecoveryXPC, @unchecked Sendable {
    private let controller: DisplayTopologyController
    private let queue: DispatchQueue
    private let decoder = JSONDecoder.displayControlDecoder
    private let encoder = JSONEncoder.displayControlEncoder
    private let cache: DisplayRecoveryStatusCache
    private let operationStore: DisplayOperationStore
    private let admissionLock: NSLock

    init(controller: DisplayTopologyController, queue: DispatchQueue, cache: DisplayRecoveryStatusCache, operationStore: DisplayOperationStore, admissionLock: NSLock) {
        self.controller = controller
        self.queue = queue
        self.cache = cache
        self.operationStore = operationStore
        self.admissionLock = admissionLock
    }

    func execute(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard data.count <= 64 * 1024,
              let request = try? decoder.decode(DisplayControlRequest.self, from: data) else {
            reply((try? encoder.encode(DisplayControlResponse(
                displays: [],
                state: .failed,
                message: DisplayControlMessageCode.malformedRequest.rawValue,
                helperReady: false
            ))) ?? Data())
            return
        }
        if request.command == .status {
            if let id = request.operationID {
                do {
                    if let response = try operationStore.status(id) {
                        reply((try? encoder.encode(response)) ?? Data())
                    } else {
                        reply(operationFailure(id, message: "operationUnknown"))
                    }
                } catch { reply(operationFailure(id, message: "operationStorageUnavailable")) }
            } else { reply(cache.encodedResponse()) }
            return
        }
        // All XPC connections share admission ordering. Work is enqueued
        // before ACK, so a following restore cannot overtake its mutation.
        admissionLock.lock()
        defer { admissionLock.unlock() }
        if request.isMutation, let id = request.operationID {
            do {
                let current = try decoder.decode(DisplayControlResponse.self, from: cache.encodedResponse())
                let managing = DisplayControlResponse(displays: current.displays, state: .managing,
                    generation: current.generation, helperReady: current.helperReady,
                    virtualDisplayUUID: current.virtualDisplayUUID, policy: current.policy, remoteSessionID: current.remoteSessionID)
                let accepted = try operationStore.accept(request, response: managing)
                guard accepted.isNew else {
                    reply((try? encoder.encode(accepted.response)) ?? Data())
                    return
                }
                cache.markManaging(for: request.command)
                queue.async { [controller, cache, operationStore] in
                    controller.handle(request, now: Date())
                    let response = controller.response()
                    cache.update(response)
                    do { try operationStore.complete(id, response: response) }
                    catch {
                        controller.restoreAll()
                        cache.update(controller.response())
                        NSLog("Display operation result could not be persisted: %@", String(describing: error))
                    }
                }
                reply((try? encoder.encode(accepted.response)) ?? Data())
            } catch { reply(operationFailure(id, message: "operationRejected")) }
            return
        }
        let receivedAt = Date()
        cache.markManaging(for: request.command)
        let responseRelay = DisplayRecoveryReply(reply)
        queue.async { [controller, encoder, cache, responseRelay] in
            let operationTime = request.command == .heartbeat ? receivedAt : Date()
            controller.handle(request, now: operationTime)
            if request.command == .heartbeat { controller.expireLeases(now: Date()) }
            let response = controller.response()
            cache.update(response)
            responseRelay.send((try? encoder.encode(response)) ?? Data())
        }
    }
    private func operationFailure(_ id: UUID, message: String) -> Data {
        (try? encoder.encode(DisplayControlResponse(displays: [], state: .recoveryRequired,
            message: message, helperReady: false, operationID: id, operationStatus: .interrupted))) ?? Data()
    }

}

private final class DisplayRecoveryReply: Sendable {
    private let callback: @Sendable (Data) -> Void
    init(_ callback: @escaping @Sendable (Data) -> Void) { self.callback = callback }
    func send(_ data: Data) { callback(data) }
}

private final class DisplayRecoveryStatusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var encoded = Data()

    func update(_ response: DisplayControlResponse) {
        guard let data = try? JSONEncoder.displayControlEncoder.encode(response) else { return }
        lock.lock()
        encoded = data
        lock.unlock()
    }

    func encodedResponse() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return encoded
    }

    func markManaging(for command: DisplayControlCommand) {
        guard [.disable, .keepOnly, .restore, .prepareVirtual, .confirmVirtual, .confirmChange].contains(command) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let response = try? JSONDecoder.displayControlDecoder.decode(DisplayControlResponse.self, from: encoded) else { return }
        let managing = DisplayControlResponse(
            displays: response.displays,
            state: .managing,
            message: response.message,
            generation: response.generation,
            confirmationDeadline: response.confirmationDeadline,
            helperReady: response.helperReady,
            virtualDisplayUUID: response.virtualDisplayUUID,
            policy: response.policy, remoteSessionID: response.remoteSessionID
        )
        if let data = try? JSONEncoder.displayControlEncoder.encode(managing) { encoded = data }
    }
}
