import CoreGraphics
import Foundation

/// The user-visible capture mode a request came from. Post-processing can be
/// configured per mode; `other` covers scheduled/legacy paths that do not have
/// a dedicated configuration yet.
enum CaptureMode: String, CaseIterable, Codable, Sendable {
    case area
    case applicationWindow
    case activeWindow
    case fullscreen
    case smartElement
    case scrolling
    case pin
    case other
}

enum CaptureTrigger: String, Codable, Sendable {
    case shortcut
    case menu
    case quickAccess
    case scheduled
    case other
}

enum CaptureConsistencyMode: String, Codable, Sendable {
    case live
    case frozen
}

/// Why a capture was taken. The intent decides *what the user asked for*, which
/// must stay independent from the global “after capture” preferences.
enum CaptureDeliveryIntent: String, Codable, Sendable {
    case automatic
    case explicitSave
    case explicitCopy
    case explicitPin
    case annotatedSave
}

/// One resolved set of post-capture actions. The legacy global settings map
/// onto this type unchanged; per-mode entries only override the modes the user
/// actually configured.
struct PostCaptureActionSet: Codable, Equatable, Sendable {
    var saveToDisk: Bool
    var copyToClipboard: Bool
    var showQuickAccess: Bool
    var pinToScreen: Bool
    var openAnnotation: Bool

    init(
        saveToDisk: Bool,
        copyToClipboard: Bool,
        showQuickAccess: Bool,
        pinToScreen: Bool,
        openAnnotation: Bool = false
    ) {
        self.saveToDisk = saveToDisk
        self.copyToClipboard = copyToClipboard
        self.showQuickAccess = showQuickAccess
        self.pinToScreen = pinToScreen
        self.openAnnotation = openAnnotation
    }

    /// Whether any consumer needs bytes on disk.
    var needsFileArtifact: Bool {
        saveToDisk || copyToClipboard || showQuickAccess || pinToScreen || openAnnotation
    }

    var isEmpty: Bool {
        !needsFileArtifact
    }

    static func actions(
        intent: CaptureDeliveryIntent,
        mode: CaptureMode,
        global: PostCaptureActionSet,
        perMode: [String: PostCaptureActionSet]
    ) -> PostCaptureActionSet {
        switch intent {
        case .automatic:
            return perMode[mode.rawValue] ?? global
        case .explicitSave, .annotatedSave:
            // An explicit save must always produce a canonical permanent file,
            // regardless of the automatic-save preference.
            return PostCaptureActionSet(
                saveToDisk: true,
                copyToClipboard: false,
                showQuickAccess: false,
                pinToScreen: false
            )
        case .explicitCopy:
            return PostCaptureActionSet(
                saveToDisk: false,
                copyToClipboard: true,
                showQuickAccess: false,
                pinToScreen: false
            )
        case .explicitPin:
            return PostCaptureActionSet(
                saveToDisk: false,
                copyToClipboard: false,
                showQuickAccess: false,
                pinToScreen: true
            )
        }
    }
}

extension ScreenCaptureImageFormat {
    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "heic": self = .heic
        case "jpg", "jpeg": self = .jpeg
        case "png": self = .png
        default: return nil
        }
    }
}

/// A recorded capture request. Every asynchronous continuation derived from it
/// carries `captureID`, so a stale task can never mutate a newer session.
struct CaptureRequest: Sendable {
    let captureID: UUID
    let mode: CaptureMode
    let trigger: CaptureTrigger
    let intent: CaptureDeliveryIntent
    let consistencyMode: CaptureConsistencyMode
    let displayIDs: Set<CGDirectDisplayID>
    let includesCursor: Bool
    let sourceWindowID: CGWindowID?
    let sourcePID: pid_t?
    let createdAt: Date

    init(
        captureID: UUID = UUID(),
        mode: CaptureMode,
        trigger: CaptureTrigger,
        intent: CaptureDeliveryIntent,
        consistencyMode: CaptureConsistencyMode = .frozen,
        displayIDs: Set<CGDirectDisplayID> = [],
        includesCursor: Bool = false,
        sourceWindowID: CGWindowID? = nil,
        sourcePID: pid_t? = nil,
        createdAt: Date = Date()
    ) {
        self.captureID = captureID
        self.mode = mode
        self.trigger = trigger
        self.intent = intent
        self.consistencyMode = consistencyMode
        self.displayIDs = displayIDs
        self.includesCursor = includesCursor
        self.sourceWindowID = sourceWindowID
        self.sourcePID = sourcePID
        self.createdAt = createdAt
    }
}

