//
//  QuickAccessSound.swift
//  Snapzy
//
//  Sound feedback for QuickAccess actions - CleanShot X inspired
//

import AppKit

/// Sound effects for QuickAccess interactions
enum QuickAccessSound {
  case appear
  case dismiss
  case copy
  case save
  case delete
  case complete
  case failed

  // MARK: - Pre-cached sounds for instant playback (avoid disk loading on each play)
  // NSSound's Sendable annotation differs between the SDKs used by local
  // development and CI. The cache is written once at startup and only ever
  // read afterwards, so it sits behind one explicit unchecked-Sendable boundary.
  private final class SoundCache: @unchecked Sendable {
    let sounds: [String: NSSound]

    init() {
      var sounds: [String: NSSound] = [:]
      let soundNames = ["Pop", "Blow", "Funk", "Glass", "Basso"]
      for name in soundNames {
        if let sound = NSSound(named: name) {
          sounds[name] = sound
        }
      }
      self.sounds = sounds
    }
  }

  private static let cachedSounds = SoundCache()

  // MARK: - Playback

  private static func cachedSound(named name: String) -> NSSound? {
    cachedSounds.sounds[name]
  }

  /// Play the sound effect asynchronously (non-blocking)
  /// - Parameter reduceMotion: When true, sounds are disabled for accessibility
  func play(reduceMotion: Bool = false) {
    guard !reduceMotion else { return }
    let soundsEnabled = UserDefaults.standard.object(forKey: PreferencesKeys.playSounds) as? Bool ?? true
    guard soundsEnabled else { return }
    let soundName = self.soundName
    let vol = self.volume
    // Fire-and-forget async playback - never blocks UI
    DispatchQueue.global(qos: .userInteractive).async {
      guard let sound = Self.cachedSound(named: soundName)?.copy() as? NSSound else { return }
      sound.volume = vol
      sound.play()
    }
  }

  /// Sound name for cache lookup
  private var soundName: String {
    switch self {
    case .appear, .copy, .save:
      return "Pop"
    case .dismiss:
      return "Blow"
    case .delete:
      return "Funk"
    case .complete:
      return "Glass"
    case .failed:
      return "Basso"
    }
  }

  /// Volume level for this sound (0.0 - 1.0)
  private var volume: Float {
    switch self {
    case .appear:
      return 0.3
    case .dismiss:
      return 0.4
    case .copy:
      return 0.5
    case .save:
      return 0.4
    case .delete:
      return 0.3
    case .complete:
      return 0.3
    case .failed:
      return 0.4
    }
  }
}
