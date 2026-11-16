import CoreGraphics
import Foundation

/// A composite screenshot is all-or-nothing. This type names every way a
/// cross-display capture can be incomplete so callers cannot turn a missing
/// display or a failed crop into a "successful" image with transparent holes.
enum CaptureCompositeError: LocalizedError, Equatable {
    case missingSnapshots([CGDirectDisplayID])
    case cropFailed(CGDirectDisplayID)
    case emptyResult
    case sizeMismatch(expected: CGSize, actual: CGSize)

    var errorDescription: String? {
        switch self {
        case .missingSnapshots(let displayIDs):
            let list = displayIDs.map(String.init).joined(separator: ", ")
            return AppText.value("scCompositeMissingDisplays", language: .system)
                .replacingOccurrences(of: "{displays}", with: list)
        case .cropFailed(let displayID):
            return AppText.value("scCompositeCropFailed", language: .system)
                .replacingOccurrences(of: "{display}", with: String(displayID))
        case .emptyResult:
            return AppText.value("scCompositeEmpty", language: .system)
        case .sizeMismatch(let expected, let actual):
            return AppText.value("scCompositeSizeMismatch", language: .system)
                .replacingOccurrences(of: "{expected}", with: "\(Int(expected.width))×\(Int(expected.height))")
                .replacingOccurrences(of: "{actual}", with: "\(Int(actual.width))×\(Int(actual.height))")
        }
    }
}

enum CaptureCompositeValidator {
    static func missingDisplayIDs(
        requested: Set<CGDirectDisplayID>,
        captured: Set<CGDirectDisplayID>
    ) -> Set<CGDirectDisplayID> {
        requested.subtracting(captured)
    }

    /// Throws before any composition starts when a requested display has no
    /// snapshot. The list is sorted so logs and tests are deterministic.
    static func validateCoverage(
        requested: Set<CGDirectDisplayID>,
        captured: Set<CGDirectDisplayID>
    ) throws {
        let missing = missingDisplayIDs(requested: requested, captured: captured)
        guard missing.isEmpty else {
            throw CaptureCompositeError.missingSnapshots(missing.sorted())
        }
    }

    static func validateCrop(
        displayID: CGDirectDisplayID,
        image: CGImage?
    ) throws {
        guard image != nil else {
            throw CaptureCompositeError.cropFailed(displayID)
        }
    }

    static func validateOutput(
        image: CGImage?,
        expectedSize: CGSize,
        tolerance: CGFloat = 1
    ) throws {
        guard let image else { throw CaptureCompositeError.emptyResult }
        guard image.width > 0, image.height > 0 else { throw CaptureCompositeError.emptyResult }
        let actual = CGSize(width: image.width, height: image.height)
        guard abs(actual.width - expectedSize.width) <= tolerance,
              abs(actual.height - expectedSize.height) <= tolerance else {
            throw CaptureCompositeError.sizeMismatch(expected: expectedSize, actual: actual)
        }
    }
}
