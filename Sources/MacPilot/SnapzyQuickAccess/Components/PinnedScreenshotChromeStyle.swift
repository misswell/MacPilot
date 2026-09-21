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
//  into one small HUD capsule at the trailing top corner, plus a transient
//  zoom read-out at the bottom.  Nothing in this file is consumed by the capture
//  toolbar, and nothing in `CaptureChromeStyle` is consumed here; the two are
//  meant to diverge.
//
//  The capsule is a *system HUD*: a dark translucent fill with a light hairline
//  and white glyphs, drawn without any backdrop sampling.  It cannot use
//  `glassEffect` here.  A pin is a borderless, non-activating panel that joins
//  every Space, and on macOS 26 the glass in that kind of window comes back
//  untinted or wrongly tinted — a flat grey slab over the image — which is the
//  failure Apple's own integrators work around.  Because the capsule sits on
//  arbitrary screenshot content, its contrast has to come from the fill itself,
//  not from whatever happens to be behind it.
//

import AppKit
import SwiftUI

enum PinnedScreenshotChromeStyle {
  // MARK: - Control capsule geometry

  /// Distance from the image edge to the capsule and to the zoom HUD.
  static let outerInset: CGFloat = 8
  static let controlHeight: CGFloat = 32
  /// Hit target of one control.  The glyph inside it is far smaller on purpose:
  /// a pin should read as image-first even while its controls are showing, but
  /// a 28pt target is the floor for something this small and this clickable.
  static let controlSide: CGFloat = 28
  static let controlSpacing: CGFloat = 2
  static let glyphSize: CGFloat = 13
  static let glyphWeight: SwiftUI.Font.Weight = .semibold

  /// Half the capsule height, which is exactly `NSWindow.defaultCornerRadius -
  /// outerInset`.  The capsule is therefore concentric with the pin it floats
  /// on — the same relationship Liquid Glass would have derived automatically,
  /// computed here so it does not depend on glass working.
  static var controlCornerRadius: CGFloat { controlHeight / 2 }

  // MARK: - Control capsule surface

  /// Dark enough to hold white glyphs over a white web page, translucent enough
  /// to still read as an overlay rather than a sticker.
  static let capsuleFillOpacity: Double = 0.62
  /// The hairline is what separates the capsule from a dark screenshot, where
  /// the fill alone has no contrast left to work with.
  static let capsuleStrokeOpacity: Double = 0.22
  static let capsuleGlyph: SwiftUI.Color = .white

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
  static let chromeShadowOpacity: Double = 0.18
  static let chromeShadowRadius: CGFloat = 6
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
}
