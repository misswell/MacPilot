import Darwin
import Foundation
import ImageIO

final class ImageViewerSketchPreview: @unchecked Sendable {
    private let cacheLock = NSLock()
    private var cache = ImageViewerCache<ImageViewerFileStamp, Data>(limit: 16 << 20, countLimit: 8)
    private var revision = 0
    private var closed = false

    var cost: Int { cacheLock.withLock { cache.cost } }

    func clear(closing: Bool = false) {
        cacheLock.withLock {
            revision += 1
            closed = closed || closing
            cache.clear()
        }
    }

    func data(for url: URL, cancelled: () -> Bool) -> Data? {
        guard !cancelled() else { return nil }
        let stamp = ImageViewerFileStamp(url)
        let (active, generation, existing) = cacheLock.withLock {
            (!closed, revision, stamp.flatMap { cache.value(for: $0) })
        }
        guard active else { return nil }
        if let existing { return existing }
        let deadline = DispatchTime.now() + .seconds(4)
        for name in ["preview.png", "preview.jpg", "preview.jpeg"] {
            guard !cancelled(), DispatchTime.now() < deadline else { return nil }
            let data: Data?
            if let stamp {
                guard stamp.size > 0, stamp.size <= ImageViewerPipeline.sourceByteLimit else { return nil }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-p", url.path, "previews/\(name)"]
                data = Self.boundedOutput(process, deadline: deadline, cancelled: cancelled)
            } else {
                data = Self.packageEntry(name, in: url, deadline: deadline, cancelled: cancelled)
            }
            guard let data, CGImageSourceCreateWithData(data as CFData, nil) != nil, !cancelled() else { continue }
            if let stamp {
                cacheLock.withLock {
                    if revision == generation { cache.insert(data, for: stamp, cost: data.count) }
                }
            }
            return data
        }
        return nil
    }

    private static func packageEntry(_ name: String, in url: URL, deadline: DispatchTime,
                                     cancelled: () -> Bool) -> Data? {
        let root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return nil }
        defer { close(root) }
        let directory = openat(root, "previews", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (1...Int64(64 << 20)).contains(info.st_size) else { return nil }
        return boundedRead(descriptor, deadline: deadline, cancelled: cancelled)
    }

    static func boundedOutput(_ process: Process, byteLimit: Int = 64 << 20, deadline: DispatchTime,
                              cancelled: () -> Bool) -> Data? {
        guard !cancelled(), DispatchTime.now() < deadline else { return nil }
        let output = Pipe()
        let termination = DispatchSemaphore(value: 0)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in termination.signal() }
        defer {
            if process.isRunning {
                process.terminate()
                if termination.wait(timeout: .now() + .milliseconds(250)) != .success, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = termination.wait(timeout: .now() + .seconds(1))
                }
            }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return nil }
        do { try process.run() } catch { return nil }
        try? output.fileHandleForWriting.close()
        guard let data = boundedRead(descriptor, byteLimit: byteLimit, deadline: deadline, cancelled: cancelled) else { return nil }
        while process.isRunning, !cancelled(), DispatchTime.now() < deadline {
            if termination.wait(timeout: .now() + .milliseconds(20)) == .success { break }
        }
        return !cancelled() && !process.isRunning && process.terminationStatus == 0 ? data : nil
    }

    private static func boundedRead(_ descriptor: Int32, byteLimit: Int = 64 << 20, deadline: DispatchTime,
                                    cancelled: () -> Bool) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32 << 10)
        while !cancelled(), DispatchTime.now() < deadline {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard count <= byteLimit - data.count else { return nil }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno == EAGAIN {
                var status = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&status, 1, 20)
            } else if errno != EINTR {
                return nil
            }
        }
        return nil
    }
}
