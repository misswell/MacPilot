//
//  CaptureChromeStyle.swift
//  MacPilot
//
//  The single visual language for the floating capture surfaces: the
//  post-selection toolbar (`AreaSelectionActionBar`) and the pinned-screenshot
//  window's chrome (`QuickAccessPinWindowView`).  Both read their geometry,
//  fills, strokes and shadows from here, so one retune moves both.
//
//  Two families live here, and the split is deliberate:
//
//  - **card + chip** — a tool surface.  An adaptive `windowBackgroundColor`
//    card with a hairline `labelColor` stroke and a soft downward shadow,
//    carrying circular glyph chips.  Used by the selection toolbar and by the
//    pin's corner buttons and drag handle.  Because the fills are semantic,
//    the native controls embedded in the card (segmented switch, checkbox,
//    colour well, slider) resolve to the same appearance as the card itself.
//  - **scrim capsule** — a badge drawn *directly over the frozen image* (the
//    pin's zoom scrubber, the size read-out, the magnifier).  Those stay dark
//    and translucent: they sit on unknown content and must not invert with the
//    appearance.  This file deliberately has no tokens for them.
//

import AppKit

enum CaptureChromeStyle {
  // MARK: - Geometry

  /// Side of a circular tool chip, and the height of a card row.
  static let chipSide: CGFloat = 28
  static var chipCornerRadius: CGFloat { chipSide / 2 }
  static let cardCornerRadius: CGFloat = 10

  /// Rest and emphasised elevation.  SwiftUI writes these as `y: 2` (down);
  /// a layer in a non-flipped view needs the negated offset.
  static let shadowOffset = CGSize(width: 0, height: -2)
  static let shadowRadius: CGFloat = 6
  static let shadowOpacity: Double = 0.12
  static let emphasizedShadowRadius: CGFloat = 7
  static let emphasizedShadowOpacity: Double = 0.18

  // MARK: - Card

  static var cardFill: NSColor { NSColor.windowBackgroundColor.withAlphaComponent(0.94) }
  static var cardFillEmphasized: NSColor { NSColor.windowBackgroundColor.withAlphaComponent(0.97) }
  static var cardStroke: NSColor { NSColor.labelColor.withAlphaComponent(0.08) }
  static var cardStrokeEmphasized: NSColor { NSColor.labelColor.withAlphaComponent(0.16) }

  // MARK: - Chip

  /// Chip floating over image content.
  static var chipFill: NSColor { NSColor.windowBackgroundColor.withAlphaComponent(0.84) }
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
