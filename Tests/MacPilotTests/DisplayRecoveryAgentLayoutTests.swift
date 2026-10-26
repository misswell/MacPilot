import Foundation
import Testing
@testable import MacPilot

/// 显示恢复助手是常驻 XPC 服务，住在主 App bundle 里。它的身份决定主应用
/// 还能不能被正常启动，因此布局由测试锁住，不靠人工记得。
@MainActor
struct DisplayRecoveryAgentLayoutTests {
    @Test func theAgentIsANestedAppWithItsOwnIdentity() throws {
        let plist = try agentPlist()

        // BundleProgram 必须指向嵌套 app 里的程序，而不是 Contents/MacOS 下的
        // 裸可执行文件。裸文件会继承主 App 的 bundle identity：助手在跑时
        // LaunchServices 把「助手活着」读成「com.misswell.macpilot 已有实例」，
        // open -a、Finder 双击、登录启动都解析到助手，主进程根本不创建。
        let program = try #require(plist["BundleProgram"] as? String)
        #expect(program == "Contents/Helpers/MacPilotDisplayRecovery.app/Contents/MacOS/MacPilotDisplayRecovery")
        #expect(!program.hasPrefix("Contents/MacOS/"))
    }

    @Test func theNestedAgentDeclaresABackgroundIdentity() throws {
        let nested = try nestedInfoPlist()

        // 独立标识符让 LaunchServices 把它当成另一个应用，而不是 MacPilot。
        #expect(nested["CFBundleIdentifier"] as? String == "com.misswell.macpilot.display-recovery")
        #expect(nested["CFBundleExecutable"] as? String == "MacPilotDisplayRecovery")
        // 后台身份：不出现 Dock 图标、不出现自己的菜单栏项。
        #expect(nested["LSUIElement"] as? Bool == true)
        #expect(nested["LSBackgroundOnly"] as? Bool == true)
    }

    @Test func theAgentIsStillAKeptAliveMachServiceOverAqua() throws {
        let plist = try agentPlist()

        // 主应用不在时也要能响应恢复请求（黑屏之后），所以常驻 + Mach 服务；
        // Carbon 热键和显示器 API 仍然需要 Aqua 会话。
        #expect(plist["Label"] as? String == "com.misswell.macpilot.display-recovery")
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
        let services = try #require(plist["MachServices"] as? [String: Bool])
        #expect(services["com.misswell.macpilot.display-recovery"] == true)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacPilotTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func agentPlist() throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent("Resources/com.misswell.macpilot.display-recovery.plist")
        let data = try Data(contentsOf: url)
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func nestedInfoPlist() throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent("Resources/MacPilotDisplayRecovery.app.Info.plist")
        let data = try Data(contentsOf: url)
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
}
