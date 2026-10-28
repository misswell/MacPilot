import Foundation

/// A generation-bound intent prevents a delayed shutdown notification from
/// terminating a helper opened after the feature was enabled again.
public enum DockHelperLifecycle {
    public static let shutdownNotification = Notification.Name("com.misswell.macpilot.dockgroups.shutdown")
    private struct Intent: Codable {
        let generation: String
        let enabled: Bool
        let issuedAt: Date
    }

    private static func file(in root: URL) -> URL {
        root.appendingPathComponent(".helper-lifecycle.json")
    }

    public static func publish(enabled: Bool, root: URL,
        notify: (String, String) -> Void = { generation, root in
            DistributedNotificationCenter.default().postNotificationName(
                shutdownNotification, object: generation, userInfo: ["root": root], deliverImmediately: true)
        }
    ) throws {
        let intent = Intent(generation: UUID().uuidString, enabled: enabled, issuedAt: Date())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(intent).write(to: file(in: root), options: .atomic)
        if !enabled {
            notify(intent.generation, root.standardizedFileURL.path)
        }
    }

    public static func permitsLaunch(root: URL) -> Bool {
        guard let data = try? Data(contentsOf: file(in: root)),
              let intent = try? JSONDecoder().decode(Intent.self, from: data) else { return true }
        return intent.enabled
    }

    public static func acceptsShutdown(generation: String, root: URL, startedAt: Date) -> Bool {
        guard let data = try? Data(contentsOf: file(in: root)),
              let intent = try? JSONDecoder().decode(Intent.self, from: data) else { return false }
        return !intent.enabled && intent.generation == generation && intent.issuedAt >= startedAt
    }
}
