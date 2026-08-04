import Foundation
import CoreServices
import Darwin

enum FileCompressionPath {
    static func canonical(_ path: String) -> String {
        var existingURL = URL(fileURLWithPath: path).standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingURL.path), existingURL.path != "/" {
            missingComponents.insert(existingURL.lastPathComponent, at: 0)
            existingURL.deleteLastPathComponent()
        }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = existingURL.path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                realpath(source, destination.baseAddress)
            }
        }
        if resolved != nil {
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let existingPath = String(
                decoding: buffer[..<end].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            return missingComponents.reduce(URL(fileURLWithPath: existingPath)) { url, component in
                url.appendingPathComponent(component)
            }.path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

struct FileCompressionFileEvent: Equatable, Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
}

struct FileCompressionChangeBatch: Equatable, Sendable {
    var changedPaths: Set<String>
    var rootsRequiringFullScan: Set<String>

    static func from(
        events: [FileCompressionFileEvent],
        monitoredRoots: Set<String>
    ) -> FileCompressionChangeBatch {
        let monitoredRoots = Set(monitoredRoots.map(FileCompressionPath.canonical))
        let globallyDroppedFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        let rootRecoveryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagMount)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)
        var batch = FileCompressionChangeBatch(changedPaths: [], rootsRequiringFullScan: [])
        for event in events {
            let eventPath = FileCompressionPath.canonical(event.path)
            if event.flags & globallyDroppedFlags != 0 {
                batch.rootsRequiringFullScan.formUnion(monitoredRoots)
                continue
            }
            guard event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 else {
                continue
            }
            let lastPathComponent = URL(fileURLWithPath: eventPath).lastPathComponent
            guard ![".macpilot-compression-", ".octopilot-compression-"]
                .contains(where: lastPathComponent.hasPrefix) else {
                continue
            }
            let affectedRoots = monitoredRoots.filter { Self.isPath(eventPath, inside: $0) }
            guard !affectedRoots.isEmpty else { continue }
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                batch.changedPaths.insert(eventPath)
                continue
            }
            if event.flags & rootRecoveryFlags != 0 {
                batch.rootsRequiringFullScan.formUnion(affectedRoots)
            } else {
                guard !monitoredRoots.contains(eventPath) else { continue }
                let isDirectory = event.flags
                    & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                let directoryNeedsInspection = event.flags
                    & (FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
                guard !isDirectory || directoryNeedsInspection else { continue }
                batch.changedPaths.insert(eventPath)
            }
        }
        batch.changedPaths = batch.changedPaths.filter { path in
            !batch.rootsRequiringFullScan.contains { Self.isPath(path, inside: $0) }
        }
        return batch
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

struct FileCompressionChangeDelivery: Sendable {
    let id: UUID
    let batch: FileCompressionChangeBatch
    let eventID: FSEventStreamEventId
    let streamID: UUID
}

struct FileCompressionDueChanges: Equatable, Sendable {
    var changedPaths: Set<String> = []
    var rootsRequiringFullScan: Set<String> = []

    var isEmpty: Bool {
        changedPaths.isEmpty && rootsRequiringFullScan.isEmpty
    }
}

struct FileCompressionRetryBackoff: Sendable {
    private static let maximumAttempts = 6
    private var attempt = 0

    mutating func consumeDelay() -> TimeInterval? {
        guard attempt < Self.maximumAttempts else { return nil }
        defer { attempt += 1 }
        return min(5 * pow(2, Double(attempt)), 300)
    }

    mutating func reset() {
        attempt = 0
    }
}

struct FileCompressionPendingChanges: Sendable {
    private static let minimumDebounceSeconds: TimeInterval = 2
    private var changedPathDeadlines: [String: Date] = [:]
    private var fullScanDeadlines: [String: Date] = [:]

    var nextDeadline: Date? {
        [changedPathDeadlines.values.min(), fullScanDeadlines.values.min()]
            .compactMap { $0 }
            .min()
    }

    mutating func record(
        _ batch: FileCompressionChangeBatch,
        now: Date = Date(),
        stableSeconds: TimeInterval
    ) {
        let delay = max(Self.minimumDebounceSeconds, stableSeconds)
        let deadline = now.addingTimeInterval(delay)
        for root in batch.rootsRequiringFullScan {
            let descendantDeadline = changedPathDeadlines
                .filter { Self.isPath($0.key, inside: root) }
                .map(\.value)
                .max() ?? .distantPast
            fullScanDeadlines[root] = max(
                fullScanDeadlines[root] ?? .distantPast,
                deadline,
                descendantDeadline
            )
            changedPathDeadlines = changedPathDeadlines.filter { !Self.isPath($0.key, inside: root) }
        }
        for path in batch.changedPaths {
            let containingRoots = fullScanDeadlines.keys.filter { Self.isPath(path, inside: $0) }
            if containingRoots.isEmpty {
                changedPathDeadlines[path] = max(changedPathDeadlines[path] ?? .distantPast, deadline)
            } else {
                for root in containingRoots {
                    fullScanDeadlines[root] = max(fullScanDeadlines[root] ?? .distantPast, deadline)
                }
            }
        }
    }

    mutating func takeDue(at now: Date = Date()) -> FileCompressionDueChanges {
        let roots = Set(fullScanDeadlines.compactMap { $0.value <= now ? $0.key : nil })
        let paths = Set(changedPathDeadlines.compactMap { $0.value <= now ? $0.key : nil })
        for root in roots { fullScanDeadlines[root] = nil }
        for path in paths { changedPathDeadlines[path] = nil }
        return FileCompressionDueChanges(
            changedPaths: Self.minimalPaths(paths.filter { path in
                !roots.contains { Self.isPath(path, inside: $0) }
            }),
            rootsRequiringFullScan: roots
        )
    }

    mutating func removeAll() {
        changedPathDeadlines.removeAll()
        fullScanDeadlines.removeAll()
    }

    mutating func requeue(
        _ changes: FileCompressionDueChanges,
        now: Date = Date(),
        delaySeconds: TimeInterval
    ) {
        record(
            FileCompressionChangeBatch(
                changedPaths: changes.changedPaths,
                rootsRequiringFullScan: changes.rootsRequiringFullScan
            ),
            now: now,
            stableSeconds: delaySeconds
        )
    }

    mutating func rescheduleAll(
        now: Date = Date(),
        stableSeconds: TimeInterval
    ) {
        let deadline = now.addingTimeInterval(max(Self.minimumDebounceSeconds, stableSeconds))
        changedPathDeadlines = changedPathDeadlines.mapValues { _ in deadline }
        fullScanDeadlines = fullScanDeadlines.mapValues { _ in deadline }
    }

    mutating func retainPaths(inside monitoredRoots: Set<String>) {
        let roots = Set(monitoredRoots.map(FileCompressionPath.canonical))
        changedPathDeadlines = changedPathDeadlines.filter { path, _ in
            let canonicalPath = FileCompressionPath.canonical(path)
            return roots.contains { Self.isPath(canonicalPath, inside: $0) }
        }
        fullScanDeadlines = fullScanDeadlines.filter { path, _ in
            let canonicalPath = FileCompressionPath.canonical(path)
            return roots.contains { Self.isPath(canonicalPath, inside: $0) }
        }
    }

    private static func minimalPaths<S: Sequence>(_ paths: S) -> Set<String> where S.Element == String {
        let sorted = Set(paths).sorted { $0.count < $1.count }
        var result = Set<String>()
        for path in sorted where !result.contains(where: { isPath(path, inside: $0) }) {
            result.insert(path)
        }
        return result
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

final class FileCompressionEventMonitor: @unchecked Sendable {
    typealias Handler = @Sendable (FileCompressionChangeDelivery) -> Void

    private final class CallbackContext {
        weak var monitor: FileCompressionEventMonitor?

        init(monitor: FileCompressionEventMonitor) {
            self.monitor = monitor
        }
    }

    private let callbackQueue = DispatchQueue(label: "com.misswell.macpilot.file-compression-events", qos: .utility)
    private let callbackQueueKey = DispatchSpecificKey<Void>()
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()
    private var stream: FSEventStreamRef?
    private var callbackContext: CallbackContext?
    private var monitoredRoots: Set<String> = []
    private var handler: Handler?
    private var lastAcknowledgedEventID: FSEventStreamEventId?
    private var currentStreamID: UUID?
    private var outstandingDeliveries: [OutstandingDelivery] = []
    private var outstandingEventHead = 0
    private var acknowledgedDeliveryIDs = Set<UUID>()

    init() {
        callbackQueue.setSpecific(key: callbackQueueKey, value: ())
    }

    deinit {
        stop()
    }

    @discardableResult
    func start(
        paths: [String],
        sinceWhen: FSEventStreamEventId? = nil,
        handler: @escaping Handler
    ) -> Bool {
        lifecycleLock.withLock {
            stopLocked()
            let roots = Set(paths.map(FileCompressionPath.canonical))
            guard !roots.isEmpty else { return false }

            stateLock.withLock {
                monitoredRoots = roots
                self.handler = handler
                lastAcknowledgedEventID = sinceWhen ?? FSEventsGetCurrentEventId()
                currentStreamID = UUID()
                outstandingDeliveries.removeAll(keepingCapacity: true)
                outstandingEventHead = 0
                acknowledgedDeliveryIDs.removeAll(keepingCapacity: true)
            }
            let callbackContext = CallbackContext(monitor: self)
            self.callbackContext = callbackContext
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(callbackContext).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
                | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
                | FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
            guard let createdStream = FSEventStreamCreate(
                nil,
                Self.callback,
                &context,
                roots.sorted() as CFArray,
                stateLock.withLock { lastAcknowledgedEventID }
                    ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                2,
                createFlags
            ) else {
                clearState()
                self.callbackContext = nil
                return false
            }
            stream = createdStream
            FSEventStreamSetDispatchQueue(createdStream, callbackQueue)
            guard FSEventStreamStart(createdStream) else {
                FSEventStreamInvalidate(createdStream)
                FSEventStreamRelease(createdStream)
                stream = nil
                self.callbackContext = nil
                clearState()
                return false
            }
            return true
        }
    }

    var resumeEventID: FSEventStreamEventId? {
        stateLock.withLock { lastAcknowledgedEventID }
    }

    func acknowledge(_ delivery: FileCompressionChangeDelivery) {
        stateLock.withLock {
            guard currentStreamID == delivery.streamID else { return }
            acknowledgedDeliveryIDs.insert(delivery.id)
            advanceAcknowledgedEventID()
        }
    }

    private func advanceAcknowledgedEventID() {
        while outstandingEventHead < outstandingDeliveries.count {
            let delivery = outstandingDeliveries[outstandingEventHead]
            guard acknowledgedDeliveryIDs.remove(delivery.id) != nil else { break }
            lastAcknowledgedEventID = max(lastAcknowledgedEventID ?? 0, delivery.eventID)
            outstandingEventHead += 1
        }
        if outstandingEventHead >= 256,
           outstandingEventHead * 2 >= outstandingDeliveries.count {
            outstandingDeliveries.removeFirst(outstandingEventHead)
            outstandingEventHead = 0
        }
    }

    func stop() {
        lifecycleLock.withLock {
            stopLocked()
        }
    }

    private func stopLocked() {
        clearState()
        guard let stream else {
            callbackContext = nil
            return
        }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        if DispatchQueue.getSpecific(key: callbackQueueKey) == nil {
            callbackQueue.sync {}
        }
        FSEventStreamRelease(stream)
        callbackContext = nil
    }

    private func clearState() {
        stateLock.withLock {
            monitoredRoots = []
            self.handler = nil
            currentStreamID = nil
            outstandingDeliveries.removeAll(keepingCapacity: true)
            outstandingEventHead = 0
            acknowledgedDeliveryIDs.removeAll(keepingCapacity: true)
        }
    }

    private static let callback: FSEventStreamCallback = {
        _, callbackInfo, eventCount, eventPaths, eventFlags, eventIDs in
        guard let callbackInfo else { return }
        let context = Unmanaged<CallbackContext>
            .fromOpaque(callbackInfo)
            .takeUnretainedValue()
        guard let monitor = context.monitor else { return }
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let count = min(Int(eventCount), paths.count)
        let events = (0..<count).map {
            FileCompressionFileEvent(path: paths[$0], flags: eventFlags[$0])
        }
        let lastEventID = count > 0 ? eventIDs[count - 1] : nil
        monitor.receive(events, lastEventID: lastEventID)
    }

    private func receive(
        _ events: [FileCompressionFileEvent],
        lastEventID: FSEventStreamEventId?
    ) {
        let deliveryID = UUID()
        let snapshot = stateLock.withLock {
            if let lastEventID {
                outstandingDeliveries.append(OutstandingDelivery(
                    id: deliveryID,
                    eventID: lastEventID
                ))
            }
            return (monitoredRoots, handler, currentStreamID)
        }
        guard let handler = snapshot.1,
              let streamID = snapshot.2,
              let lastEventID else { return }
        let batch = FileCompressionChangeBatch.from(events: events, monitoredRoots: snapshot.0)
        let delivery = FileCompressionChangeDelivery(
            id: deliveryID,
            batch: batch,
            eventID: lastEventID,
            streamID: streamID
        )
        guard !batch.changedPaths.isEmpty || !batch.rootsRequiringFullScan.isEmpty else {
            acknowledge(delivery)
            return
        }
        handler(delivery)
    }
}
    private struct OutstandingDelivery {
        let id: UUID
        let eventID: FSEventStreamEventId
    }
