//
//  SmartCaptureOutputStyling.swift
//  MacPilot's iShot-style output post-processing.
//
//  The 圆角截图 / 阴影或边框 side-bar toggles are applied when the capture is
//  committed, so the frozen backdrop and the annotation canvas stay untouched
//  while the session is live and only the delivered image carries the style.
//

import AppKit
import CoreGraphics

nonisolated enum SmartCaptureOutputStyling {
  /// Applies the side-bar output style. `scaleFactor` converts point-based
  /// radii into the output image's pixel space.
  static func apply(
    to image: CGImage,
    style: SmartCaptureOutputStyle,
    scaleFactor: CGFloat
  ) -> CGImage {
    guard style.roundedCorners || style.shadow else { return image }
    let scale = max(1, scaleFactor)
    var output = image
    if style.roundedCorners {
      let radius = max(2, style.cornerRadius * scale)
      output = roundedCorners(output, radius: radius) ?? output
    }
    if style.shadow {
      output = dropShadow(output, scale: scale) ?? output
    }
    return output
  }

  /// Clips the image to a rounded rectangle; corner pixels become transparent
  /// and the canvas size is unchanged.
  static func roundedCorners(_ image: CGImage, radius: CGFloat) -> CGImage? {
    guard radius > 0 else { return image }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let context = CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    )
    context.clip()
    context.draw(image, in: rect)
    return context.makeImage()
  }

  /// Composites the image onto a larger transparent canvas with a soft drop
  /// shadow beneath it (iShot's 阴影或边框).
  static func dropShadow(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let padding = (18.0 * scale).rounded()
    let width = Int(CGFloat(image.width) + padding * 2)
    let height = Int(CGFloat(image.height) + padding * 2)
    guard width > 0, height > 0,
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    let contentRect = CGRect(
      x: padding,
      y: padding,
      width: CGFloat(image.width),
      height: CGFloat(image.height)
    )
    context.saveGState()
    context.setShadow(
      offset: CGSize(width: 0, height: (-4.0 * scale).rounded()),
      blur: (16.0 * scale).rounded(),
      color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    context.setFillColor(NSColor.black.cgColor)
    context.fill(contentRect)
    context.restoreGState()
    context.draw(image, in: contentRect)
    return context.makeImage()
  }
}
