//
//  ThirdPartyAppIntegrityReader.swift
//  MacPilotDockGroupsCore
//
//  需求第 29、30 节：自动化完整性测试的只读快照读取器。
//
//  读取内容：
//  - Bundle 目录元数据（修改时间、顶层条目）
//  - 主可执行文件 SHA-256
//  - Info.plist SHA-256
//  - 代码签名身份（identifier / team / cdhash / 是否有效 / Hardened Runtime）
//  - Entitlements
//
//  全程只读：不写入、不拷贝、不改名、不重新签名。
//

import CryptoKit
import Foundation
import Security

public enum ThirdPartyAppIntegrityReader {
    public static func snapshot(of appURL: URL) -> ThirdPartyAppIntegrity {
        let fileManager = FileManager.default
        let bundle = Bundle(url: appURL)

        let modificationDate = (try? fileManager.attributesOfItem(atPath: appURL.path))?[.modificationDate] as? Date
        let entries = ((try? fileManager.contentsOfDirectory(atPath: appURL.path)) ?? []).sorted()

        let executableURL = bundle?.executableURL
        let infoPlistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        return ThirdPartyAppIntegrity(
            bundlePath: appURL.standardizedFileURL.path,
            bundleIdentifier: bundle?.bundleIdentifier,
            modificationDate: modificationDate,
            directoryEntryNames: entries,
            executableSHA256: executableURL.flatMap { sha256(ofFileAt: $0) },
            infoPlistSHA256: sha256(ofFileAt: infoPlistURL),
            codeSignature: signatureInfo(of: appURL)
        )
    }

    /// 只读地取出一个 App 的 Entitlements（需求第 30 节）。
    public static func entitlements(of appURL: URL) -> [String] {
        guard let staticCode = staticCode(for: appURL) else { return [] }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard status == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return sortedDescription(of: entitlements)
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return sha256(of: data)
    }

    // MARK: - 内部

    private static func staticCode(for url: URL) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess else { return nil }
        return staticCode
    }

    private static func signatureInfo(of url: URL) -> ThirdPartyAppIntegrity.SignatureInfo {
        guard let staticCode = staticCode(for: url) else {
            return .init(
                identifier: nil,
                teamIdentifier: nil,
                cdHash: nil,
                isValid: false,
                entitlements: [],
                hasHardenedRuntime: false
            )
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        let dictionary = (infoStatus == errSecSuccess ? information : nil) as? [String: Any]

        let cdHashData = dictionary?[kSecCodeInfoUnique as String] as? Data
        let cdHash = cdHashData?.map { String(format: "%02x", $0) }.joined()

        // kSecCodeInfoFlags 里的 CS_RUNTIME 位即 Hardened Runtime。
        // CS_RUNTIME 是 CSCommon.h 里的 C 常量，没有导入到 Swift，因此本地声明。
        let hardenedRuntimeFlag: UInt32 = 0x0001_0000
        let flags = (dictionary?[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let hasHardenedRuntime = (flags & hardenedRuntimeFlag) != 0

        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            nil
        )

        return .init(
            identifier: dictionary?[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary?[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: cdHash,
            isValid: validityStatus == errSecSuccess,
            entitlements: sortedDescription(
                of: dictionary?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            ),
            hasHardenedRuntime: hasHardenedRuntime
        )
    }

    /// 把嵌套字典/数组也拍平成稳定的可比较字符串。
    private static func sortedDescription(of entitlements: [String: Any]) -> [String] {
        entitlements.keys.sorted().map { key in
            "\(key)=\(describe(entitlements[key]))"
        }
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string
        case let array as [Any]:
            return "[" + array.map { describe($0) }.sorted().joined(separator: ",") + "]"
        case let dictionary as [String: Any]:
            return "{" + dictionary.keys.sorted().map { "\($0):\(describe(dictionary[$0]))" }.joined(separator: ",") + "}"
        case .none:
            return "nil"
        case let other:
            return String(describing: other)
        }
    }
}
