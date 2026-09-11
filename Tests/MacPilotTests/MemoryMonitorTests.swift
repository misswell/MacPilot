import Foundation
import Testing
@testable import MacPilot

struct MemoryMonitorTests {
    private func sample(
        _ pid: Int32,
        _ name: String,
        path: String? = nil,
        _ bytes: UInt64
    ) -> ProcessMemorySample {
        ProcessMemorySample(pid: pid, name: name, executablePath: path, footprintBytes: bytes)
    }

    @Test func bundleHelpersAndCliProcessesRollIntoOneApp() {
        let grouped = AppMemoryGrouper.group([
            sample(1, "ZCode", path: "/Applications/ZCode.app/Contents/MacOS/ZCode", 100),
            sample(
                2,
                "ZCode Helper",
                path: "/Applications/ZCode.app/Contents/Frameworks/ZCode Helper.app/Contents/MacOS/ZCode Helper",
                200
            ),
            sample(
                3,
                "ZCode Helper (Renderer)",
                path: "/Applications/ZCode.app/Contents/Frameworks/ZCode Helper (Renderer).app/Contents/MacOS/ZCode Helper (Renderer)",
                300
            ),
            sample(4, "zcode-cli", path: "/Users/dev/.zcode/cli/zcode-cli", 400),
            sample(5, "zcode-host-local-1", path: "/Users/dev/.zcode/cli/zcode-host-local-1", 500),
        ])

        #expect(grouped.count == 1)
        #expect(grouped[0].name == "ZCode")
        #expect(grouped[0].bundlePath == "/Applications/ZCode.app")
        #expect(grouped[0].processCount == 5)
        #expect(grouped[0].footprintBytes == 1500)
        // 进程明细按占用从大到小排列
        #expect(grouped[0].processes.map(\.footprintBytes) == [500, 400, 300, 200, 100])
    }

    @Test func standaloneFamilyMergesEvenWithoutRunningBundle() {
        let grouped = AppMemoryGrouper.group([
            sample(1, "zcode-cli", path: "/Users/dev/.zcode/cli/zcode-cli", 400),
            sample(2, "zcode-host-local-1", path: "/Users/dev/.zcode/cli/zcode-host-local-1", 500),
            sample(3, "zcode-node-repl-mcp", path: "/Users/dev/.zcode/cli/zcode-node-repl-mcp", 600),
        ])

        #expect(grouped.count == 1)
        #expect(grouped[0].bundlePath == nil)
        #expect(grouped[0].processCount == 3)
        // 没有应用包可依托时，用最短的成员名作为展示名
        #expect(grouped[0].name == "zcode-cli")
    }

    @Test func unrelatedLookAlikeNamesStaySeparate() {
        let grouped = AppMemoryGrouper.group([
            sample(1, "Safari", path: "/System/Applications/Safari.app/Contents/MacOS/Safari", 900),
            sample(2, "safaridriver", path: "/usr/bin/safaridriver", 50),
            sample(3, "SafariBookmarksSyncAgent", path: "/System/Library/PrivateFrameworks/SafariBookmarks.framework/safaridriver2", 30),
        ])

        #expect(grouped.count == 3)
    }

    @Test func systemProcessesAreNotFamilyMerged() {
        let grouped = AppMemoryGrouper.group([
            sample(1, "Foo", path: "/Applications/Foo.app/Contents/MacOS/Foo", 800),
            sample(2, "foo-helper", path: "/usr/libexec/foo-helper", 20),
        ])

        // 系统路径下的同名前缀进程不并入第三方应用
        #expect(grouped.count == 2)
        #expect(grouped[0].name == "Foo")
    }

    @Test func relatedUserCliToolsMergeByFamilyPrefix() {
        let grouped = AppMemoryGrouper.group([
            sample(1, "git", path: "/opt/homebrew/bin/git", 10),
            sample(2, "git-lfs", path: "/opt/homebrew/bin/git-lfs", 20),
        ])

        #expect(grouped.count == 1)
        #expect(grouped[0].name == "git")
        #expect(grouped[0].footprintBytes == 30)
    }

