import AppKit
import Darwin
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacPilot

@MainActor
struct ImageViewerPerformanceTests {
    @MainActor private struct Sample {
        let time = ProcessInfo.processInfo.systemUptime
        let cpu = Self.cpuSeconds()
        let footprint = ProcessMemorySampler.ownFootprint() ?? 0

        private static func cpuSeconds() -> Double {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }

        func report(_ stage: String, previous: Self, runtime: ImageViewerRuntime?) {
            let cpu = (self.cpu - previous.cpu) / max(0.001, time - previous.time) * 100
            print("IMAGE_VIEWER_PERF \(stage) footprint=\(footprint) cpu=\(String(format: "%.2f", cpu))% jobs=\(runtime?.taskCount ?? 0) observers=\(runtime?.session?.observerCount ?? 0) cache=\(runtime?.session?.cacheBytes ?? 0)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACPILOT_IMAGE_VIEWER_STRESS"] == "1"))
    func largeFoldersAndEightHiddenDocumentWindowsDrainTheirResources() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fiveK = folder.appendingPathComponent("image-1.jpg")
        try autoreleasepool {
            let output = try #require(CGImageDestinationCreateWithURL(fiveK as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(output, try ImageViewerFixture.bitmap(5120, 2880), nil)
            try #require(CGImageDestinationFinalize(output))
        }
        var files = [fiveK]
        for count in [100, 1000, 10_000] {
            for next in (files.count + 1)...count {
                let file = folder.appendingPathComponent("image-\(next).jpg")
                try FileManager.default.linkItem(at: fiveK, to: file)
                files.append(file)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let index = try await Task.detached {
                try ImageViewerFolderIndex.scan(folder, cancelled: { Task.isCancelled })
            }.value
            #expect(index.files.count == count)
            print("IMAGE_VIEWER_PERF index count=\(count) elapsed=\(ProcessInfo.processInfo.systemUptime - start)s")
        }

        var last = Sample()
        func sample(_ stage: String, runtime: ImageViewerRuntime? = nil) {
            let current = Sample()
            current.report(stage, previous: last, runtime: runtime)
            last = current
        }

        try await Task.sleep(for: .milliseconds(250))
        sample("disabled")
        let runtime = ImageViewerRuntime(language: .english, presentWindows: false)
        defer { runtime.close() }
        try await Task.sleep(for: .milliseconds(250))
        sample("idle", runtime: runtime)
        #expect(runtime.session == nil)
        runtime.open([fiveK])
        let first = try #require(runtime.windows.all.first)
        try await waitUntil { first.frame != nil && first.browser.index != nil }
        #expect(first.frame?.originalSize == CGSize(width: 5120, height: 2880))
        sample("first", runtime: runtime)
        for _ in 0..<100 {
            first.perform(.next)
            try await waitUntil { first.frame != nil }
        }
        #expect(first.browser.url == files[100])
        sample("browse100", runtime: runtime)
        runtime.open(Array(files[101..<108]))
        try await waitUntil { runtime.windows.all.allSatisfy { $0.frame != nil } }
        #expect(runtime.windows.all.count == 8)
        sample("eight", runtime: runtime)
        for window in runtime.windows.all { window.window?.close() }
        try await Task.sleep(for: .milliseconds(250))
        sample("closed", runtime: runtime)
        #expect(runtime.session == nil)
        #expect(runtime.windows.isEmpty)
        #expect(runtime.taskCount == 0)
        runtime.close()
        sample("stopped", runtime: runtime)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
