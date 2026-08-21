//
//  AreaSelectionBackdrop.swift
//  Snapzy (integrated into MacPilot)
//
//  Shared models for area selection backdrops and results.
//

import CoreGraphics
import Foundation

typealias AreaSelectionResultCompletion = (AreaSelectionResult?) -> Void

/// Tools that can be started directly from the post-selection HUD.  The
/// annotation editor maps these values to its richer tool model, while the
/// capture layer stays independent from SwiftUI/AppKit implementation types.
nonisolated enum AreaSelectionAnnotationTool: String, Equatable, Sendable {
  case rectangle
  case arrow
  case pencil
  case text
  case counter
  case blur
  case crop
}

/// Actions exposed by the post-selection HUD.  PixPin keeps the selected area
/// on screen until the user chooses one of these actions; keeping the action
/// as a value type lets the capture coordinator route copy/annotate/OCR/pin
/// without coupling the Snapzy overlay to MacPilot's output pipeline.
nonisolated enum AreaSelectionAction: Equatable, Sendable {
  case capture
  case copy
  case save
  case newSelection
  case adjustSelection
  case more
  case annotate
  case annotateTool(AreaSelectionAnnotationTool)
  case ocr
  case pin
  case cancel
}

nonisolated enum AreaSelectionInteractionMode {
  case manualRegion
  /// Select the accessibility element under the pointer, then keep the
  /// selected frame on screen until a PixPin action is chosen.
  case smartElement
  case applicationWindow
}

nonisolated struct AreaSelectionBackdrop {
  let displayID: CGDirectDisplayID
  let image: CGImage
  let scaleFactor: CGFloat
  let isVisible: Bool

  init(displayID: CGDirectDisplayID, image: CGImage, scaleFactor: CGFloat, isVisible: Bool = true) {
    self.displayID = displayID
    self.image = image
    self.scaleFactor = scaleFactor
    self.isVisible = isVisible
  }
}

nonisolated enum WindowCaptureTargetKind: String, Sendable {
  case normal
  case menuBarPopover
}

nonisolated struct WindowCaptureTarget: Equatable, Sendable {
  let windowID: CGWindowID
  let frame: CGRect
  let displayID: CGDirectDisplayID
  let title: String?
  let bundleIdentifier: String?
  let ownerPID: Int32?

  let kind: WindowCaptureTargetKind

  init(
    windowID: CGWindowID,
    frame: CGRect,
    displayID: CGDirectDisplayID,
    title: String?,
    bundleIdentifier: String?,
    ownerPID: Int32?,
    kind: WindowCaptureTargetKind = .normal
  ) {
    self.windowID = windowID
    self.frame = frame
    self.displayID = displayID
    self.title = title
    self.bundleIdentifier = bundleIdentifier
    self.ownerPID = ownerPID
    self.kind = kind
  }
}

/// A menu-bar popover captured synchronously when the capture shortcut is received.
///
/// Menu extras may close as soon as Snapzy presents its selection UI. This preserves only
/// that already-visible popover's pixels; it is not a frozen-screen session.
nonisolated struct ImmediateMenuBarPopoverCapture {
  let target: WindowCaptureTarget
  let image: CGImage
  let scaleFactor: CGFloat
}

nonisolated enum AreaSelectionTarget: Equatable {
  case rect(CGRect)
  case window(WindowCaptureTarget)

  var rect: CGRect {
    switch self {
    case .rect(let rect):
      rect
    case .window(let target):
      target.frame
    }
  }

  var windowTarget: WindowCaptureTarget? {
    switch self {
    case .rect:
      nil
    case .window(let target):
      target
    }
  }
}

nonisolated struct AreaSelectionApplicationConfiguration {
  let prefetchedContentTask: ShareableContentPrefetchTask?
  let excludeOwnApplication: Bool
  let immediateMenuBarPopoverCaptures: [ImmediateMenuBarPopoverCapture]

  init(
    prefetchedContentTask: ShareableContentPrefetchTask?,
    excludeOwnApplication: Bool,
    immediateMenuBarPopoverCaptures: [ImmediateMenuBarPopoverCapture] = []
  ) {
    self.prefetchedContentTask = prefetchedContentTask
    self.excludeOwnApplication = excludeOwnApplication
    self.immediateMenuBarPopoverCaptures = immediateMenuBarPopoverCaptures
  }
}

nonisolated struct AreaSelectionResult {
  let target: AreaSelectionTarget
  let displayID: CGDirectDisplayID
  let mode: SelectionMode
  let displayIDs: Set<CGDirectDisplayID>

  init(
    target: AreaSelectionTarget,
    displayID: CGDirectDisplayID,
    mode: SelectionMode,
    displayIDs: Set<CGDirectDisplayID>? = nil
  ) {
    self.target = target
    self.displayID = displayID
    self.mode = mode
    self.displayIDs = displayIDs ?? [displayID]
  }

  var rect: CGRect {
    target.rect
  }

  var spansMultipleDisplays: Bool {
    displayIDs.count > 1
  }
}
