//
//  AppLaunchService.swift
//  MacPilotDockGroupsCore
//
//  需求第 2、10、19 节：
//  - 启动应用统一使用公开 Workspace API；
//  - 已运行则激活，未运行才启动，绝不重复启动第二个实例；
//  - 绝不使用 NSRunningApplication.hide() 来「消除 Dock 图标」——
//    那只会隐藏窗口，属于需求第 19 节明确禁止的误用。
//

import AppKit
import Foundation

public enum AppLaunchError: Error, Equatable, LocalizedError {
    case applicationNotFound(name: String)
    case launchFailed(name: String, message: String)
    case activationFailed(name: String)

    public var errorDescription: String? {
        switch self {
        case let .applicationNotFound(name):
            return "Application not found: \(name)"
        case let .launchFailed(name, message):
            return "Could not launch \(name): \(message)"
        case let .activationFailed(name):
            return "Could not activate \(name)."
        }
    }
}

public enum AppLaunchService {
    /// 需求第 10 节的统一入口：运行中 → 激活；未运行 → 启动。
    @discardableResult
    public static func open(_ reference: DockGroupApp, workspace: NSWorkspace = .shared) async throws -> Bool {
        guard let url = InstalledAppResolver.resolveURL(reference, workspace: workspace) else {
            throw AppLaunchError.applicationNotFound(name: reference.name)
        }
        return try await open(url: url, name: reference.name, workspace: workspace)
    }

    @discardableResult
    public static func open(url: URL, name: String, workspace: NSWorkspace = .shared) async throws -> Bool {
        let bundleIdentifier = Bundle(url: url)?.bundleIdentifier

        if let running = runningApplication(bundleIdentifier: bundleIdentifier, url: url, workspace: workspace) {
            return try activate(running, name: name)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // 需求第 10 节：即使竞态下已被启动，也不要创建第二个实例。
        configuration.createsNewApplicationInstance = false

        return try await withCheckedThrowingContinuation { continuation in
            workspace.openApplication(at: url, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: AppLaunchError.launchFailed(name: name, message: error.localizedDescription))
                } else {
                    continuation.resume(returning: application != nil)
                }
            }
        }
    }

    /// 按 bundleIdentifier 优先、路径兜底匹配正在运行的实例。
    public static func runningApplication(
        bundleIdentifier: String?,
        url: URL,
        workspace: NSWorkspace = .shared
    ) -> NSRunningApplication? {
        let running = workspace.runningApplications
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            if let match = running.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                return match
            }
        }
        let targetPath = url.standardizedFileURL.path
        return running.first { application in
            guard let bundleURL = application.bundleURL else { return false }
            return bundleURL.standardizedFileURL.path == targetPath
        }
    }

    public static func isRunning(bundleIdentifier: String?, url: URL, workspace: NSWorkspace = .shared) -> Bool {
        runningApplication(bundleIdentifier: bundleIdentifier, url: url, workspace: workspace) != nil
    }

    private static func activate(_ application: NSRunningApplication, name: String) throws -> Bool {
        // macOS 14 起 activate(options:) 已废弃；activate(from:options:) 是公开替代。
        let activated = application.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        guard activated else { throw AppLaunchError.activationFailed(name: name) }
        return true
    }
}