/// A finished capture. The image is carried in the existing sendable wrapper;
/// everything else describes where it came from so history, artifacts and UI
/// rows can be correlated by ID instead of by filename.
struct CaptureResult: Sendable {
    let captureID: UUID
    let image: SendableScreenCaptureImage
    let pixelWidth: Int
    let pixelHeight: Int
    let scaleFactor: CGFloat
    let screenRect: CGRect
    let displayIDs: Set<CGDirectDisplayID>
    let sourceWindowID: CGWindowID?
    let sourcePID: pid_t?
    let sourceApplication: String?
    let mode: CaptureMode
    let capturedAt: Date
    let colorSpaceName: String?
    let isComposite: Bool

    init(
        captureID: UUID = UUID(),
        image: CGImage,
        scaleFactor: CGFloat = 1,
        screenRect: CGRect = .zero,
        displayIDs: Set<CGDirectDisplayID> = [],
        sourceWindowID: CGWindowID? = nil,
        sourcePID: pid_t? = nil,
        sourceApplication: String? = nil,
        mode: CaptureMode,
        capturedAt: Date = Date(),
        colorSpaceName: String? = nil,
        isComposite: Bool = false
    ) {
        self.captureID = captureID
        self.image = SendableScreenCaptureImage(value: image)
        self.pixelWidth = image.width
        self.pixelHeight = image.height
        self.scaleFactor = scaleFactor
        self.screenRect = screenRect
        self.displayIDs = displayIDs
        self.sourceWindowID = sourceWindowID
        self.sourcePID = sourcePID
        self.sourceApplication = sourceApplication
        self.mode = mode
        self.capturedAt = capturedAt
        self.colorSpaceName = colorSpaceName
        self.isComposite = isComposite
    }
}

enum CaptureArtifactState: String, Codable, Sendable, CaseIterable {
    case reserved
    case writing
    case ready
    case promoting
    case failed
    case deleted

    var allowsFileOperations: Bool {
        self == .ready
    }

    var isSettled: Bool {
        switch self {
        case .ready, .failed, .deleted: return true
        case .reserved, .writing, .promoting: return false
        }
    }
}

struct CaptureArtifact: Identifiable, Equatable, Sendable {
    let id: UUID
    let captureID: UUID
    var url: URL
    let isTemporary: Bool
    let format: ScreenCaptureImageFormat
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int64
    var state: CaptureArtifactState
    var errorDescription: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        captureID: UUID,
        url: URL,
        isTemporary: Bool,
        format: ScreenCaptureImageFormat,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int64 = 0,
        state: CaptureArtifactState = .reserved,
        errorDescription: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.captureID = captureID
        self.url = url
        self.isTemporary = isTemporary
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.state = state
        self.errorDescription = errorDescription
        self.createdAt = createdAt
    }

    var isReady: Bool { state == .ready }
}

enum CaptureArtifactError: LocalizedError, Equatable {
    case destinationUnavailable
    case destinationNotWritable
    case encodeFailed
    case validationFailed
    case moveFailed
    case sourceMissing
    case alreadyPermanent
    case notReady

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable: return "The destination folder is unavailable."
        case .destinationNotWritable: return "The destination folder is not writable."
        case .encodeFailed: return "Failed to encode the screenshot image."
        case .validationFailed: return "The screenshot file failed validation."
        case .moveFailed: return "Failed to move the screenshot file."
        case .sourceMissing: return "The screenshot file no longer exists."
        case .alreadyPermanent: return "The screenshot is already a permanent file."
        case .notReady: return "The screenshot file is not ready."
        }
    }
}

/// Actions that depend on the artifact being fully written. The Quick Access UI
/// and manager both consult this so no code path can act on a half-written file.
enum QuickAccessFileOperation: String, CaseIterable, Sendable {
    case copy
    case save
    case open
    case drag
    case delete
    case edit
    case pin

    func isAllowed(in state: CaptureArtifactState) -> Bool {
        guard state.allowsFileOperations else { return false }
        // Deleting a failed write is the recovery path, so it is the only
        // operation allowed outside `.ready`.
        return true
    }

    static func canDelete(in state: CaptureArtifactState) -> Bool {
        switch state {
        case .ready, .failed: return true
        case .reserved, .writing, .promoting, .deleted: return false
        }
    }
}
