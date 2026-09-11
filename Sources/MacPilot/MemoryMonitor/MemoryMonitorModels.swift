import Foundation

/// 单个进程的内存采样。数值与活动监视器「内存」列同源，取物理占用（phys footprint）。
struct ProcessMemorySample: Identifiable, Equatable, Sendable {
    let pid: pid_t
    let name: String
    let executablePath: String?
    let footprintBytes: UInt64

    var id: Int32 { pid }
}

/// 按软件维度聚合后的内存占用：同一应用的 Helper、XPC、CLI 子进程会合并到一条。
struct AppMemoryUsage: Identifiable, Equatable, Sendable {
    let familyKey: String
    let name: String
    let bundlePath: String?
    let footprintBytes: UInt64
    let processes: [ProcessMemorySample]

    var id: String { familyKey }
    var processCount: Int { processes.count }
}

/// 把分散的进程聚合到「软件」维度的纯逻辑，独立于采样便于测试。
enum AppMemoryGrouper {
    /// 聚合并按总内存从大到小排序。
    static func group(_ samples: [ProcessMemorySample]) -> [AppMemoryUsage] {
        struct Member {
            var sample: ProcessMemorySample
            var bundlePath: String?
            var bundleName: String?
        }

        // 第一遍：应用包进程按包名锚定家族，其余进程先收集为独立成员。
        var bundleEntries: [String: (anchor: (path: String, name: String), samples: [ProcessMemorySample])] = [:]
        var standalone: [ProcessMemorySample] = []
        for sample in samples {
            if let path = sample.executablePath, let bundlePath = appBundlePath(ofExecutable: path) {
                let name = displayName(ofBundlePath: bundlePath)
                let key = name.lowercased()
                if bundleEntries[key] == nil {
                    bundleEntries[key] = (anchor: (path: bundlePath, name: name), samples: [])
                }
                bundleEntries[key]?.samples.append(sample)
            } else {
                standalone.append(sample)
            }
        }

        var families: [String: [Member]] = [:]
        for (key, entry) in bundleEntries {
            families[key] = entry.samples.map {
                Member(sample: $0, bundlePath: entry.anchor.path, bundleName: entry.anchor.name)
            }
        }

        // 第二遍：独立进程优先按「路径中出现主应用同名目录」归入该应用
        // （如 <App>/runtime/node 这类包外运行时辅助进程），否则按名称家族
        // 归组。系统路径进程不参与该匹配，避免被误并进第三方应用。
        for sample in standalone {
            var matchedAnchor: (path: String, name: String)?
            if let path = sample.executablePath, !isSystemExecutablePath(path) {
                matchedAnchor = bundleEntries.values
                    .filter { pathContainsAppName(path, appName: $0.anchor.name) }
                    .max { $0.anchor.name.count < $1.anchor.name.count }?
                    .anchor
            }
            if let anchor = matchedAnchor {
                families[anchor.name.lowercased(), default: []].append(
                    Member(sample: sample, bundlePath: anchor.path, bundleName: anchor.name)
                )
            } else {
                let key = familyKey(of: sample)
                families[key, default: []].append(Member(sample: sample, bundlePath: nil, bundleName: nil))
            }
        }

        let usages = families.map { key, members -> AppMemoryUsage in
            let processes = members
                .map(\.sample)
                .sorted { $0.footprintBytes > $1.footprintBytes }
            let total = processes.reduce(0) { $0 + $1.footprintBytes }
            // 有应用包的成员决定展示名与图标；纯 CLI 家族使用最短的成员名。
            let primaryBundle = members
                .compactMap { member -> (path: String, name: String, bytes: UInt64)? in
                    guard let path = member.bundlePath, let name = member.bundleName else { return nil }
                    return (path, name, member.sample.footprintBytes)
                }
                .max { $0.bytes < $1.bytes }
            if let primaryBundle {
                return AppMemoryUsage(
                    familyKey: key,
                    name: primaryBundle.name,
                    bundlePath: primaryBundle.path,
                    footprintBytes: total,
                    processes: processes
                )
            }
            let shortestName = members
                .map(\.sample.name)
                .min { ($0.count, $0) < ($1.count, $1) } ?? key
            return AppMemoryUsage(
                familyKey: key,
                name: shortestName,
                bundlePath: nil,
                footprintBytes: total,
                processes: processes
            )
        }
        return usages.sorted { $0.footprintBytes > $1.footprintBytes }
    }

    /// 可执行文件所在的应用包路径。取路径上第一个 `.app` 组件，
    /// 这样 Helper（可能自带嵌套 `.app`）会归入外层主应用。
    static func appBundlePath(ofExecutable path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 1 else { return nil }
        for index in components.indices.dropLast() where components[index].lowercased().hasSuffix(".app") {
            // 首个组件是路径开头的空串，join 后已带前导斜杠
            return components[0...index].joined(separator: "/")
        }
        return nil
    }

    static func displayName(ofBundlePath path: String) -> String {
        let base = (path as NSString).lastPathComponent
        guard base.lowercased().hasSuffix(".app") else { return base }
        return String(base.dropLast(4))
    }

    /// 独立可执行文件按「首个分隔符之前的部分」归入同一家族，
    /// 例如 zcode-cli、zcode-host-local-1 都属于 zcode 家族。
    static func standaloneFamilyPrefix(of name: String) -> String {
        let separators: Set<Character> = ["-", "_", " "]
        if let index = name.firstIndex(where: { separators.contains($0) }) {
            return String(name[..<index]).lowercased()
        }
        return name.lowercased()
    }

    /// 独立进程的路径中出现与主应用同名（或以其加空格/连字符/下划线开头）
    /// 的目录时，视为该应用的附属进程，如 <App>/runtime/node。
    static func pathContainsAppName(_ path: String, appName: String) -> Bool {
        let target = appName.lowercased()
        guard !target.isEmpty else { return false }
        return path.split(separator: "/").contains { component in
            let lowered = component.lowercased()
            return lowered == target
                || lowered.hasPrefix(target + " ")
                || lowered.hasPrefix(target + "-")
                || lowered.hasPrefix(target + "_")
        }
    }

    /// 系统自带进程不参与家族归并，避免把无关系统组件聚到一起。
    static func isSystemExecutablePath(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/")
            || path.hasPrefix("/sbin/") || path.hasPrefix("/private/")
    }

    private static func familyKey(of sample: ProcessMemorySample) -> String {
        if let path = sample.executablePath, isSystemExecutablePath(path) {
            return sample.name.lowercased()
        }
        return standaloneFamilyPrefix(of: sample.name)
    }
}

enum MemoryByteFormatter {
    // ByteCountFormatter 实例配置后不再修改，仅从主线程读取。
    nonisolated(unsafe) private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    static func string(fromBytes bytes: UInt64) -> String {
        formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
