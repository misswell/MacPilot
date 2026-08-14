//
//  BackdropTransitionEffect.swift
//  Snapzy
//
//  Self-contained, removable crossfade effect for area-selection backdrop updates.
//
//  Removal: set `isEnabled = false` (instant swap everywhere) or
//  delete this file + drop the `animated:` parameter on `AreaSelectionOverlayView.applyBackdrop`.
//

import AppKit
import QuartzCore

enum BackdropTransitionEffect {

  /// Master switch. `false` == current instant hard-swap behavior.
  static let isEnabled = false

  /// Crossfade duration (seconds). Matches app-wide 0.22s motion precedent.
  static let duration: CFTimeInterval = 0.22

  private static let animationKey = "backdropCrossfade"

  /// Returns `true` when a crossfade should run for this backdrop apply.
  ///
  /// - `isReapplication`: a backdrop image was already shown for this display overlay.
  /// - `isVisible`: the incoming backdrop will be rendered (not invisible/luma-only).
  @MainActor
  static func shouldCrossfade(isReapplication: Bool, isVisible: Bool) -> Bool {
    guard isEnabled, isReapplication, isVisible else { return false }
    return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// Adds an explicit fade transition to `layer`.
  /// The caller must NOT wrap the subsequent `contents` assignment in a disabled-actions
  /// transaction — the explicit transition drives the change.
  @MainActor
  static func addCrossfade(to layer: CALayer) {
    let transition = CATransition()
    transition.type = .fade
    transition.duration = duration
    transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(transition, forKey: animationKey)
  }
}
