//
//  PinnedScreenshotChromeStyle.swift
//  MacPilot
//
//  The visual language of a pinned screenshot.  It is deliberately *not*
//  `CaptureChromeStyle`: that one describes a *tool* — an opaque card holding
//  circular chips, which is right for the toolbar that floats over a region the
//  user is still selecting.  A pin is a different object: a floating picture
//  that happens to have controls.  So a pin shows the image full bleed at
//  native window radius with the panel's own shadow, and gathers every control
//  into one small glass island at the trailing top corner, plus a transient
//  zoom HUD at the bottom.  Nothing in this file is consumed by the capture
//  toolbar, and nothing in `CaptureChromeStyle` is consumed here; the two are
//  meant to diverge.
//

import AppKit
import SwiftUI

enum PinnedScreenshotChromeStyle {
  // MARK: - Control island geometry

  /// Distance from the image edge to the island and to the zoom HUD.
  static let outerInset: CGFloat = 8
  static let controlHeight: CGFloat = 32
  /// Hit target of one control.  The glyph inside it is far smaller on purpose:
  /// a pin should read as image-first even while its controls are showing, but
  /// a 28pt target is the floor for something this small and this clickable.
  static let controlSide: CGFloat = 28
  static let controlSpacing: CGFloat = 2
  static let glyphSize: CGFloat = 11.5

  /// Corner radius of the pre-Liquid-Glass island.  Smaller than the window's
  /// own radius so the two nested curves still read as intentional.
  static let legacyControlCornerRadius: CGFloat = 11

  // MARK: - Lock hotspot

  /// Mouse-passthrough exemption while locked.  Larger than the unlock control
  /// it holds: the target has to be reachable without hunting for pixels, and
  /// the image is only clickable in this square.
  static let lockHotspotSide: CGFloat = 48

  // MARK: - Zoom HUD

  static let zoomHUDWidth: CGFloat = 108
  static let zoomHUDHeight: CGFloat = 30
  /// One tap of `−` / `+`.
  static let zoomHUDStep: CGFloat = 0.10
  /// How long the HUD stays after the last zoom event.
  static let zoomHUDIdleInterval: TimeInterval = 1
  /// The bottom-centre region whose pointer keeps the HUD up.  Wider than the
  /// HUD itself so the user can aim at it without losing it.
  static let zoomHUDZoneWidth: CGFloat = 200
  static let zoomHUDZoneHeight: CGFloat = 56

  // MARK: - Motion and elevation

  static let hoverAnimationDuration: Double = 0.14
  /// Only the fallback island draws a shadow; on Liquid Glass the material
  /// already separates it from the image, and the panel owns the window shadow.
  static let chromeShadowOpacity: Double = 0.10
  static let chromeShadowRadius: CGFloat = 5
  static let chromeShadowOffset: CGFloat = 2

  // MARK: - Hairline around the image

  /// The pin's border is a single adaptive hairline.  It has to survive sitting
  /// on either a white web page or a dark terminal, so it is a light-line whose
  /// strength depends on the appearance rather than one fixed alpha.
  static let borderOpacityLight: Double = 0.18
  static let borderOpacityDark: Double = 0.12

  static func borderOpacity(for scheme: SwiftUI.ColorScheme) -> Double {
    scheme == .dark ? borderOpacityDark : borderOpacityLight
  }

  // MARK: - Glyphs

  static var glyph: NSColor { NSColor.labelColor }
  static var glyphMuted: NSColor { NSColor.secondaryLabelColor }
}
