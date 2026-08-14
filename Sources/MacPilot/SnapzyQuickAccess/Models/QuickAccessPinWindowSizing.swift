//
//  QuickAccessPinWindowSizing.swift
//  Snapzy
//
//  Sizing policy for pinned screenshot windows.
//

import AppKit
import Foundation

enum QuickAccessPinWindowSizing {
  static let minimumInteractiveSize = CGSize(width: 240, height: 180)

  private static let absoluteMaxSize = CGSize(width: 1440, height: 920)
  private static let screenMaxRatio: CGFloat = 0.78
  private static let screenMargin: CGFloat = 24

  static func sizes(for imageSize: CGSize, on screen: NSScreen) -> (base: CGSize, max: CGSize) {
    sizes(for: imageSize, visibleSize: screen.visibleFrame.size)
  }

  static func sizes(for imageSize: CGSize, visibleSize: CGSize) -> (base: CGSize, max: CGSize) {
    let sourceSize = CGSize(width: max(imageSize.width, 1), height: max(imageSize.height, 1))
    let maxSize = CGSize(
      width: min(absoluteMaxSize.width, visibleSize.width * screenMaxRatio),
      height: min(absoluteMaxSize.height, visibleSize.height * screenMaxRatio)
    )
    let maxFitScale = min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height)
    let minFitScale = max(
      minimumInteractiveSize.width / sourceSize.width,
      minimumInteractiveSize.height / sourceSize.height
    )
    let preferredScale = max(1, minFitScale)
    let normalizedScale = min(preferredScale, maxFitScale)
    let fittedSize = CGSize(width: sourceSize.width * normalizedScale, height: sourceSize.height * normalizedScale)
    let baseSize = CGSize(
      width: min(max(fittedSize.width, minimumInteractiveSize.width), maxSize.width),
      height: min(max(fittedSize.height, minimumInteractiveSize.height), maxSize.height)
    )
    return (baseSize, maxSize)
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
