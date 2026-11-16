import Foundation

/// The single place that turns a capture intent plus the stored per-mode
/// configuration into the set of post-processing actions.
///
/// Explicit toolbar actions never read the automatic-save switches; automatic
/// captures use the mode entry when the user configured one and fall back to
/// the legacy global switches otherwise.
struct PostCapturePlan: Equatable, Sendable {
    let actions: PostCaptureActionSet
    let needsArtifact: Bool
    let artifactIsPermanent: Bool
}

enum PostCaptureRouter {
    static func plan(
        request: CaptureRequest,
        global: PostCaptureActionSet,
        perMode: [String: PostCaptureActionSet]
    ) -> PostCapturePlan {
        let actions = PostCaptureActionSet.actions(
            intent: request.intent,
            mode: request.mode,
            global: global,
            perMode: perMode
        )
        let permanent = actions.saveToDisk
        return PostCapturePlan(
            actions: actions,
            needsArtifact: actions.needsFileArtifact,
            artifactIsPermanent: permanent
        )
    }
}

/// Codable container for per-mode overrides. Absent keys mean "use the global
/// switches", which is exactly the pre-upgrade behaviour.
struct PostCaptureConfiguration: Codable, Equatable, Sendable {
    var perModeActions: [String: PostCaptureActionSet]

    init(perModeActions: [String: PostCaptureActionSet] = [:]) {
        self.perModeActions = perModeActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        perModeActions = try container.decodeIfPresent(
            [String: PostCaptureActionSet].self,
            forKey: .perModeActions
        ) ?? [:]
    }

    /// Unknown enum values in a persisted dictionary must not throw away the
    /// whole section: keep only keys that still name a known capture mode.
    func sanitized() -> PostCaptureConfiguration {
        let known = Set(CaptureMode.allCases.map(\.rawValue))
        return PostCaptureConfiguration(
            perModeActions: perModeActions.filter { known.contains($0.key) }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case perModeActions
    }
}

extension PostCaptureActionSet {
    init(legacy settings: ScreenCaptureSettings) {
        self.init(
            saveToDisk: settings.saveAfterCapture,
            copyToClipboard: settings.copyAfterCapture,
            showQuickAccess: settings.showQuickAccess,
            pinToScreen: settings.pinAfterCapture
        )
    }
}
