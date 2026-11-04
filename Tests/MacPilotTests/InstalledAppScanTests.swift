import Darwin
import Foundation
import MacPilotDockGroupsCore
import Testing

/// 安装目录扫描：只在扫描目录里留一条符号链接的 App 也必须进索引。
///
/// macOS 把 Safari 这类随封印系统卷安装的 App 放在 Cryptex，只在 `/Applications`
/// 留一条同名符号链接；`FileManager.enumerator` 不返回指向目录的符号链接，所以
/// 扫描漏掉它们时，快速搜索里输入 `saf` 连 Safari 都搜不出来。
struct InstalledAppScanTests {

    @Test func scanFindsAnApplicationThatOnlyExistsAsASymbolicLink() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let applications = root.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let sealed = root.url.appendingPathComponent("System/Applications", isDirectory: true)
        let realBundle = try makeBundle(named: "Safari", identifier: "com.example.safari", in: sealed)
        let link = applications.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: realBundle.path
        )

        let scanned = InstalledAppResolver.scanInstalledApps(in: [applications])

        #expect(scanned.map(\.name) == ["Safari"])
        // 索引里存的是用户看得见的那条路径，不是 Cryptex 的真实路径：
        // 「在 Finder 中显示」落在 /Applications 才对。
        #expect(scanned.first?.path == link.standardizedFileURL.path)
        #expect(scanned.first?.bundleIdentifier == "com.example.safari")
    }

    @Test func scanFindsASymbolicLinkApplicationThatCarriesTheHiddenFlag() throws {
        // Safari 的链接带着 `restricted,hidden`：系统故意让它在 Finder 里看不见。
        // `.skipsHiddenFiles` 会连条目一起吞掉，扫描必须按文件名的 `.` 前缀过滤。
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let applications = root.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let sealed = root.url.appendingPathComponent("System/Applications", isDirectory: true)
        let realBundle = try makeBundle(named: "Safari", identifier: "com.example.safari", in: sealed)
        let link = applications.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: realBundle.path
        )
        chflags(link.path, UInt32(UF_HIDDEN))

        let scanned = InstalledAppResolver.scanInstalledApps(in: [applications])

        #expect(scanned.map(\.name) == ["Safari"])
        #expect(scanned.first?.bundleIdentifier == "com.example.safari")
    }

    @Test func scanKeepsOneRowWhenASymbolicLinkPointsAtAnAlreadyScannedBundle() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let applications = root.url.appendingPathComponent("Applications", isDirectory: true)
        let nested = applications.appendingPathComponent("Vendor", isDirectory: true)
        let realBundle = try makeBundle(named: "VPN", identifier: "com.example.vpn", in: nested)
        let link = applications.appendingPathComponent("VPN.app")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: realBundle.path
        )

        let scanned = InstalledAppResolver.scanInstalledApps(in: [applications])

        #expect(scanned.count == 1)
        #expect(scanned.first?.bundleIdentifier == "com.example.vpn")
    }

    // MARK: - 辅助

    private func makeBundle(named name: String, identifier: String, in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>\(identifier)</string>
          <key>CFBundleName</key><string>\(name)</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        return bundle
    }
}
