//
//  QuickAccessItem.swift
//  Snapzy
//
//  Data model for a captured item (screenshot or video) in the quick access stack
//

import AppKit
import Foundation

/// Type of quick access item
enum QuickAccessItemType: Equatable {
  case screenshot
  case video
}

/// Processing state for quick access item (annotation, conversion, etc.)
enum QuickAccessProcessingState: Equatable {
  case idle
  case processing(progress: Double?)  // nil = indeterminate
  case complete
  case failed

  var isProcessing: Bool {
    if case .processing = self { return true }
    return false
  }
}

/// Represents a single item (screenshot or video) in the quick access preview stack
struct QuickAccessItem: Identifiable, Equatable {
  let id: UUID
  var url: URL
  var thumbnail: NSImage
  let capturedAt: Date
  let itemType: QuickAccessItemType
  let duration: TimeInterval?
  var processingState: QuickAccessProcessingState = .idle
  /// Incremented when thumbnail changes — used by SwiftUI to detect visual updates
  var thumbnailVersion: UUID
  /// Cloud URL after successful upload (nil if not uploaded)
  var cloudURL: URL?
  /// Cloud object key for overwrite uploads (nil if not uploaded)
  var cloudKey: String?
  /// True when image has changed since last cloud upload (needs re-upload)
  var isCloudStale: Bool = false
  /// True when the item should remain visible and bypass auto-dismiss
  var isPinned: Bool = false
  /// True if the item's corresponding Pin or Edit window is currently open
  var isWindowOpen: Bool = false
  /// The canonical artifact this card shows. Operations that read the file are
  /// gated on `artifactState`, never on "a URL exists".
  let artifactID: UUID
  let captureID: UUID
  var artifactState: CaptureArtifactState
  var artifactErrorDescription: String?
  /// True until the artifact is promoted into the user's export folder.
  var isTemporaryArtifact: Bool
  var pixelWidth: Int
  var pixelHeight: Int

  /// Initializer for screenshots (backward compatible)
  init(url: URL, thumbnail: NSImage) {
    self.id = UUID()
    self.url = url
    self.thumbnail = thumbnail
    self.capturedAt = Date()
    self.itemType = .screenshot
    self.duration = nil
    self.thumbnailVersion = UUID()
    self.cloudURL = nil
    self.cloudKey = nil
    self.isPinned = false
    self.isWindowOpen = false
    self.artifactID = UUID()
    self.captureID = UUID()
    self.artifactState = .ready
    self.artifactErrorDescription = nil
    self.isTemporaryArtifact = false
    self.pixelWidth = 0
    self.pixelHeight = 0
  }

  /// Initializer for videos with duration
  init(url: URL, thumbnail: NSImage, duration: TimeInterval) {
    self.id = UUID()
    self.url = url
    self.thumbnail = thumbnail
    self.capturedAt = Date()
    self.itemType = .video
    self.duration = duration
    self.thumbnailVersion = UUID()
    self.cloudURL = nil
    self.cloudKey = nil
    self.isPinned = false
    self.isWindowOpen = false
    self.artifactID = UUID()
    self.captureID = UUID()
    self.artifactState = .ready
    self.artifactErrorDescription = nil
    self.isTemporaryArtifact = false
    self.pixelWidth = 0
    self.pixelHeight = 0
  }

  /// Initializer for a capture whose file is still being written.
  init(
    url: URL,
    thumbnail: NSImage,
    artifactID: UUID,
    captureID: UUID,
    artifactState: CaptureArtifactState,
    isTemporaryArtifact: Bool,
    pixelWidth: Int,
    pixelHeight: Int
  ) {
    self.id = UUID()
    self.url = url
    self.thumbnail = thumbnail
    self.capturedAt = Date()
    self.itemType = .screenshot
    self.duration = nil
    self.thumbnailVersion = UUID()
    self.cloudURL = nil
    self.cloudKey = nil
    self.isPinned = false
    self.isWindowOpen = false
    self.artifactID = artifactID
    self.captureID = captureID
    self.artifactState = artifactState
    self.artifactErrorDescription = nil
    self.isTemporaryArtifact = isTemporaryArtifact
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }

  /// Initializer with explicit id (used for thumbnail retry updates)
  init(
    id: UUID,
    url: URL,
    thumbnail: NSImage,
    capturedAt: Date,
    itemType: QuickAccessItemType,
    duration: TimeInterval?,
    thumbnailVersion: UUID = UUID(),
    cloudURL: URL? = nil,
    cloudKey: String? = nil,
    isCloudStale: Bool = false,
    isPinned: Bool = false,
    isWindowOpen: Bool = false,
    artifactID: UUID = UUID(),
    captureID: UUID = UUID(),
    artifactState: CaptureArtifactState = .ready,
    artifactErrorDescription: String? = nil,
    isTemporaryArtifact: Bool = false,
    pixelWidth: Int = 0,
    pixelHeight: Int = 0
  ) {
    self.id = id
    self.url = url
    self.thumbnail = thumbnail
    self.capturedAt = capturedAt
    self.itemType = itemType
    self.duration = duration
    self.thumbnailVersion = thumbnailVersion
    self.cloudURL = cloudURL
    self.cloudKey = cloudKey
    self.isCloudStale = isCloudStale
    self.isPinned = isPinned
    self.isWindowOpen = isWindowOpen
    self.artifactID = artifactID
    self.captureID = captureID
    self.artifactState = artifactState
    self.artifactErrorDescription = artifactErrorDescription
    self.isTemporaryArtifact = isTemporaryArtifact
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }

  static func == (lhs: QuickAccessItem, rhs: QuickAccessItem) -> Bool {
    lhs.id == rhs.id && lhs.url == rhs.url && lhs.processingState == rhs.processingState
      && lhs.thumbnailVersion == rhs.thumbnailVersion && lhs.cloudURL == rhs.cloudURL
      && lhs.isCloudStale == rhs.isCloudStale && lhs.isPinned == rhs.isPinned
      && lhs.isWindowOpen == rhs.isWindowOpen && lhs.artifactState == rhs.artifactState
      && lhs.artifactErrorDescription == rhs.artifactErrorDescription
      && lhs.isTemporaryArtifact == rhs.isTemporaryArtifact
  }

  /// Whether this item is a video
  var isVideo: Bool {
    itemType == .video
  }

  /// File-backed actions are legal only once the artifact committed.
  var fileOperationsAllowed: Bool {
    QuickAccessOperationCoordinator.isFileReady(artifactState)
  }

  func allows(_ operation: QuickAccessFileOperation) -> Bool {
    QuickAccessOperationCoordinator.allows(operation, state: artifactState)
  }

  /// Formatted duration string for display (e.g., "01:30s")
  var formattedDuration: String? {
    guard let duration = duration, duration.isFinite, duration >= 0 else {
      return nil
    }
    let mins = Int(duration) / 60
    let secs = Int(duration) % 60
    return String(format: "%02d:%02ds", mins, secs)
  }
}
