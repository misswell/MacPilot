//
//  main.swift
//  MacPilotDockHelper
//
//  MacPilot Dock Groups 的二级启动器（需求第 5、7、24 节）。
//
//  这个进程由 MacPilot 生成：同一份 binary 被复制进每个分组的 .app，
//  只靠 Bundle ID（com.misswell.macpilot.dockgroup.<id>）区分自己是哪一组。
//
//  职责严格限制为：读配置 → 显示浮层 → 启动/激活 App → 打开 MacPilot 设置。
//  不加载外部 dylib、不执行第三方脚本、不运行 shell 命令、不修改任何第三方 App。
//

import AppKit
import MacPilotDockGroupsCore

@MainActor
final class DockHelperAppDelegate: NSObject, NSApplicationDelegate {
    private let controller: DockHelperPanelController

    init(controller: DockHelperPanelController) {
        self.controller = controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.show()
    }

    /// 用户再次点击 Dock 图标时重新显示浮层（而不是再开一个窗口）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

let application = NSApplication.shared

// accessory：浮层可以成为 key window，但不会在 Dock / 程序切换器里出现第二个图标。
application.setActivationPolicy(.accessory)

// 默认读取 MacPilot 的管理目录；`MACPILOT_DOCK_GROUPS_ROOT` 仅用于开发与自动化测试，
// 只影响「从哪里读配置」，Helper 本身始终没有写入能力。
let groupsRoot: URL = ProcessInfo.processInfo.environment["MACPILOT_DOCK_GROUPS_ROOT"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? DockGroupPaths.defaultRootDirectory()

let helperModel = DockHelperModel(rootDirectory: groupsRoot)
let panelController = DockHelperPanelController(model: helperModel)
DockHelperPanelController.shared = panelController

let appDelegate = DockHelperAppDelegate(controller: panelController)
application.delegate = appDelegate

application.run()
