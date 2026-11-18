import Foundation

@MainActor
final class ImageViewerFileRouter {
    private var pending: [URL] = []
    private var handler: (([URL]) -> Void)?

    nonisolated static func documents(in urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.filter(ImageViewerFileKind.isCandidate).map(\.standardizedFileURL)
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

    func attach(_ handler: @escaping ([URL]) -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler
        let documents = pending
        pending.removeAll()
        if !documents.isEmpty { handler(documents) }
    }
}
