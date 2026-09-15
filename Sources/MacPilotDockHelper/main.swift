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
//  生命周期：浮层关掉之后进程继续待命 `DockHelperPanelController.warmLifetime`，
//  这样再次点 Dock 图标是立刻展开；到期（或被系统按 TAL 回收）才退出。
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
    /// 浮层关掉之后进程仍在待命，所以这条路径是「热展开」。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return true
    }

    /// 兜底：待命中的 Helper 被 Dock 图标激活时，有些路径只送来「激活」事件、
    /// 不送 reopen。两个入口都指向同一个 `show()`，重复调用是幂等的。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !controller.isPanelVisible else { return }
        controller.show()
    }

    /// 浮层不是「主窗口」：收起来之后进程要继续待命，不能被当成「最后一个窗口关了」。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
