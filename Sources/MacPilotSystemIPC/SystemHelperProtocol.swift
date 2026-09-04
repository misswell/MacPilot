import Foundation
import Security

// MARK: - 共享的 Helper 身份与 XPC 协议
//
// 该 target 同时被主程序与 root Helper 链接，集中定义：
//  - Helper 的 binary / plist / mach service 命名规则
//  - 双向代码签名验证 requirement
//  - 唯一允许 Helper 执行的固定命令
//
// Helper 永远不能成为通用 root command executor，因此本文件刻意
// 不提供任何接受外部命令、脚本或参数的接口。

/// Bundle-program（无 Info.plist）二进制无法从 `Bundle.main` 读取自身身份，
/// 因此 helper 进程从同级 LaunchDaemon plist 反查 Label，回退到默认值。
public enum SystemHelperLaunchdConfig {
    /// 从 Helper 可执行文件所在路径定位打包后的
    /// `Contents/Library/LaunchDaemons/<plistName>` 并返回其 `Label`。
    public static func packagedLabel(executablePath: String?, bundleURL: URL?) -> String? {
        guard let launchDaemonsDirectory = launchDaemonsDirectory(
            executablePath: executablePath,
            bundleURL: bundleURL
        ) else { return nil }
        let plistURL = launchDaemonsDirectory
            .appendingPathComponent(SystemHelperIdentity.plistName)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let label = plist["Label"] as? String
        else { return nil }
        return label
    }

    /// Helper 进程要监听的 mach service 名称。
    public static func helperMachServiceName(
        executablePath: String? = CommandLine.arguments.first,
        bundleURL: URL? = Bundle.main.bundleURL
    ) -> String {
        packagedLabel(executablePath: executablePath, bundleURL: bundleURL)
            ?? SystemHelperIdentity.serviceName(
                forBundleIdentifier: SystemHelperIdentity.defaultBundleIdentifier
            )
    }

    private static func launchDaemonsDirectory(executablePath: String?, bundleURL: URL?) -> URL? {
        if let executablePath {
            let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            // <App>.app/Contents/Resources/<helper> → <App>.app/Contents
            let resourcesDirectory = executableURL.deletingLastPathComponent()
            if resourcesDirectory.lastPathComponent == "Resources" {
                let contentsDirectory = resourcesDirectory.deletingLastPathComponent()
                if contentsDirectory.lastPathComponent == "Contents",
                   contentsDirectory.deletingLastPathComponent().pathExtension == "app" {
                    return contentsDirectory
                        .appendingPathComponent("Library", isDirectory: true)
                        .appendingPathComponent("LaunchDaemons", isDirectory: true)
                }
            }
        }
        guard let bundleURL, bundleURL.pathExtension == "app" else { return nil }
        return bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchDaemons", isDirectory: true)
    }
}

/// Helper 的命名规则。Label / mach service 名由主 bundle identifier 加固定
/// 后缀派生，保证 MacPilot 与 OctoPilot bridge 构建互不冲突。
public enum SystemHelperIdentity {
    public static let defaultBundleIdentifier = "com.misswell.macpilot"
    /// Helper 可执行文件在 `Contents/Resources` 中的文件名。
    public static let executableName = "MacPilotSystemHelper"
    /// LaunchDaemon plist 在 `Contents/Library/LaunchDaemons` 中的文件名。
    public static let plistName = "MacPilotSystemHelper.plist"
    /// 追加在 bundle identifier 之后的 launchd Label 后缀。
    public static let serviceSuffix = "system-helper"

    public static func serviceName(forBundleIdentifier bundleIdentifier: String) -> String {
        "\(bundleIdentifier).\(serviceSuffix)"
    }

    /// 主程序运行时使用的 mach service 名称。
    public static var runtimeServiceName: String {
        serviceName(
            forBundleIdentifier: Bundle.main.bundleIdentifier ?? defaultBundleIdentifier
        )
    }
}

/// Helper 唯一允许执行的命令：`/bin/launchctl reboot userspace`。
/// 两个值都固定在编译期，UI 与 XPC 无法注入任何参数。
public enum SystemHelperRebootCommand {
    public static let executablePath = "/bin/launchctl"
    public static let arguments = ["reboot", "userspace"]
}

