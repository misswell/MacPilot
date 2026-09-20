//
//  QuickAccessPinWindowState.swift
//  Snapzy
//
//  Observable state for independent pinned screenshot windows.
//

import AppKit
import Combine
import Foundation

/// The single pinned-window model. A pin holds either an image (a screenshot or
/// a pasted clipboard image) or clipboard text; the text case has no file to
/// drag out and nothing to zoom, so the chrome adapts via `supportsZoom`.
@MainActor
final class QuickAccessPinWindowState: ObservableObject {
  let id: UUID

  @Published private(set) var url: URL?
  @Published private(set) var image: NSImage?
  @Published private(set) var thumbnail: NSImage?
  @Published private(set) var text: String?
  @Published var isLocked = false
  @Published var isMouseInside = false
  @Published private(set) var zoomFactor: CGFloat = 1

  private(set) var baseSize: CGSize
  private(set) var maxSize: CGSize

  private let absoluteMinimumZoomFactor: CGFloat = 0.4

  /// Image pins can be zoomed; a text pin has no raster to scale.
  var supportsZoom: Bool { image != nil }

  var isText: Bool { text != nil }

  /// Image pin. `url` supplies the drag-out file name/extension and may be a
  /// reserved temp path that is only written when the user actually drags.
  init(id: UUID, url: URL?, image: NSImage, thumbnail: NSImage, baseSize: CGSize, maxSize: CGSize) {
    self.id = id
    self.url = url
    self.image = image
    self.thumbnail = thumbnail
    self.text = nil
    self.baseSize = baseSize
    self.maxSize = maxSize
  }

  /// Text pin (clipboard text pasted onto the screen).
  init(id: UUID, text: String, baseSize: CGSize) {
    self.id = id
    self.url = nil
    self.image = nil
    self.thumbnail = nil
    self.text = text
    self.baseSize = baseSize
    self.maxSize = baseSize
  }

  var displaySize: CGSize {
    CGSize(width: baseSize.width * zoomFactor, height: baseSize.height * zoomFactor)
  }

  var zoomPercent: Int {
    Int((zoomFactor * 100).rounded())
  }

  /// Scrubber bounds: both ends round inwards so every value it offers is one
  /// the clamp can actually reach, current scale included.
  var zoomScrubRange: ClosedRange<Int> {
    let current = zoomPercent
    let lower = min(current, Int((minimumZoomFactor * 100).rounded(.up)))
    let upper = max(current, Int((maximumZoomFactor * 100).rounded(.down)))
    return lower...upper
  }

  var minimumZoomFactor: CGFloat {
    guard supportsZoom, baseSize.width > 0, baseSize.height > 0 else { return 1 }
    let interactiveSize = QuickAccessPinWindowSizing.minimumInteractiveSize
    let interactiveFloor = max(
      interactiveSize.width / baseSize.width,
      interactiveSize.height / baseSize.height
    )
    let floor = max(absoluteMinimumZoomFactor, interactiveFloor)
    return min(floor, maximumZoomFactor)
  }

  var maximumZoomFactor: CGFloat {
    guard supportsZoom, baseSize.width > 0, baseSize.height > 0 else { return 1 }
    let screenLimit = min(maxSize.width / baseSize.width, maxSize.height / baseSize.height)
    return max(1, min(2, screenLimit))
  }

  func setZoomPercent(_ percent: Int) -> CGSize {
    setZoomFactor(CGFloat(percent) / 100)
  }

  func resetZoom() -> CGSize {
    setZoomFactor(1)
  }

  func applyZoomStep(_ step: CGFloat) -> CGSize {
    guard step.isFinite, step != 0 else { return displaySize }
    return setZoomFactor(zoomFactor + step)
  }

  /// Replace the pinned bitmap in place (used after in-pin annotation).
  func updateImage(_ image: NSImage) {
    self.image = image
    self.thumbnail = image
  }

  func update(url: URL, image: NSImage, thumbnail: NSImage, baseSize: CGSize, maxSize: CGSize) -> CGSize {
    self.url = url
    self.image = image
    self.thumbnail = thumbnail
    return updateSizing(baseSize: baseSize, maxSize: maxSize)
  }

  func updateSizing(baseSize: CGSize, maxSize: CGSize) -> CGSize {
    self.baseSize = baseSize
    self.maxSize = maxSize
    zoomFactor = clampedZoomFactor(zoomFactor)
    return displaySize
  }

  func updateZoomFactor(_ factor: CGFloat) {
    zoomFactor = clampedZoomFactor(factor)
  }

  @discardableResult
  private func setZoomFactor(_ factor: CGFloat) -> CGSize {
    guard supportsZoom else { return displaySize }
    zoomFactor = clampedZoomFactor(factor)
    return displaySize
  }

  func clampedZoomFactor(_ factor: CGFloat) -> CGFloat {
    guard supportsZoom else { return 1 }
    return min(max(factor, minimumZoomFactor), maximumZoomFactor)
  }
}

/// Layout policy for clipboard-text pins, mirroring the text bubble the pin
/// window used to render itself before the two pin paths were unified.
@MainActor
enum QuickAccessPinTextMetrics {
  static let font = NSFont.systemFont(ofSize: 14, weight: .regular)
  static let maximumTextWidth: CGFloat = 360
  static let padding: CGFloat = 14
  /// Top inset reserved for the pin's close/lock chrome so a text pin never
  /// renders its first line underneath those buttons.
  static let chromeBand: CGFloat = 40
  static let minimumSize = CGSize(width: 140, height: 78)

  static func baseSize(for text: String) -> CGSize {
    let measured = (text as NSString).boundingRect(
      with: NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font]
    ).size
    return CGSize(
      width: max(minimumSize.width, ceil(measured.width) + padding * 2),
      height: max(minimumSize.height, ceil(measured.height) + padding + chromeBand)
    )
  }
}
