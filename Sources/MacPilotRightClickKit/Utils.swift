import Foundation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.misswell.macpilot.rightclick",
    category: "RightClickUtils"
)

/// FinderSync sends `URL.path`, not a percent-encoded URL component. Keep the
/// value byte-for-byte so names containing `%2F` or `%25` cannot be retargeted.
public enum RightClickIPCPath {
    public static func fileSystemPath(_ value: String) -> String { value }
}

public class Utils {
    public static func isProtectedFolder(_ path: String) -> Bool {
        // Finder 传来的路径不带尾斜杠，而 Constants.protectedDirs 统一带尾斜杠；
        // 归一化后再比较，否则 /Applications 这类路径永远匹配不上。
        let normalized = path.hasSuffix("/") ? path : path + "/"
        return Constants.protectedDirs.contains(normalized)
    }
    // MARK:
    public static func getRealHomeDir() -> String {
        let fullPath = NSHomeDirectory()
        let components = fullPath.components(separatedBy: "/")
        let limitedComponents = Array(components.prefix(3))  // 取前3个是因为第一个是空字符串（路径以/开头）
        return limitedComponents.joined(separator: "/")
    }
}
