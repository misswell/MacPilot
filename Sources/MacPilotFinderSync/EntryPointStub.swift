import Foundation

// SwiftPM 要求每个可执行目标都提供 `<TargetName>_main` 符号，并把 `_main`
// 别名到它上面。appex 的真正入口是 `_NSExtensionMain`（见 Package.swift 的
// linkerSettings，它从 Info.plist 里发现 NSExtensionPrincipalClass），
// 这个桩符号只为满足链接别名，永远不会被执行。
// public 可见性使其成为导出符号，任何优化级别与工具链下都不会被剔除。
@_cdecl("MacPilotFinderSync_main")
public func macPilotFinderSyncMain() -> Int32 {
    0
}
