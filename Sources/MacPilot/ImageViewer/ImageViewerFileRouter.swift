import Foundation

@MainActor
final class ImageViewerFileRouter {
    private var pending: [URL] = []
    private var handler: (([URL]) -> Void)?
    private var deliveriesInProgress = 0
    var hasPendingDocuments: Bool { !pending.isEmpty }
    var hasOutstandingDocuments: Bool { hasPendingDocuments || deliveriesInProgress > 0 }

    nonisolated static func documents(in urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.filter {
            guard ImageViewerFileKind.isCandidate($0) else { return false }
            if $0.pathExtension.lowercased() == "sketch" { return true }
            if $0.hasDirectoryPath { return false }
            return (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }.map(\.standardizedFileURL)
            .filter { seen.insert($0).inserted }
    }

    @discardableResult
    func receive(_ urls: [URL]) -> Bool {
        let documents = Self.documents(in: urls)
        guard !documents.isEmpty else { return false }
        if let handler { handler(documents) }
        else { pending = Self.documents(in: pending + documents) }
        return true
    }

    func attach(
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { $0() },
        _ handler: @escaping ([URL]) -> Void
    ) {
        guard self.handler == nil else { return }
        let deliver: ([URL]) -> Void = { [weak self] documents in
            guard let self else { return }
            self.deliveriesInProgress += 1
            schedule { [weak self] in
                defer { self?.deliveriesInProgress -= 1 }
                handler(documents)
            }
        }
        self.handler = deliver
        let documents = pending
        pending.removeAll()
        if !documents.isEmpty { deliver(documents) }
    }
}
