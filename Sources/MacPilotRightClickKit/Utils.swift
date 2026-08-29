import Foundation

/// FinderSync sends `URL.path`, not a percent-encoded URL component. Keep the
/// value byte-for-byte so names containing `%2F` or `%25` cannot be retargeted.
enum RightClickIPCPath {
    static func fileSystemPath(_ value: String) -> String { value }
}

public class Utils {
    public static func isProtectedFolder(_ path: String) -> Bool {
        print("isProtectedFolder: \(path)")

        return Constants.protectedDirs.contains { protectedPath in
            print("Comparing with protected path: \(protectedPath)")
            return path == protectedPath
        }
    }
    // MARK:
    public static func getRealHomeDir() -> String {
        let fullPath = NSHomeDirectory()
        let components = fullPath.components(separatedBy: "/")
        let limitedComponents = Array(components.prefix(3))  // 取前3个是因为第一个是空字符串（路径以/开头）
        return limitedComponents.joined(separator: "/")
    }
}
