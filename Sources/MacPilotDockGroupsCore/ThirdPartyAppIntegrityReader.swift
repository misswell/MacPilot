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
//  - 代码签名身份（identifier / team / cdhash / 是否有效）
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

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return sha256(of: data)
    }

    private static func signatureInfo(of url: URL) -> ThirdPartyAppIntegrity.SignatureInfo {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return .init(identifier: nil, teamIdentifier: nil, cdHash: nil, isValid: false)
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let dictionary = (infoStatus == errSecSuccess ? information : nil) as? [String: Any]

        let cdHashData = dictionary?[kSecCodeInfoUnique as String] as? Data
        let cdHash = cdHashData?.map { String(format: "%02x", $0) }.joined()

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        let validityStatus = SecStaticCodeCheckValidity(staticCode, flags, nil)

        return .init(
            identifier: dictionary?[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary?[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: cdHash,
            isValid: validityStatus == errSecSuccess
        )
    }
}
