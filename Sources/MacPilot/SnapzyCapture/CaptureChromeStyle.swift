//
//  CaptureChromeStyle.swift
//  MacPilot
//
//  The visual language of the capture *tool*: the post-selection toolbar
//  (`AreaSelectionActionBar`) and the annotation controls living inside it.  An
//  adaptive `windowBackgroundColor` card with a hairline `labelColor` stroke, a
//  soft downward shadow and circular glyph chips is right for a surface the user
//  is still driving.  Because the fills are semantic, the native controls
//  embedded in the card (segmented switch, checkbox, colour well, slider)
//  resolve to the same appearance as the card itself.
//
//  A pinned screenshot is not a tool — it is a floating picture that happens to
//  have controls — and it styles itself from `PinnedScreenshotChromeStyle`
//  instead.  Nothing under `SnapzyQuickAccess` reads this file, and the pin- and
//  capture-chrome tests exist to keep that boundary from silently re-forming.
//
//  One family deliberately has no tokens here: the scrim capsules drawn directly
//  over the frozen image (the size read-out, the magnifier).  Those stay dark
//  and translucent because they sit on unknown content and must not invert with
//  the appearance.
//

import AppKit

enum CaptureChromeStyle {
  // MARK: - Geometry

  /// Side of a circular tool chip, and the height of a card row.
  static let chipSide: CGFloat = 28
  static var chipCornerRadius: CGFloat { chipSide / 2 }
  static let cardCornerRadius: CGFloat = 10

  /// Elevation of a card at rest.  SwiftUI writes these as `y: 2` (down);
  /// a layer in a non-flipped view needs the negated offset.
  static let shadowOffset = CGSize(width: 0, height: -2)
  static let shadowRadius: CGFloat = 6
  static let shadowOpacity: Double = 0.12

  // MARK: - Card

  static var cardFill: NSColor { NSColor.windowBackgroundColor.withAlphaComponent(0.94) }
  static var cardStroke: NSColor { NSColor.labelColor.withAlphaComponent(0.08) }

  // MARK: - Chip

  /// Chip sitting *inside* a card: same colour as the card would make it
  /// disappear, so the resting fill is a translucent contrast wash that
  /// lightens on a dark card and darkens on a light one.
  static var chipFillOnCard: NSColor { NSColor.quaternaryLabelColor }
  static var chipFillActive: NSColor { NSColor.controlAccentColor }
  static var chipStroke: NSColor { NSColor.labelColor.withAlphaComponent(0.1) }

  // MARK: - Glyphs

  static var glyph: NSColor { NSColor.labelColor }
  static var glyphOnAccent: NSColor { NSColor.white }
  static var glyphMuted: NSColor { NSColor.secondaryLabelColor }
  static var glyphFaint: NSColor { NSColor.tertiaryLabelColor }

  /// Ring around a colour swatch that is not selected.  The preset palette
  /// contains both a white and a black swatch, so the ring has to survive being
  /// drawn on a card of either tone.
  static var swatchRing: NSColor { NSColor.labelColor.withAlphaComponent(0.3) }
}
