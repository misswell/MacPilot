//
//  Constants.swift
//  MacPilot
//
//  Created by 李旭 on 2024/9/25.
//

import Foundation


/// MacPilot 集成的 Finder 右键菜单统一常量。
/// 主 App 与 FinderSync 扩展必须使用同一 App Group 才能共享配置。
public enum RightClickConstants {
    /// 主程序与 FinderSync 扩展共享配置的 App Group。
    /// 与资源里的 entitlements（com.apple.security.application-groups）保持一致。
    // Developer ID distributions without provisioning profiles must use the
    // signing team's prefix for macOS to validate container ownership.
    public static let appGroupIdentifier = "U8U443D7ZL.com.misswell.macpilot.rightclick"
}

public enum Constants {
    static let HomedirPath = Utils.getRealHomeDir()
    /// The identifier for the settings window.
    static let settingsWindowID = "rclick-settings"
    static let protectedDirs = [
        HomedirPath + "/Desktop/",
        HomedirPath + "/Desktop/danger/",
        HomedirPath + "/Applications/",
        "/Applications/",
        "/System/",
        "/Library/",
        "/Users/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/var/"
    ]

}
