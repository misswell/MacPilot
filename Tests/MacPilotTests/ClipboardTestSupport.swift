//
//  ClipboardTestSupport.swift
//  MacPilot
//
//  剪贴板测试共享辅助：把 ClipboardContentStore 的内容目录隔离到临时目录，
//  避免测试读写真实的用户目录。
//

import Foundation
@testable import MacPilot

@MainActor
enum ClipboardContentStoreIsolation {
    /// 把内容文件目录指到独立的临时目录；与 `restore(_:)` 成对使用。
    static func isolate() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-content-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ClipboardContentStore.directoryOverride = dir
        return dir
    }

    /// 恢复默认目录并清理临时目录；无论与其他 defer 的相对顺序如何都安全。
    static func restore(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        ClipboardContentStore.directoryOverride = nil
    }
}
