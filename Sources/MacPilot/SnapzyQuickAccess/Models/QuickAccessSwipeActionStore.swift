//
//  QuickAccessSwipeActionStore.swift
//  Snapzy
//
//  Persisted per-direction swipe action configuration for Quick Access cards.
//

import Combine
import Foundation

/// Tracks which direction a trackpad swipe was resolved to.
enum QuickAccessSwipeDirection: String, CaseIterable, Codable, Identifiable {
  case left
  case right

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .left:
      return L10n.PreferencesQuickAccess.swipeLeftAction
    case .right:
      return L10n.PreferencesQuickAccess.swipeRightAction
    }
  }

  var systemImage: String {
    switch self {
    case .left:
      return "arrow.left"
    case .right:
      return "arrow.right"
    }
  }
}

@MainActor
final class QuickAccessSwipeActionStore: ObservableObject {
  static let shared = QuickAccessSwipeActionStore()

  @Published private(set) var swipeLeftAction: QuickAccessActionKind?
  @Published private(set) var swipeRightAction: QuickAccessActionKind?

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    if let rawValue = defaults.string(forKey: PreferencesKeys.quickAccessSwipeLeftAction) {
      if rawValue == "none" {
        self.swipeLeftAction = nil
      } else {
        self.swipeLeftAction = QuickAccessActionKind(rawValue: rawValue)
      }
    } else {
      self.swipeLeftAction = .dismiss
    }

    if let rawValue = defaults.string(forKey: PreferencesKeys.quickAccessSwipeRightAction) {
      if rawValue == "none" {
        self.swipeRightAction = nil
      } else {
        self.swipeRightAction = QuickAccessActionKind(rawValue: rawValue)
      }
    } else {
      self.swipeRightAction = .dismiss
    }
  }

  func action(for direction: QuickAccessSwipeDirection) -> QuickAccessActionKind? {
    switch direction {
    case .left:
      return swipeLeftAction
    case .right:
      return swipeRightAction
    }
  }

  func setAction(_ direction: QuickAccessSwipeDirection, action: QuickAccessActionKind?) {
    switch direction {
    case .left:
      guard swipeLeftAction != action else { return }
      swipeLeftAction = action
      if let action {
        defaults.set(action.rawValue, forKey: PreferencesKeys.quickAccessSwipeLeftAction)
      } else {
        defaults.set("none", forKey: PreferencesKeys.quickAccessSwipeLeftAction)
      }
    case .right:
      guard swipeRightAction != action else { return }
      swipeRightAction = action
      if let action {
        defaults.set(action.rawValue, forKey: PreferencesKeys.quickAccessSwipeRightAction)
      } else {
        defaults.set("none", forKey: PreferencesKeys.quickAccessSwipeRightAction)
      }
    }
  }

  func resetToDefaults() {
    setAction(.left, action: .dismiss)
    setAction(.right, action: .dismiss)
  }
}