    @Test func groupsAreSortedByMemoryDescending() {
        let grouped = AppMemoryGrouper.group([
            sample(1, "small", path: "/Users/dev/tools/small", 10),
            sample(2, "big", path: "/Applications/Big.app/Contents/MacOS/Big", 900),
            sample(3, "medium", path: "/Users/dev/tools/medium", 100),
        ])

        #expect(grouped.map(\.name) == ["Big", "medium", "small"])
    }

    @Test func appBundlePathUsesOutermostAppBundle() {
        #expect(
            AppMemoryGrouper.appBundlePath(ofExecutable: "/Applications/ZCode.app/Contents/MacOS/ZCode")
                == "/Applications/ZCode.app"
        )
        #expect(
            AppMemoryGrouper.appBundlePath(
                ofExecutable: "/Applications/ZCode.app/Contents/Frameworks/ZCode Helper (Renderer).app/Contents/MacOS/ZCode Helper (Renderer)"
            ) == "/Applications/ZCode.app"
        )
        #expect(AppMemoryGrouper.appBundlePath(ofExecutable: "/usr/bin/zcode-cli") == nil)
        #expect(AppMemoryGrouper.appBundlePath(ofExecutable: "zcode-cli") == nil)
    }

    @Test func standaloneFamilyPrefixCutsAtSeparator() {
        #expect(AppMemoryGrouper.standaloneFamilyPrefix(of: "zcode-host-local-1") == "zcode")
        #expect(AppMemoryGrouper.standaloneFamilyPrefix(of: "zcode_host") == "zcode")
        #expect(AppMemoryGrouper.standaloneFamilyPrefix(of: "zcode cli") == "zcode")
        #expect(AppMemoryGrouper.standaloneFamilyPrefix(of: "safaridriver") == "safaridriver")
        #expect(AppMemoryGrouper.standaloneFamilyPrefix(of: "ZCode-CLI") == "zcode")
    }

    @Test func systemPathDetection() {
        #expect(AppMemoryGrouper.isSystemExecutablePath("/usr/libexec/foo-helper"))
        #expect(AppMemoryGrouper.isSystemExecutablePath("/System/Library/CoreServices/foo"))
        #expect(AppMemoryGrouper.isSystemExecutablePath("/sbin/launchd"))
        #expect(AppMemoryGrouper.isSystemExecutablePath("/private/var/db/foo"))
        #expect(!AppMemoryGrouper.isSystemExecutablePath("/Applications/Foo.app/Contents/MacOS/Foo"))
        #expect(!AppMemoryGrouper.isSystemExecutablePath("/opt/homebrew/bin/git"))
        #expect(!AppMemoryGrouper.isSystemExecutablePath("/Users/dev/.zcode/cli/zcode-cli"))
    }

    @Test func samplerReadsLiveProcessesAndSystemSnapshot() throws {
        let samples = ProcessMemorySampler.sample()
        #expect(samples.count > 10)
        #expect(samples.contains { $0.footprintBytes > 0 })

        // 自身进程应能读到可执行路径与物理占用
        let selfPID = getpid()
        let selfSample = samples.first { $0.pid == selfPID }
        #expect(selfSample != nil)
        #expect((selfSample?.footprintBytes ?? 0) > 0)
        #expect(selfSample?.executablePath != nil)

        let snapshot = try #require(SystemMemoryReader.snapshot())
        #expect(snapshot.physicalBytes == UInt64(ProcessInfo.processInfo.physicalMemory))
        #expect(snapshot.usedBytes > 0)
        #expect(snapshot.usedBytes <= snapshot.physicalBytes)
        #expect(snapshot.appBytes <= snapshot.usedBytes)
    }
}
