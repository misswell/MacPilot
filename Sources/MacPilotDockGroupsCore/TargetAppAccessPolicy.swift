//
//  TargetAppAccessPolicy.swift
//  MacPilotDockGroupsCore
//
//  需求第 2、3、20、23、26 节：
//
//  MacPilot 对第三方 App **只读**。本文件是这条原则的代码化表达：
//  任何 Service 想要对非 MacPilot 管理的路径执行
//  write / modify / replace / sign / patch / inject，都会被拒绝。
//
//  允许的读取范围（需求第 2 节）：
//  Bundle URL、Bundle Identifier、App Name、App Icon、Version、
//  Executable URL、Running State。
//

import Foundation

public enum TargetAppAccessPolicy {
    /// 需求第 23 节建议的常量：策略恒为只读。
    public static let readOnly = true

    /// 一次操作需要的权限级别。
    public enum Capability: String, CaseIterable, Sendable {
        case read
        case write
        case modify
        case replace
        case sign
        case patch
        case inject
        case launch
        case activate

        /// 只有 read / launch / activate 是允许对第三方 App 执行的动作。
        public var isAllowedOnTargetApps: Bool {
            switch self {
            case .read, .launch, .activate: true
            case .write, .modify, .replace, .sign, .patch, .inject: false
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        /// 目标是 MacPilot 自己生成/管理的内容，可以写入。
        case allowedManagedArtifact
        /// 读 / 启动 / 激活第三方 App，允许。
        case allowedReadOrLaunch
        /// 违反只读原则，拒绝。
        case deniedReadOnlyPolicy(capability: Capability)

        public var isAllowed: Bool {
            switch self {
            case .allowedManagedArtifact, .allowedReadOrLaunch: true
            case .deniedReadOnlyPolicy: false
            }
        }

        /// 被拒绝时给日志/测试使用的说明。
        public var denialReason: String? {
            guard case let .deniedReadOnlyPolicy(capability) = self else { return nil }
            return "MacPilot never \(capability.rawValue)s third-party apps (Dock Groups is read-only)."
        }
    }

    /// 判定某次操作是否允许。
    ///
    /// - Parameters:
    ///   - capability: 需要的权限。
    ///   - url: 目标路径。
    ///   - managedRoot: MacPilot 自己的管理根目录（Helper / 配置 / 缓存）。
    public static func decide(_ capability: Capability, for url: URL, managedRoot: URL) -> Decision {
        if capability == .read { return .allowedReadOrLaunch }
        if ManagedPathGuard.isManaged(url, root: managedRoot) {
            return .allowedManagedArtifact
        }
        if capability.isAllowedOnTargetApps {
            return .allowedReadOrLaunch
        }
        return .deniedReadOnlyPolicy(capability: capability)
    }

    public enum AccessError: Error, Equatable, LocalizedError {
        case denied(capability: Capability, path: String)

        public var errorDescription: String? {
            switch self {
            case let .denied(capability, path):
                return "MacPilot refuses to \(capability.rawValue) \(path): Dock Groups never modifies third-party apps."
            }
        }
    }

    /// 需要写入权限的调用点统一走这里：要么落在管理目录内，要么抛错。
    public static func requireWrite(_ capability: Capability, at url: URL, managedRoot: URL) throws {
        switch decide(capability, for: url, managedRoot: managedRoot) {
        case .allowedManagedArtifact:
            return
        case .allowedReadOrLaunch, .deniedReadOnlyPolicy:
            throw AccessError.denied(capability: capability, path: url.path)
        }
    }
}

/// 需求第 29/30 节的完整性快照：只读地记录第三方 App 的身份信息，
/// 用于测试断言「操作前后完全一致」。
public struct ThirdPartyAppIntegrity: Equatable, Sendable {
    public struct SignatureInfo: Equatable, Sendable {
        public var identifier: String?
        public var teamIdentifier: String?
        public var cdHash: String?
        public var isValid: Bool
        /// 需求第 30 节：Entitlements 也要参与比对。
        /// 用「键=值」的排序字符串数组表示，避免字典比较的不确定性。
        public var entitlements: [String]
        /// Hardened Runtime 标志位；被重新签名过的 App 在这里会变化。
        public var hasHardenedRuntime: Bool
    }

    public var bundlePath: String
    public var bundleIdentifier: String?
    public var modificationDate: Date?
    public var directoryEntryNames: [String]
    /// 主可执行文件 SHA-256。
    public var executableSHA256: String?
    /// Info.plist SHA-256。
    public var infoPlistSHA256: String?
    public var codeSignature: SignatureInfo

    /// 需求第 30 节：`before == after` 才算通过。
    /// 逐字段给出差异，便于测试失败时定位。
    public func differences(from other: ThirdPartyAppIntegrity) -> [String] {
        var result: [String] = []
        if bundlePath != other.bundlePath { result.append("bundlePath") }
        if bundleIdentifier != other.bundleIdentifier { result.append("bundleIdentifier") }
        if modificationDate != other.modificationDate { result.append("modificationDate") }
        if directoryEntryNames != other.directoryEntryNames { result.append("directoryEntryNames") }
        if executableSHA256 != other.executableSHA256 { result.append("executableSHA256") }
        if infoPlistSHA256 != other.infoPlistSHA256 { result.append("infoPlistSHA256") }
        if codeSignature != other.codeSignature { result.append("codeSignature") }
        return result
    }
}
