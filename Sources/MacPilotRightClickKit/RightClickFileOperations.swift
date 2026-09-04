//
//  RightClickFileOperations.swift
//  MacPilot
//
//  执行 Finder 右键菜单对应的文件操作：
//  打开应用/常用目录、复制路径、打开终端、隐藏/取消隐藏、删除、AirDrop、新建文件。
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class RightClickFileOperations {
    @AppLog(category: "RightClickMenu")
    private var logger

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - 点击入口

    func openCommonDirs(target: [String]) {
        logger.debug("开始打开常用目录，目标路径：\(target)")

        for dirPath in target {
            let path = RightClickIPCPath.fileSystemPath(dirPath)
            let url = URL(fileURLWithPath: path, isDirectory: true)

            logger.debug("正在打开目录：\(path)")
            NSWorkspace.shared.open(url)
        }

        logger.debug("常用目录打开操作完成")
    }

    func openApp(rid: String, target: [String]) {
        guard let rcitem = appState.getAppItem(rid: rid) else {
            logger.warning("when openapp, but not have app \(rid)")
            return
        }

        let appUrl = rcitem.url
        logger.debug("openApp: rid=\(rid) app=\(appUrl.path) target=\(target)")

        for dirPath in target {
            let path = RightClickIPCPath.fileSystemPath(dirPath)
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            let config = NSWorkspace.OpenConfiguration()
            let logger = self.logger
            NSWorkspace.shared.open([dir], withApplicationAt: appUrl, configuration: config) { @Sendable [logger] runningApp, error in
                if let error = error {
                    logger.error("Error opening with application: \(error.localizedDescription)")
                    logger.error("Error code: \((error as NSError).code), domain: \((error as NSError).domain)")
                } else if let runningApp = runningApp {
                    logger.debug("Successfully opened with application: \(runningApp.localizedName ?? "Unknown")")
                }
            }
        }
    }

    /// 按稳定的 action id 分发操作。
    func handleAction(rid: String, target: [String], trigger: String) async {
        guard let rcitem = appState.getActionItem(rid: rid) else {
            logger.warning("Action not found for id: \(rid)")
            return
        }

        switch rcitem.id {
        case "copy-path":
            copyPath(target)
        case "open-terminal":
            openTerminal(target)
        case "delete-direct":
            await deleteFoldorFile(target, trigger)
        case "unhide":
            await unhideFilesAndDirs(target, trigger)
        case "hide":
            await hideFilesAndDirs(target, trigger)
        case "airdrop":
            await showAirDrop(target, trigger)
        default:
            logger.warning("no action id matched")
        }
    }

    // MARK: - 新建文件

    func createFile(rid: String, target: [String]) async {
        guard let dirPath = targetDirectoryForNewFile(target) else {
            logger.warning("when createFile, but not have target directory")
            return
        }

        let dirURL = URL(fileURLWithPath: dirPath)

        guard await ensureAccess(to: dirURL, skipLog: "用户取消授权，跳过创建文件") else {
            return
        }

        if rid == NewFileMenuItem.customFileId {
            let filePath = getUniqueFilePath(dir: dirPath, ext: "")
            let fileURL = URL(fileURLWithPath: filePath)
            do {
                try Data().write(to: fileURL)
                logger.info("created editable file: \(fileURL.path)")
                revealInFinderAndRename(fileURL)
            } catch {
                logger.error("create editable file error: \(error.localizedDescription)")
            }
            return
        }

        guard let rcitem = appState.getFileType(rid: rid) else {
            logger.warning("when createFile, but not have fileType \(rid) ")
            return
        }

        let ext = rcitem.ext
        logger.info("create file dir:\(dirPath) -- ext \(ext)")
        let filePath = getUniqueFilePath(dir: dirPath, ext: ext)
        let fileURL = URL(fileURLWithPath: filePath)

        do {
            let fileManager = FileManager.default

            if let templateUrl = rcitem.template {
                try fileManager.copyItem(at: templateUrl, to: fileURL)
                logger.info("已成功复制模板到目标路径：\(fileURL.path)")
            } else {
                if let defaultTemplateURL = Bundle.main.url(forResource: "template", withExtension: ext.replacingOccurrences(of: ".", with: "")) {
                    logger.info("使用模板创建文件，模板路径：\(defaultTemplateURL.path)")
                    try fileManager.copyItem(at: defaultTemplateURL, to: fileURL)
                    logger.info("已成功复制模板到目标路径：\(fileURL.path)")
                } else {
                    logger.warning("模板文件不存在：\(ext)")
                    try Data().write(to: fileURL)
                }
            }
            revealInFinderAndRename(fileURL)
        } catch let error as NSError {
            switch error.domain {
            case NSCocoaErrorDomain:
                switch error.code {
                case NSFileNoSuchFileError:
                    logger.error("文件不存在：\(filePath)")
                case NSFileWriteOutOfSpaceError:
                    logger.error("磁盘空间不足")
                case NSFileWriteNoPermissionError:
                    logger.error("没有写入权限：\(filePath)")
                default:
                    logger.error("创建文件错误：\(error.localizedDescription) (错误码：\(error.code))")
                }
            default:
                logger.error("未处理的错误：\(error.localizedDescription) (错误码：\(error.code))")
            }
        }
    }

    func getUniqueFilePath(dir: String, ext: String) -> String {
        let fileManager = FileManager.default
        let dirURL = URL(fileURLWithPath: dir.hasSuffix("/") ? String(dir.dropLast()) : dir)
        let baseFileName = AppLocalization.localized("Untitled")
        var filePath = dirURL.appendingPathComponent("\(baseFileName)\(ext)").path
        var counter = 1

        while fileManager.fileExists(atPath: filePath) {
            let newFileName = "\(baseFileName)\(counter)"
            filePath = dirURL.appendingPathComponent("\(newFileName)\(ext)").path
            counter += 1
        }

        return filePath
    }

    private func targetDirectoryForNewFile(_ target: [String]) -> String? {
        guard let rawPath = target.first else { return nil }
        let path = RightClickIPCPath.fileSystemPath(rawPath)
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return path
            }
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }

        return path
    }

    /// 在 Finder 中显示新文件并借助辅助功能触发一次回车进入重命名。
    private func revealInFinderAndRename(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [logger] in
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(options) else {
                logger.warning("Accessibility permission is required to trigger Finder rename for \(fileURL.path)")
                return
            }

            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let keyCodeReturn: CGKeyCode = 36
                let source = CGEventSource(stateID: .hidSystemState)
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: false)
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - 动作实现

    func showAirDrop(_ target: [String], _ trigger: String) async {
        logger.info("---- showAirDrop trigger:\(trigger)")
        let fm = FileManager.default
        var fileURLs: [URL] = []

        if trigger == "ctx-container" {
            showAlert(style: .warning, titleKey: "Warning", formatKey: "The current folder cannot be shared. Please select files or subfolders instead.")
            return
        }

        for item in target {
            let decodedPath = RightClickIPCPath.fileSystemPath(item)
            logger.info("airdrop path \(decodedPath)")

            if Utils.isProtectedFolder(decodedPath) {
                showAlert(
                    style: .warning,
                    titleKey: "Warning",
                    formatKey: "Protected system folders cannot be shared: %@",
                    [decodedPath]
                )
                logger.warning("试图分享受保护的系统文件夹，操作已被阻止：\(decodedPath)")
                continue
            }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: decodedPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    logger.warning("不能通过 AirDrop 分享文件夹：\(decodedPath)")
                    showAlert(
                        style: .informational,
                        titleKey: "Notice",
                        formatKey: "Folders cannot be shared via AirDrop: %@",
                        [decodedPath]
                    )
                    continue
                } else {
                    // 确保有文件所在目录的访问权限
                    let fileURL = URL(fileURLWithPath: decodedPath)
                    let dirURL = fileURL.deletingLastPathComponent()
                    guard await ensureAccess(to: dirURL, skipLog: "用户取消授权，跳过 AirDrop：\(decodedPath)") else {
                        continue
                    }
                    fileURLs.append(fileURL)
                }
            }
        }

        if !fileURLs.isEmpty {
            if let airDropService = NSSharingService(named: .sendViaAirDrop) {
                airDropService.perform(withItems: fileURLs)
                logger.info("已通过 AirDrop 分享文件：\(fileURLs.map { $0.path }.joined(separator: ", "))")
            } else {
                logger.warning("无法获取 AirDrop 服务")
            }
        }
    }

    func unhideFilesAndDirs(_ target: [String], _ trigger: String) async {
        logger.info("开始取消隐藏文件和目录，目标路径：\(target)")
        if let dirPath = target.first {
            let fileManager = FileManager.default
            let path = RightClickIPCPath.fileSystemPath(dirPath)
            logger.info("处理主目录：\(path)")
            let url = URL(fileURLWithPath: path)

            guard await ensureAccess(to: url, skipLog: "用户取消授权，跳过取消隐藏：\(path)") else {
                return
            }

            do {
                let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isHiddenKey], options: [.skipsPackageDescendants])
                for case var fileURL in contents {
                    do {
                        var resourceValues = URLResourceValues()
                        resourceValues.isHidden = false
                        try fileURL.setResourceValues(resourceValues)
                        logger.info("成功取消隐藏：\(fileURL.path)")
                    } catch {
                        logger.error("取消隐藏失败：\(fileURL.path): \(error)")
                    }
                }
            } catch {
                logger.error("获取目录内容失败：\(error)")
            }

            do {
                var resourceValues = URLResourceValues()
                resourceValues.isHidden = false
                var targetURL = url
                try targetURL.setResourceValues(resourceValues)
                logger.info("成功取消隐藏主目录：\(path)")
            } catch {
                logger.error("取消隐藏主目录失败：\(path): \(error)")
            }
            logger.info("取消隐藏操作完成，共处理目录：\(path)")
        }
    }

    func hideFilesAndDirs(_ target: [String], _ trigger: String) async {
        logger.info("开始隐藏文件和目录，目标路径：\(target), 触发器：\(trigger)")
        let fileManager = FileManager.default

        if trigger == "ctx-container", let dirPath = target.first {
            let path = RightClickIPCPath.fileSystemPath(dirPath)
            logger.info("处理主目录：\(path)")
            let url = URL(fileURLWithPath: path)

            guard await ensureAccess(to: url, skipLog: "用户取消授权，跳过隐藏：\(path)") else {
                return
            }

            do {
                let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
                for case var fileURL in contents {
                    if Utils.isProtectedFolder(fileURL.path) {
                        logger.warning("跳过受保护的文件路径：\(fileURL.path)")
                        continue
                    }
                    do {
                        var resourceValues = URLResourceValues()
                        resourceValues.isHidden = true
                        try fileURL.setResourceValues(resourceValues)
                        logger.info("成功隐藏：\(fileURL.path)")
                    } catch {
                        logger.error("隐藏失败：\(fileURL.path): \(error)")
                    }
                }
            } catch {
                logger.error("获取目录内容失败：\(error)")
            }
        } else if trigger == "ctx-items" {
            for dirPath in target {
                let path = RightClickIPCPath.fileSystemPath(dirPath)
                logger.info("处理路径：\(path)")
                let url = URL(fileURLWithPath: path)

                if Utils.isProtectedFolder(path) {
                    logger.warning("跳过受保护的文件路径：\(path)")
                    continue
                }

                // 确保有文件所在目录的访问权限
                let dirURL = url.deletingLastPathComponent()
                guard await ensureAccess(to: dirURL, skipLog: "用户取消授权，跳过隐藏：\(path)") else {
                    continue
                }

                do {
                    var resourceValues = URLResourceValues()
                    resourceValues.isHidden = true
                    var targetURL = url
                    try targetURL.setResourceValues(resourceValues)
                    logger.info("成功隐藏：\(path)")
                } catch {
                    logger.error("隐藏失败：\(path): \(error)")
                }
            }
        }
        logger.info("隐藏操作完成")
    }

    func copyPath(_ target: [String]) {
        let paths = target.compactMap { rawPath -> String? in
            let path = RightClickIPCPath.fileSystemPath(rawPath)
            guard !path.isEmpty else { return nil }
            return path
        }

        guard !paths.isEmpty else {
            logger.warning("No paths to copy")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        logger.debug("Copied \(paths.count) path(s) to the pasteboard")
    }

    func openTerminal(_ target: [String]) {
        let directories = target.compactMap { rawPath -> URL? in
            let path = RightClickIPCPath.fileSystemPath(rawPath)
            guard !path.isEmpty else { return nil }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return nil
            }

            let url = URL(fileURLWithPath: path)
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }
        .reduce(into: [URL]()) { result, url in
            if !result.contains(url) {
                result.append(url)
            }
        }

        guard !directories.isEmpty else {
            logger.warning("No valid directory found to open in Terminal")
            return
        }

        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            logger.error("Terminal.app is not installed")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        let logger = self.logger
        for directory in directories {
            NSWorkspace.shared.open(
                [directory],
                withApplicationAt: terminalURL,
                configuration: configuration
            ) { @Sendable [logger] _, error in
                if let error {
                    logger.error("Failed to open Terminal at \(directory.path): \(error.localizedDescription)")
                } else {
                    logger.debug("Opened Terminal at \(directory.path)")
                }
            }
        }
    }

    func deleteFoldorFile(_ target: [String], _ trigger: String) async {
        logger.info("---- deleteFoldorFile trigger:\(trigger)")
        let fm = FileManager.default

        if trigger == "ctx-container" {
            showAlert(style: .warning, titleKey: "Warning", formatKey: "The current folder cannot be deleted. Please select files or subfolders instead.")
            return
        }

        for item in target {
            let decodedPath = RightClickIPCPath.fileSystemPath(item)

            if Utils.isProtectedFolder(decodedPath) {
                showAlert(
                    style: .warning,
                    titleKey: "Warning",
                    formatKey: "Protected system folders cannot be deleted: %@",
                    [decodedPath]
                )
                logger.warning("试图删除受保护的系统文件夹，操作已被阻止：\(decodedPath)")
                continue
            }

            // 确保有父目录的访问权限
            let url = URL(fileURLWithPath: decodedPath)
            let dirURL = url.deletingLastPathComponent()
            guard await ensureAccess(to: dirURL, skipLog: "用户取消授权，跳过删除：\(decodedPath)") else {
                continue
            }

            do {
                try fm.removeItem(atPath: decodedPath)
            } catch {
                logger.error("delete \(target) file run error \(error)")
            }
        }
    }

    // MARK: - 私有工具

    /// 确认对 `url` 的沙盒访问权限，必要时弹窗请求；被拒绝时返回 false 并记录日志。
    private func ensureAccess(to url: URL, skipLog: @autoclosure () -> String) async -> Bool {
        if appState.bookmarkManager.hasAccess(to: url) {
            return true
        }
        if await appState.bookmarkManager.promptForPermission(for: url) != nil {
            return true
        }
        let message = skipLog()
        logger.warning("\(message)")
        return false
    }

    /// 统一的提示弹窗（原实现中四处重复的 NSAlert 样板）。
    private func showAlert(style: NSAlert.Style, titleKey: String, formatKey: String, _ arguments: [CVarArg] = []) {
        let alert = NSAlert()
        alert.messageText = AppLocalization.localized(titleKey)
        alert.informativeText = String(format: AppLocalization.localized(formatKey), arguments: arguments)
        alert.alertStyle = style
        alert.addButton(withTitle: AppLocalization.localized("OK"))
        alert.runModal()
    }
}
