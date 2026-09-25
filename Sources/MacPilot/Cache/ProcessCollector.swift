import Foundation

/// Shares one process inventory across CPU and memory samplers opened together.
/// Resource counters are still read independently for each monitor.
final class ProcessCollector: @unchecked Sendable {
    static let shared = ProcessCollector()

    private let lock = NSLock()
    private let reader: @Sendable () -> [RunningProcessInfo]
    private var cached: (sampledAt: TimeInterval, processes: [RunningProcessInfo])?

    init(reader: @escaping @Sendable () -> [RunningProcessInfo] = RunningProcessReader.sample) {
        self.reader = reader
    }

    func sample(maxAge: TimeInterval = 0.5) -> [RunningProcessInfo] {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.sampledAt < maxAge {
            return cached.processes
        }
        let processes = reader()
        cached = (now, processes)
        return processes
    }

    func clear() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
