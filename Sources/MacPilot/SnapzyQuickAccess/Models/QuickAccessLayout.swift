//
//  QuickAccessLayout.swift
//  Snapzy
//
//  Centralized layout constants for QuickAccess panel
//

import Foundation

/// Centralized layout constants for QuickAccess panel
/// Single source of truth for dimensions used by Manager and StackView
enum QuickAccessLayout {
  /// Base width of panel content area (matches card container width)
  static let cardWidth: CGFloat = 180

  /// Base height of each card slot in the panel
  static let cardHeight: CGFloat = 112

  /// Scaled card width based on user overlay scale setting
  static func scaledCardWidth(_ scale: CGFloat) -> CGFloat { cardWidth * scale }

  /// Scaled card height based on user overlay scale setting
  static func scaledCardHeight(_ scale: CGFloat) -> CGFloat { cardHeight * scale }

  /// Vertical spacing between cards
  static let cardSpacing: CGFloat = 8

  /// Padding around the card stack (12pt for shadow clearance: radius 8 + y-offset 4)
  static let containerPadding: CGFloat = 12

  // MARK: - Depth Stacking (CleanShot X style)

  /// Scale reduction per card in stack (each card 5% smaller than previous)
  static let depthScaleStep: CGFloat = 0.05

  /// Vertical offset per card in stack (cards stack upward)
  static let depthOffsetStep: CGFloat = -8

  /// Parallax push distance when hovering a card
  static let depthParallaxPush: CGFloat = 4

  /// Opacity of the oldest (bottom) card in stack
  static let maxDepthOpacity: CGFloat = 0.7

  /// Scale increase when card is hovered
  static let hoverScaleBoost: CGFloat = 1.02
}
