import CoreGraphics
import Foundation

/// A display as AppKit sees it: logical frame in points plus the backing scale
/// that turns those points into pixels. ScreenCaptureKit reports pixel sizes,
/// so comparing those to `NSScreen.frame` never identified a display reliably.
struct CaptureScreenInfo: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let backingScaleFactor: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int

    init(
        displayID: CGDirectDisplayID,
        frame: CGRect,
        backingScaleFactor: CGFloat,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.displayID = displayID
        self.frame = frame
        self.backingScaleFactor = backingScaleFactor
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

enum CaptureDisplayResolutionSource: String, Equatable, Sendable {
    case pointer
    case focusedWindow
    case mainScreen
    case firstAvailable
    case none
}

struct CaptureDisplayResolution: Equatable, Sendable {
    let displayID: CGDirectDisplayID?
    let source: CaptureDisplayResolutionSource
}

/// Resolves the display a capture should target. Matching is always by
/// `CGDirectDisplayID`; geometry is only used to ask which screen contains a
/// point, never to guess a display by size similarity.
enum CaptureDisplayResolver {
    static func displayID(containing point: CGPoint, screens: [CaptureScreenInfo]) -> CGDirectDisplayID? {
        screens.first { $0.frame.contains(point) }?.displayID
    }

    static func resolve(
        mouseLocation: CGPoint,
        screens: [CaptureScreenInfo],
        mainDisplayID: CGDirectDisplayID?,
        focusedWindowFrame: CGRect? = nil
    ) -> CaptureDisplayResolution {
        if let pointerID = displayID(containing: mouseLocation, screens: screens) {
            return CaptureDisplayResolution(displayID: pointerID, source: .pointer)
        }
        if let focusedWindowFrame {
            let midpoint = CGPoint(x: focusedWindowFrame.midX, y: focusedWindowFrame.midY)
            if let focusedID = displayID(containing: midpoint, screens: screens) {
                return CaptureDisplayResolution(displayID: focusedID, source: .focusedWindow)
            }
        }
        if let mainDisplayID, screens.contains(where: { $0.displayID == mainDisplayID }) {
            return CaptureDisplayResolution(displayID: mainDisplayID, source: .mainScreen)
        }
        if let first = screens.first?.displayID {
            return CaptureDisplayResolution(displayID: first, source: .firstAvailable)
        }
        return CaptureDisplayResolution(displayID: nil, source: .none)
    }

    /// Exact ID match only. A missing display is a failure the caller must
    /// report, not an opportunity to pick the closest-looking size.
    static func exactMatch(
        _ requested: CGDirectDisplayID,
        in available: [CGDirectDisplayID]
    ) -> CGDirectDisplayID? {
        available.first { $0 == requested }
    }

    /// Output pixels per point for a display. ScreenCaptureKit's
    /// `pointPixelScale` wins; AppKit's backing scale is the only fallback.
    static func outputScale(screenBackingScale: CGFloat, pointPixelScale: CGFloat?) -> CGFloat {
        if let pointPixelScale, pointPixelScale.isFinite, pointPixelScale > 0 {
            return pointPixelScale
        }
        return max(1, screenBackingScale)
    }

    static func pixelSize(
        for screen: CaptureScreenInfo,
        pointPixelScale: CGFloat? = nil
    ) -> CGSize {
        let scale = outputScale(
            screenBackingScale: screen.backingScaleFactor,
            pointPixelScale: pointPixelScale
        )
        return CGSize(
            width: max(1, (screen.frame.width * scale).rounded()),
            height: max(1, (screen.frame.height * scale).rounded())
        )
    }
}
