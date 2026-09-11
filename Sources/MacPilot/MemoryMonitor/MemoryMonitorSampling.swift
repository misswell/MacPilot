import Darwin
import Foundation

/// 进程内存采样：通过 libproc 读取全部进程的物理占用。
/// 读取不到占用（如其他用户或 root 进程）的进程会被跳过。
enum ProcessMemorySampler {
    static func sample() -> [ProcessMemorySample] {
        let entries = processEntries()
        var samples: [ProcessMemorySample] = []
        samples.reserveCapacity(entries.count)
        for entry in entries {
            let pid = entry.kp_proc.p_pid
            guard pid > 0, let footprint = physicalFootprint(of: pid) else { continue }
            let path = executablePath(of: pid)
            let name = path.map { ($0 as NSString).lastPathComponent } ?? commandName(of: entry)
            samples.append(
                ProcessMemorySample(
                    pid: pid,
                    name: name.isEmpty ? "\(pid)" : name,
                    executablePath: path,
                    footprintBytes: footprint,
                    startedAt: Self.date(from: entry.kp_proc.p_starttime)
                )
            )
        }
        return samples
    }

    /// 一次 sysctl 拿到全部进程的 pid、命令名与启动时间。
    /// 两次调用之间进程数可能增长，缓冲区按 10% 余量放大。
    private static func processEntries() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let entryStride = MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / entryStride + 16)
        var actualSize = entries.count * entryStride
        guard sysctl(&mib, 4, &entries, &actualSize, nil, 0) == 0, actualSize > 0 else { return [] }
        return Array(entries.prefix(actualSize / entryStride))
    }

    private static func date(from timeval: timeval) -> Date? {
        guard timeval.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timeval.tv_sec) + TimeInterval(timeval.tv_usec) / 1_000_000)
    }

    /// libproc 的路径缓冲区上限（libproc.h: PROC_PIDPATHINFO_MAXSIZE）。
    private static let maxProcessPathLength = 4 * 1024

    /// 读取 phys footprint，即活动监视器「内存」列展示的数值。
    /// proc_pid_rusage 会把完整的 rusage_info_current 结构拷贝进参数指向的
    /// 缓冲区，因此这里必须提供一块该结构大小的内存，而不是指针槽位。
    /// rusage 结构为版本化布局，只会向后追加字段，因此按 v3 读取安全。
    private static func physicalFootprint(of pid: pid_t) -> UInt64? {
        let byteCount = MemoryLayout<rusage_info_current>.stride
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<rusage_info_current>.alignment
        )
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let slot = buffer.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        let result = proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, slot)
        guard result == 0 else { return nil }
        return buffer.assumingMemoryBound(to: rusage_info_v3.self).pointee.ri_phys_footprint
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: maxProcessPathLength)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return string(fromNullTerminated: buffer)
    }

    private static func commandName(of entry: kinfo_proc) -> String {
        withUnsafeBytes(of: entry.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func string(fromNullTerminated buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

struct SystemMemorySnapshot: Equatable, Sendable {
    enum PressureLevel: Int, Equatable, Sendable {
        case normal = 1
        case warning = 2
        case critical = 3

        var labelKey: String {
            switch self {
            case .normal: "pressureNormal"
            case .warning: "pressureWarning"
            case .critical: "pressureCritical"
            }
        }
    }

    let physicalBytes: UInt64
    let usedBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cachedFilesBytes: UInt64
    let swapUsedBytes: UInt64
    let pressure: PressureLevel
    /// 系统开机时间（now − uptime）。
    let bootDate: Date
    /// 本次开机已运行的秒数。
    let uptimeInterval: TimeInterval
}

/// 系统级内存统计，口径对齐活动监视器：
/// 已使用 = App（internal − purgeable）+ 联机 + 已压缩（compressor）；
/// 已缓存文件 = external + speculative。
enum SystemMemoryReader {
    static func snapshot() -> SystemMemorySnapshot? {
        guard let vm = vmStatistics64(), let physicalBytes = totalPhysicalBytes() else { return nil }
        let pageSize = vm.pageSize
        let appBytes = vm.internalPages > vm.purgeablePages
            ? (vm.internalPages - vm.purgeablePages) * pageSize
            : 0
        let wiredBytes = vm.wiredPages * pageSize
        let compressedBytes = vm.compressedPages * pageSize
        let cachedFilesBytes = (vm.externalPages + vm.speculativePages) * pageSize
        let usedBytes = appBytes + wiredBytes + compressedBytes
        let uptime = ProcessInfo.processInfo.systemUptime
        return SystemMemorySnapshot(
            physicalBytes: physicalBytes,
            usedBytes: usedBytes,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedFilesBytes: cachedFilesBytes,
            swapUsedBytes: swapUsedBytes(),
            pressure: memoryPressure(usedBytes: usedBytes, physicalBytes: physicalBytes),
            bootDate: Date().addingTimeInterval(-uptime),
            uptimeInterval: uptime
        )
    }

    private struct VMStats {
        let pageSize: UInt64
        let internalPages: UInt64
        let externalPages: UInt64
        let purgeablePages: UInt64
        let compressedPages: UInt64
        let wiredPages: UInt64
        let speculativePages: UInt64
    }

    private static func vmStatistics64() -> VMStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            UInt32(MemoryLayout<vm_statistics64>.size) / UInt32(MemoryLayout<integer_t>.size)
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        return VMStats(
            pageSize: UInt64(pageSize),
            internalPages: UInt64(stats.internal_page_count),
            externalPages: UInt64(stats.external_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            compressedPages: UInt64(stats.compressor_page_count),
            wiredPages: UInt64(stats.wire_count),
            speculativePages: UInt64(stats.speculative_count)
        )
    }

    private static func totalPhysicalBytes() -> UInt64? {
        var info = host_basic_info()
        var count = mach_msg_type_number_t(
            UInt32(MemoryLayout<host_basic_info>.size) / UInt32(MemoryLayout<integer_t>.size)
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_info(mach_host_self(), HOST_BASIC_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.max_mem
    }

    private static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            sysctlbyname("vm.swapusage", pointer, &size, nil, 0)
        }
        guard result == 0 else { return 0 }
        return usage.xsu_used
    }

    private static func memoryPressure(
        usedBytes: UInt64,
        physicalBytes: UInt64
    ) -> SystemMemorySnapshot.PressureLevel {
        if let level = systemPressureLevel() { return level }
        guard physicalBytes > 0 else { return .normal }
        let ratio = Double(usedBytes) / Double(physicalBytes)
        if ratio >= 0.92 { return .critical }
        if ratio >= 0.8 { return .warning }
        return .normal
    }

    /// 系统内存压力等级（1 正常 / 2 警告 / 3 严重）；读取失败时由比例估算兜底。
    private static func systemPressureLevel() -> SystemMemorySnapshot.PressureLevel? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard result == 0 else { return nil }
        return SystemMemorySnapshot.PressureLevel(rawValue: Int(level))
    }
}