/// Helper 拒绝软重启请求时返回的错误码。
public enum SystemHelperRebootError: String {
    case alreadyScheduled
    case notRunningAsRoot
    case unknown
}

/// 保证每个 Helper 进程生命周期内只调度一次 userspace reboot，
/// 防止连续点击或重复 XPC 请求叠加多次重启。
public final class UserspaceRebootGate: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false

    public init() {}

    /// 只有第一次调用返回 true，之后直到进程退出都返回 false。
    public func tryScheduleReboot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if scheduled { return false }
        scheduled = true
        return true
    }
}

/// root Helper 对外暴露的最小 XPC 接口。
/// 刻意保持极小：没有 execute(command:)、runShell(script:) 之类的通用入口。
@objc public protocol MacPilotSystemHelperProtocol {
    /// 连通性探测，主程序用于确认 Helper 可达。
    func ping(withReply reply: @escaping (Bool) -> Void)

    /// 请求执行固定的 `/bin/launchctl reboot userspace`。
    /// Helper 会先回复（成功后约 0.5 秒才真正执行重启，因为重启会销毁
    /// 包括本连接在内的整个 user space）。`reply(false, errorCode)` 表示
    /// 拒绝执行，errorCode 为 `SystemHelperRebootError.rawValue`。
    func requestUserspaceReboot(withReply reply: @escaping (Bool, String?) -> Void)
}

/// XPC 双向代码签名验证。生产构建（Developer ID）要求 anchor apple generic
/// 加 Team ID；ad-hoc 本地构建没有 Team ID，退化为仅锁定 identifier。
public enum SystemHelperSigning {
    public static let productionTeamIdentifier = "U8U443D7ZL"
    /// 允许连接 Helper 的主程序 bundle identifier（含 OctoPilot bridge）。
    public static let allowedClientBundleIdentifiers = [
        "com.misswell.macpilot",
        "com.misswell.octopilot"
    ]

    /// Helper 侧对连接进来的主程序施加的 requirement。
    public static func clientRequirement(teamIdentifier: String?) -> String {
        let identifierClause: String
        if allowedClientBundleIdentifiers.count == 1 {
            identifierClause = "identifier \"\(allowedClientBundleIdentifiers[0])\""
        } else {
            identifierClause = "("
                + allowedClientBundleIdentifiers
                    .map { "identifier \"\($0)\"" }
                    .joined(separator: " or ")
                + ")"
        }
        return requirementString(identifierClause: identifierClause, teamIdentifier: teamIdentifier)
    }

    /// 主程序侧对特权 Helper 施加的 requirement。
    public static func helperRequirement(helperServiceName: String, teamIdentifier: String?) -> String {
        requirementString(
            identifierClause: "identifier \"\(helperServiceName)\"",
            teamIdentifier: teamIdentifier
        )
    }

    public static func clientRequirementForCurrentProcess() -> String {
        clientRequirement(teamIdentifier: currentTeamIdentifier())
    }

    public static func helperRequirementForCurrentProcess(helperServiceName: String) -> String {
        helperRequirement(
            helperServiceName: helperServiceName,
            teamIdentifier: currentTeamIdentifier()
        )
    }

    /// 当前进程自身代码签名的 Team Identifier；ad-hoc 签名时为 nil。
    public static func currentTeamIdentifier() -> String? {
        var codeReference: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &codeReference) == errSecSuccess,
              let code = codeReference
        else { return nil }
        var staticCodeReference: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCodeReference) == errSecSuccess,
              let staticCode = staticCodeReference
        else { return nil }
        // kSecCSSigningInformation（SDK 头文件中为匿名 CF_ENUM，未挂到
        // SecCSFlags 类型上）。
        let signingInformationFlags = SecCSFlags(
            rawValue: SecCSFlags.RawValue(kSecCSSigningInformation)
        )
        var informationReference: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            signingInformationFlags,
            &informationReference
        ) == errSecSuccess,
              let information = informationReference as NSDictionary?
        else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func requirementString(identifierClause: String, teamIdentifier: String?) -> String {
        var clauses = [identifierClause]
        if let teamIdentifier, !teamIdentifier.isEmpty {
            clauses.append("anchor apple generic")
            clauses.append("certificate leaf[subject.OU] = \"\(teamIdentifier)\"")
        }
        return clauses.joined(separator: " and ")
    }
}
