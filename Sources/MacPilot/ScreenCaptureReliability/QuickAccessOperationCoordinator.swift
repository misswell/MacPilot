import Foundation

/// The only authority that decides which Quick Access actions may run for a
/// given artifact state. UI and the manager both ask here, so a half-written
/// file can never be copied, saved, dragged or edited.
enum QuickAccessOperationCoordinator {
    static func isFileReady(_ state: CaptureArtifactState) -> Bool {
        state == .ready
    }

    static func allows(_ operation: QuickAccessFileOperation, state: CaptureArtifactState) -> Bool {
        switch operation {
        case .delete:
            return QuickAccessFileOperation.canDelete(in: state)
        default:
            return isFileReady(state)
        }
    }

    static func mayStartSave(state: CaptureArtifactState) -> Bool {
        isFileReady(state)
    }

    static func mayStartDelete(state: CaptureArtifactState) -> Bool {
        QuickAccessFileOperation.canDelete(in: state)
    }

    /// The auto-dismiss countdown starts only after the file committed. A card
    /// that is merely showing its in-memory thumbnail must not disappear
    /// before its file exists.
    static func shouldRunCountdown(state: CaptureArtifactState) -> Bool {
        state == .ready
    }

    static func pauseCountdown(state: CaptureArtifactState) -> Bool {
        !shouldRunCountdown(state: state)
    }

    static func stateAfterWriteFailure() -> CaptureArtifactState { .failed }

    static func stateAfterPromotionFailure() -> CaptureArtifactState { .ready }

    static func userMessageKey(for state: CaptureArtifactState) -> String? {
        switch state {
        case .reserved, .writing, .promoting: return "qaArtifactPreparing"
        case .failed: return "qaArtifactFailed"
        case .ready, .deleted: return nil
        }
    }
}
