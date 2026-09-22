//
//  QuickAccessPinWindowSizing.swift
//  Snapzy
//
//  Sizing policy for pinned screenshot windows.
//

import AppKit
import Foundation

enum QuickAccessPinWindowSizing {
  /// The smallest size still worth zooming a large pin *down* to, below which the
  /// floating chrome has nowhere to sit. It is not a floor for the size a pin
  /// opens at — a small capture stays small.
  static let minimumInteractiveSize = CGSize(width: 240, height: 180)

  private static let screenMargin: CGFloat = 24

  static func sizes(for imageSize: CGSize, on screen: NSScreen) -> (base: CGSize, max: CGSize) {
    sizes(for: imageSize, visibleSize: screen.visibleFrame.size)
  }

  /// Actual size: the pin opens at the image's own point size and only ever
  /// shrinks, and then only because the screen cannot hold that many points.
  static func sizes(for imageSize: CGSize, visibleSize: CGSize) -> (base: CGSize, max: CGSize) {
    let sourceSize = CGSize(width: max(imageSize.width, 1), height: max(imageSize.height, 1))
    let maxSize = CGSize(
      width: max(1, visibleSize.width - screenMargin * 2),
      height: max(1, visibleSize.height - screenMargin * 2)
    )
    let fitScale = min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height)
    let scale = min(1, fitScale)
    return (
      CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale),
      maxSize
    )
  }

  static func centeredFrame(size: CGSize, on screen: NSScreen) -> NSRect {
    let visibleFrame = screen.visibleFrame
    return NSRect(
      x: visibleFrame.midX - size.width / 2,
      y: visibleFrame.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  static func constrainedFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
    constrainedFrame(frame, visibleFrame: screen.visibleFrame)
  }

  static func constrainedFrame(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
    let bounds = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
    let width = min(frame.width, max(bounds.width, 1))
    let height = min(frame.height, max(bounds.height, 1))
    return NSRect(
      x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
      y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
      width: width,
      height: height
    )
  }
}
