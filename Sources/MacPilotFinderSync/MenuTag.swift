import Foundation

/// 确定性的菜单项 tag 推导，菜单构建与点击解析共用同一映射。
///
/// 原实现用 `String.hash`，其结果是按进程随机化的；FNV-1a 让 tag 在
/// 启动之间保持稳定、可测试。64 位空间下的碰撞概率与原实现等价。
enum MenuTag {
    private static let offset: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    static func forAction(_ id: String) -> Int { tag("action_\(id)") }
    static func forApp(_ id: String) -> Int { tag("app_\(id)") }
    static func forNewFile(_ id: String) -> Int { tag("newfile_\(id)") }
    static func forCommonDir(_ id: String) -> Int { tag("commondir_\(id)") }

    private static func tag(_ key: String) -> Int {
        var hash = offset
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        return Int(truncatingIfNeeded: hash)
    }
}
