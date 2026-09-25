import Foundation

/// Coalesces complete configuration snapshots before touching disk. The
/// existing config.json schema stays readable by older installations.
@MainActor
final class ConfigStore {
    private let url: URL
    private let writeQueue = DispatchQueue(label: "com.misswell.macpilot.configuration-write", qos: .utility)
    private var lastQueuedData: Data?
    private var pendingData: Data?
    private var pendingTask: Task<Void, Never>?
    var onError: ((Error) -> Void)?

    init(url: URL) {
        self.url = url
        lastQueuedData = try? Data(contentsOf: url)
    }

    var isDirty: Bool { pendingData != nil }

    func markDirty(_ data: Data) {
        if pendingData == data || (pendingData == nil && lastQueuedData == data) { return }
        pendingData = data
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            self?.flush()
        }
    }

    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let data = pendingData else { return }
        pendingData = nil
        lastQueuedData = data
        let url = url
        writeQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastQueuedData = nil
                    self?.onError?(error)
                }
            }
        }
    }

    /// App termination is synchronous; drain a pending snapshot before exit.
    func finish() {
        flush()
        writeQueue.sync {}
    }
}
