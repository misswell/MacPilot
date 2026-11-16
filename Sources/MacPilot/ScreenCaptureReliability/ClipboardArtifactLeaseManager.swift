import AppKit
import Foundation

/// Tracks which capture artifacts the pasteboard still depends on.
///
/// `SmartCaptureClipboard` installs a lazy `NSPasteboardItemDataProvider`; the
/// pasteboard therefore holds *no* `.fileURL` representation, and a check that
/// only looks for `.fileURL` can never see that dependency. Every copy records
/// a lease here, tied to the pasteboard change count, so temp-file reclamation
/// can ask one authority whether a file is still referenced.
@MainActor
final class ClipboardArtifactLeaseManager {
    struct Lease: Identifiable, Equatable {
        let id: UUID
        let artifactID: UUID
        let captureID: UUID
        let url: URL
        let changeCount: Int
        let providedTypes: [String]
        let createdAt: Date
    }

    static let shared = ClipboardArtifactLeaseManager()

    private var leasesByID: [UUID: Lease] = [:]
    private var leaseIDsByArtifact: [UUID: Set<UUID>] = [:]
    private var consumersByArtifact: [UUID: Set<String>] = [:]
    private var consumersByURL: [URL: Set<String>] = [:]

    /// Last pasteboard generation this manager reconciled with.
    private(set) var lastChangeCount = -1
    /// Diagnostics counters, also used by tests.
    private(set) var releasedLeaseCount = 0
    private(set) var providerFailureCount = 0

    private init() {}

    @discardableResult
    func recordCopy(
        artifact: CaptureArtifact,
        changeCount: Int,
        providedTypes: [NSPasteboard.PasteboardType],
        now: Date = Date()
    ) -> Lease {
        synchronize(changeCount: changeCount)
        let lease = Lease(
            id: UUID(),
            artifactID: artifact.id,
            captureID: artifact.captureID,
            url: artifact.url,
            changeCount: changeCount,
            providedTypes: providedTypes.map(\.rawValue),
            createdAt: now
        )
        leasesByID[lease.id] = lease
        leaseIDsByArtifact[artifact.id, default: []].insert(lease.id)
        return lease
    }

    /// Releases every lease that belonged to an older pasteboard generation.
    /// Called both explicitly and passively before any reclamation decision.
    @discardableResult
    func synchronize(changeCount: Int) -> [Lease] {
        guard changeCount != lastChangeCount else { return [] }
        let released = Array(leasesByID.values)
        leasesByID.removeAll()
        leaseIDsByArtifact.removeAll()
        lastChangeCount = changeCount
        releasedLeaseCount += released.count
        return released
    }

    func synchronizeWithGeneralPasteboard() {
        synchronize(changeCount: NSPasteboard.general.changeCount)
    }

    func retain(artifactID: UUID, consumer: String) {
        consumersByArtifact[artifactID, default: []].insert(consumer)
    }

    func release(artifactID: UUID, consumer: String) {
        consumersByArtifact[artifactID]?.remove(consumer)
        if consumersByArtifact[artifactID]?.isEmpty == true {
            consumersByArtifact[artifactID] = nil
        }
    }

    /// Consumers that only know a file path (annotation editors, Quick Access
    /// save flows) hold it by URL; both forms answer the reclamation question.
    func retain(url: URL, consumer: String) {
        consumersByURL[url.standardizedFileURL, default: []].insert(consumer)
    }

    func release(url: URL, consumer: String) {
        let key = url.standardizedFileURL
        consumersByURL[key]?.remove(consumer)
        if consumersByURL[key]?.isEmpty == true {
            consumersByURL[key] = nil
        }
    }

    func lease(for artifactID: UUID) -> Lease? {
        leasesByID.values.first { $0.artifactID == artifactID }
    }

    func isReferencedByPasteboard(artifactID: UUID) -> Bool {
        !(leaseIDsByArtifact[artifactID]?.isEmpty ?? true)
    }

    func isReferencedByPasteboard(url: URL) -> Bool {
        let key = url.standardizedFileURL
        return leasesByID.values.contains { $0.url.standardizedFileURL == key }
    }

    var activeLeaseCount: Int { leasesByID.count }

    /// A temp file may be reclaimed only when neither the pasteboard nor any
    /// named consumer still holds it.
    func canReclaim(artifactID: UUID) -> Bool {
        guard !isReferencedByPasteboard(artifactID: artifactID) else { return false }
        guard consumersByArtifact[artifactID]?.isEmpty ?? true else { return false }
        let leaseURLs = leaseIDsByArtifact[artifactID]?.compactMap { leasesByID[$0]?.url.standardizedFileURL } ?? []
        return leaseURLs.allSatisfy { consumersByURL[$0]?.isEmpty ?? true }
    }

    func canReclaim(url: URL) -> Bool {
        let key = url.standardizedFileURL
        guard !isReferencedByPasteboard(url: key) else { return false }
        return consumersByURL[key]?.isEmpty ?? true
    }

    func providerDidFail(leaseID: UUID, error: Error) {
        providerFailureCount += 1
        let lease = leasesByID[leaseID]
        DiagnosticLogger.shared.logError(
            .fileAccess,
            error,
            "Clipboard image provider could not read its source file",
            context: [
                "leaseId": leaseID.uuidString,
                "fileName": lease?.url.lastPathComponent ?? "unknown",
            ]
        )
    }

    func providerDidFail(artifactID: UUID, error: Error) {
        providerFailureCount += 1
        let lease = leaseIDsByArtifact[artifactID]?.compactMap { leasesByID[$0] }.first
        DiagnosticLogger.shared.logError(
            .fileAccess,
            error,
            "Clipboard image provider could not read its source file",
            context: [
                "artifactId": artifactID.uuidString,
                "fileName": lease?.url.lastPathComponent ?? "unknown",
            ]
        )
    }

    /// Test seam: forget every lease and consumer without touching the pasteboard.
    func resetForTesting() {
        leasesByID.removeAll()
        leaseIDsByArtifact.removeAll()
        consumersByArtifact.removeAll()
        consumersByURL.removeAll()
        lastChangeCount = -1
        releasedLeaseCount = 0
        providerFailureCount = 0
    }
}
