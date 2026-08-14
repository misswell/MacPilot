//
//  FrozenAreaCaptureSession.swift
//  Snapzy (integrated into MacPilot)
//
//  Owns frozen display snapshots used for static area selection.
//

import Accelerate
import CoreGraphics
import Foundation

nonisolated struct FrozenDisplaySnapshot: @unchecked Sendable {
  let displayID: CGDirectDisplayID
  let screenFrame: CGRect
  let scaleFactor: CGFloat
  let colorSpaceName: CFString?
  let image: CGImage

  var pixelScaleFactor: CGFloat {
    let widthScale = screenFrame.width > 0 ? CGFloat(image.width) / screenFrame.width : 0
    let heightScale = screenFrame.height > 0 ? CGFloat(image.height) / screenFrame.height : 0
    let candidates = [widthScale, heightScale].filter { $0.isFinite && $0 > 0 }

    guard let imageScale = candidates.max() else {
      return max(scaleFactor, 1)
    }

    return imageScale
  }
}

nonisolated struct FrozenAreaCropResult {
  let image: CGImage
  let scaleFactor: CGFloat
  let screenRect: CGRect
}

nonisolated final class FrozenAreaCaptureSession {
  private static let sharpenPromotedOutputPixelLimit = 12_000_000

  private var snapshots: [CGDirectDisplayID: FrozenDisplaySnapshot]

  private init(snapshots: [CGDirectDisplayID: FrozenDisplaySnapshot]) {
    self.snapshots = snapshots
  }

  static func fromSnapshot(_ snapshot: FrozenDisplaySnapshot) -> FrozenAreaCaptureSession {
    FrozenAreaCaptureSession(snapshots: [snapshot.displayID: snapshot])
  }

  static func fromSnapshots(_ snapshots: [FrozenDisplaySnapshot]) -> FrozenAreaCaptureSession {
    var snapshotsByDisplayID: [CGDirectDisplayID: FrozenDisplaySnapshot] = [:]
    for snapshot in snapshots {
      snapshotsByDisplayID[snapshot.displayID] = snapshot
    }
    return FrozenAreaCaptureSession(snapshots: snapshotsByDisplayID)
  }

  @MainActor
  static func prepare(
    captureManager: SnapzyScreenCaptureManager? = nil,
    displayIDs: Set<CGDirectDisplayID>? = nil,
    showCursor: Bool,
    excludeDesktopIcons: Bool,
    excludeDesktopWidgets: Bool,
    excludeOwnApplication: Bool,
    prefetchedContentTask: ShareableContentPrefetchTask? = nil
  ) async throws -> FrozenAreaCaptureSession {
    let captureManager = captureManager ?? .shared
    let snapshots = try await captureManager.captureDisplaySnapshots(
      displayIDs: displayIDs,
      showCursor: showCursor,
      excludeDesktopIcons: excludeDesktopIcons,
      excludeDesktopWidgets: excludeDesktopWidgets,
      excludeOwnApplication: excludeOwnApplication,
      prefetchedContentTask: prefetchedContentTask
    )
    return FrozenAreaCaptureSession(snapshots: snapshots)
  }

  var backdrops: [CGDirectDisplayID: AreaSelectionBackdrop] {
    var result: [CGDirectDisplayID: AreaSelectionBackdrop] = [:]
    for (displayID, snapshot) in snapshots {
      result[displayID] = AreaSelectionBackdrop(
        displayID: displayID,
        image: snapshot.image,
        scaleFactor: snapshot.pixelScaleFactor
      )
    }
    return result
  }

  var displayIDs: Set<CGDirectDisplayID> {
    Set(snapshots.keys)
  }

  func containsSnapshot(for displayID: CGDirectDisplayID) -> Bool {
    snapshots[displayID] != nil
  }

  /// Value copy of the current snapshots, safe to hand to a detached task for
  /// off-main cropping (dictionaries are value types; later mutations of the
  /// session copy-on-write and never affect the returned value).
  func allSnapshots() -> [CGDirectDisplayID: FrozenDisplaySnapshot] {
    snapshots
  }

  func addSnapshot(_ snapshot: FrozenDisplaySnapshot) {
    snapshots[snapshot.displayID] = snapshot
  }

  func backdrop(for displayID: CGDirectDisplayID) -> AreaSelectionBackdrop? {
    guard let snapshot = snapshots[displayID] else { return nil }
    return AreaSelectionBackdrop(
      displayID: displayID,
      image: snapshot.image,
      scaleFactor: snapshot.pixelScaleFactor
    )
  }

  func missingSnapshotDisplayIDs(for displayIDs: Set<CGDirectDisplayID>) -> Set<CGDirectDisplayID> {
    Set(displayIDs.filter { snapshots[$0] == nil })
  }

  func cropImage(
    for selection: AreaSelectionResult,
    minimumOutputScaleFactor: CGFloat = 1
  ) throws -> FrozenAreaCropResult {
    try Self.cropImage(
      snapshots: snapshots,
      for: selection,
      minimumOutputScaleFactor: minimumOutputScaleFactor
    )
  }

  /// Heavy crop/scale-promote/sharpen pipeline, decoupled from session state so
  /// callers can run it off the main actor with a snapshots value copy.
  static func cropImage(
    snapshots: [CGDirectDisplayID: FrozenDisplaySnapshot],
    for selection: AreaSelectionResult,
    minimumOutputScaleFactor: CGFloat = 1
  ) throws -> FrozenAreaCropResult {
    guard let snapshot = snapshots[selection.displayID] else {
      throw ScreenCaptureError.captureFailed(AppText.value("scCaptureOutsideDisplay", language: .system))
    }
    let scaleFactor = snapshot.pixelScaleFactor

    let relativeRect = CGRect(
      x: selection.rect.origin.x - snapshot.screenFrame.origin.x,
      y: selection.rect.origin.y - snapshot.screenFrame.origin.y,
      width: selection.rect.width,
      height: selection.rect.height
    )
    let screenBounds = CGRect(
      x: 0,
      y: 0,
      width: snapshot.screenFrame.width,
      height: snapshot.screenFrame.height
    )
    let clampedRect = relativeRect.intersection(screenBounds)
    guard !clampedRect.isEmpty else {
      throw ScreenCaptureError.captureFailed(AppText.value("scCaptureOutsideDisplay", language: .system))
    }

    let alignedRect = Self.pixelAlignedRect(
      clampedRect,
      scaleFactor: scaleFactor,
      bounds: screenBounds
    )
    guard !alignedRect.isEmpty else {
      throw ScreenCaptureError.captureFailed(AppText.value("scCaptureOutsideDisplay", language: .system))
    }

    let flippedY = snapshot.screenFrame.height - alignedRect.origin.y - alignedRect.height
    let pixelCropRect = CGRect(
      x: (alignedRect.origin.x * scaleFactor).rounded(),
      y: (flippedY * scaleFactor).rounded(),
      width: CGFloat(max(1, Int((alignedRect.width * scaleFactor).rounded()))),
      height: CGFloat(max(1, Int((alignedRect.height * scaleFactor).rounded())))
    ).intersection(
      CGRect(
        x: 0,
        y: 0,
        width: snapshot.image.width,
        height: snapshot.image.height
      )
    )

    guard let croppedImage = snapshot.image.cropping(to: pixelCropRect), !pixelCropRect.isEmpty else {
      throw ScreenCaptureError.captureFailed(AppText.value("scCaptureCropFailed", language: .system))
    }

    let alignedScreenRect = CGRect(
      x: snapshot.screenFrame.origin.x + alignedRect.origin.x,
      y: snapshot.screenFrame.origin.y + alignedRect.origin.y,
      width: alignedRect.width,
      height: alignedRect.height
    )

    let promotedImage = Self.imageByPromotingScaleIfNeeded(
      croppedImage,
      logicalSize: alignedScreenRect.size,
      sourceScaleFactor: scaleFactor,
      minimumOutputScaleFactor: minimumOutputScaleFactor,
      colorSpaceName: snapshot.colorSpaceName
    )

    return FrozenAreaCropResult(
      image: promotedImage.image,
      scaleFactor: promotedImage.scaleFactor,
      screenRect: alignedScreenRect
    )
  }

  func cropCompositeImage(
    for selection: AreaSelectionResult,
    minimumOutputScaleFactor: CGFloat = 1
  ) throws -> FrozenAreaCropResult {
    try Self.cropCompositeImage(
      snapshots: snapshots,
      for: selection,
      minimumOutputScaleFactor: minimumOutputScaleFactor
    )
  }

  /// Heavy multi-display composite pipeline, decoupled from session state so
  /// callers can run it off the main actor with a snapshots value copy.
  static func cropCompositeImage(
    snapshots: [CGDirectDisplayID: FrozenDisplaySnapshot],
    for selection: AreaSelectionResult,
    minimumOutputScaleFactor: CGFloat = 1
  ) throws -> FrozenAreaCropResult {
    let requestedSelectionRect = selection.rect
    let requestedDisplayIDs = selection.displayIDs.isEmpty ? [selection.displayID] : selection.displayIDs
    let candidateSnapshots = snapshots.values.filter { snapshot in
      requestedDisplayIDs.contains(snapshot.displayID) && snapshot.screenFrame.intersects(requestedSelectionRect)
    }

    guard !candidateSnapshots.isEmpty else {
      throw ScreenCaptureError.captureFailed(AppText.value("scCaptureOutsideDisplay", language: .system))
    }

    let sourceScaleFactor = candidateSnapshots.map(\.pixelScaleFactor).max() ?? 1.0
    let outputScaleFactor = max(sourceScaleFactor, minimumOutputScaleFactor)
    let captureBounds = candidateSnapshots.reduce(CGRect.null) { partialResult, snapshot in
      partialResult.union(snapshot.screenFrame)
    }
    let selectionRect = Self.pixelAlignedRect(
      requestedSelectionRect.intersection(captureBounds),
      scaleFactor: outputScaleFactor,
      bounds: captureBounds
    )
    guard !selectionRect.isEmpty else {
      throw ScreenCaptureError.captureFailed(AppText.value("scCaptureOutsideDisplay", language: .system))
    }

    let matchingSnapshots = candidateSnapshots.filter { snapshot in
      snapshot.screenFrame.intersects(selectionRect)
    }
    guard !matchingSnapshots.isEmpty else {
      throw ScreenCaptureError.captureFailed(AppText.value("scCaptureOutsideDisplay", language: .system))
    }

    let outputWidth = max(1, Int((selectionRect.width * outputScaleFactor).rounded()))
    let outputHeight = max(1, Int((selectionRect.height * outputScaleFactor).rounded()))
    let colorSpace = matchingSnapshots
      .compactMap { Self.colorSpace(from: $0.colorSpaceName) }
      .first ?? CGColorSpaceCreateDeviceRGB()

    guard let context = CGContext(
      data: nil,
      width: outputWidth,
      height: outputHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw ScreenCaptureError.captureFailed(AppText.value("scCaptureCropFailed", language: .system))
    }

    context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    context.interpolationQuality = .none

    for snapshot in matchingSnapshots {
      let snapshotScaleFactor = snapshot.pixelScaleFactor
      let screenBounds = CGRect(
        x: 0,
        y: 0,
        width: snapshot.screenFrame.width,
        height: snapshot.screenFrame.height
      )
      let intersection = selectionRect.intersection(snapshot.screenFrame)
      let relativeRect = CGRect(
        x: intersection.origin.x - snapshot.screenFrame.origin.x,
        y: intersection.origin.y - snapshot.screenFrame.origin.y,
        width: intersection.width,
        height: intersection.height
      )
      let alignedRect = Self.pixelAlignedRect(
        relativeRect,
        scaleFactor: snapshotScaleFactor,
        bounds: screenBounds
      )
      guard !alignedRect.isEmpty else { continue }

      let flippedY = snapshot.screenFrame.height - alignedRect.origin.y - alignedRect.height
      let pixelCropRect = CGRect(
        x: (alignedRect.origin.x * snapshotScaleFactor).rounded(),
        y: (flippedY * snapshotScaleFactor).rounded(),
        width: CGFloat(max(1, Int((alignedRect.width * snapshotScaleFactor).rounded()))),
        height: CGFloat(max(1, Int((alignedRect.height * snapshotScaleFactor).rounded())))
      ).intersection(
        CGRect(
          x: 0,
          y: 0,
          width: snapshot.image.width,
          height: snapshot.image.height
        )
      )

      guard let croppedImage = snapshot.image.cropping(to: pixelCropRect), !pixelCropRect.isEmpty else {
        continue
      }

      let alignedScreenRect = CGRect(
        x: snapshot.screenFrame.origin.x + alignedRect.origin.x,
        y: snapshot.screenFrame.origin.y + alignedRect.origin.y,
        width: alignedRect.width,
        height: alignedRect.height
      )
      let requestedDestinationRect = CGRect(
        x: (alignedScreenRect.minX - selectionRect.minX) * outputScaleFactor,
        y: (alignedScreenRect.minY - selectionRect.minY) * outputScaleFactor,
        width: alignedScreenRect.width * outputScaleFactor,
        height: alignedScreenRect.height * outputScaleFactor
      ).integral
      let needsSnapshotPromotion = outputScaleFactor > snapshotScaleFactor + 0.0001
      let imageToDraw: CGImage
      let didPromoteSnapshot: Bool
      if needsSnapshotPromotion {
        let promotedImage = Self.imageByPromotingScaleIfNeeded(
          croppedImage,
          logicalSize: alignedScreenRect.size,
          sourceScaleFactor: snapshotScaleFactor,
          minimumOutputScaleFactor: outputScaleFactor,
          colorSpaceName: snapshot.colorSpaceName
        )
        imageToDraw = promotedImage.image
        didPromoteSnapshot = promotedImage.scaleFactor > snapshotScaleFactor + 0.0001
      } else {
        imageToDraw = croppedImage
        didPromoteSnapshot = false
      }
      context.interpolationQuality = needsSnapshotPromotion && !didPromoteSnapshot ? .high : .none
      let destinationRect = didPromoteSnapshot
        ? CGRect(
          x: requestedDestinationRect.origin.x,
          y: requestedDestinationRect.origin.y,
          width: CGFloat(imageToDraw.width),
          height: CGFloat(imageToDraw.height)
        )
        : requestedDestinationRect
      context.draw(imageToDraw, in: destinationRect)
    }

    guard let renderedImage = context.makeImage() else {
      throw ScreenCaptureError.captureFailed(AppText.value("scCaptureCropFailed", language: .system))
    }

    return FrozenAreaCropResult(
      image: renderedImage,
      scaleFactor: outputScaleFactor,
      screenRect: selectionRect
    )
  }

  func invalidate() {
    snapshots.removeAll()
  }

  private static func pixelAlignedRect(
    _ rect: CGRect,
    scaleFactor: CGFloat,
    bounds: CGRect
  ) -> CGRect {
    guard scaleFactor > 0 else { return rect.intersection(bounds) }

    let minX = floor(rect.minX * scaleFactor) / scaleFactor
    let minY = floor(rect.minY * scaleFactor) / scaleFactor
    let maxX = ceil(rect.maxX * scaleFactor) / scaleFactor
    let maxY = ceil(rect.maxY * scaleFactor) / scaleFactor

    return CGRect(
      x: minX,
      y: minY,
      width: max(0, maxX - minX),
      height: max(0, maxY - minY)
    ).intersection(bounds)
  }

  static func imageByPromotingScaleIfNeeded(
    _ image: CGImage,
    logicalSize: CGSize,
    sourceScaleFactor: CGFloat,
    minimumOutputScaleFactor: CGFloat,
    colorSpaceName: CFString?
  ) -> (image: CGImage, scaleFactor: CGFloat) {
    let outputScaleFactor = max(sourceScaleFactor, minimumOutputScaleFactor)
    let targetWidth = max(1, Int((logicalSize.width * outputScaleFactor).rounded()))
    let targetHeight = max(1, Int((logicalSize.height * outputScaleFactor).rounded()))

    guard outputScaleFactor > sourceScaleFactor + 0.0001,
          targetWidth != image.width || targetHeight != image.height,
          let scaledImage = scaledImage(
            image,
            width: targetWidth,
            height: targetHeight,
            colorSpaceName: colorSpaceName
          )
    else {
      return (image, sourceScaleFactor)
    }

    return (scaledImage, outputScaleFactor)
  }

  static func sharpenPromotedImageIfUseful(
    _ image: CGImage,
    colorSpaceName: CFString?
  ) -> CGImage {
    let pixelCount = image.width * image.height
    guard pixelCount > 0,
          pixelCount <= sharpenPromotedOutputPixelLimit,
          let sharpenedImage = sharpenedImage(image, colorSpaceName: colorSpaceName)
    else {
      return image
    }

    return sharpenedImage
  }

  private static func scaledImage(
    _ image: CGImage,
    width: Int,
    height: Int,
    colorSpaceName: CFString?
  ) -> CGImage? {
    let colorSpace = colorSpace(from: colorSpaceName)
      ?? image.colorSpace
      ?? CGColorSpaceCreateDeviceRGB()

    if let acceleratedImage = acceleratedScaledImage(
      image,
      width: width,
      height: height,
      colorSpace: colorSpace
    ) {
      return sharpenPromotedImageIfUseful(acceleratedImage, colorSpaceName: colorSpaceName)
    }

    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaledImage = context.makeImage() else { return nil }
    return sharpenPromotedImageIfUseful(scaledImage, colorSpaceName: colorSpaceName)
  }

  private static func acceleratedScaledImage(
    _ image: CGImage,
    width: Int,
    height: Int,
    colorSpace: CGColorSpace
  ) -> CGImage? {
    let format = vImage_CGImageFormat(
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      colorSpace: Unmanaged.passUnretained(colorSpace),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      version: 0,
      decode: nil,
      renderingIntent: .defaultIntent
    )

    do {
      var sourceBuffer = try vImage_Buffer(cgImage: image, format: format)
      defer { sourceBuffer.free() }

      var destinationBuffer = try vImage_Buffer(
        width: width,
        height: height,
        bitsPerPixel: format.bitsPerPixel
      )
      defer { destinationBuffer.free() }

      let error = vImageScale_ARGB8888(
        &sourceBuffer,
        &destinationBuffer,
        nil,
        vImage_Flags(kvImageHighQualityResampling)
      )
      guard error == kvImageNoError else { return nil }

      return try destinationBuffer.createCGImage(format: format)
    } catch {
      return nil
    }
  }

  private static func sharpenedImage(
    _ image: CGImage,
    colorSpaceName: CFString?
  ) -> CGImage? {
    let colorSpace = colorSpace(from: colorSpaceName)
      ?? image.colorSpace
      ?? CGColorSpaceCreateDeviceRGB()
    let format = vImage_CGImageFormat(
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      colorSpace: Unmanaged.passUnretained(colorSpace),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      version: 0,
      decode: nil,
      renderingIntent: .defaultIntent
    )

    do {
      var sourceBuffer = try vImage_Buffer(cgImage: image, format: format)
      defer { sourceBuffer.free() }

      var destinationBuffer = try vImage_Buffer(
        width: image.width,
        height: image.height,
        bitsPerPixel: format.bitsPerPixel
      )
      defer { destinationBuffer.free() }

      var kernel: [Int16] = [
        0, -1, 0,
        -1, 10, -1,
        0, -1, 0
      ]
      let error = vImageConvolve_ARGB8888(
        &sourceBuffer,
        &destinationBuffer,
        nil,
        0,
        0,
        &kernel,
        3,
        3,
        6,
        nil,
        vImage_Flags(kvImageEdgeExtend)
      )
      guard error == kvImageNoError else { return nil }

      return try destinationBuffer.createCGImage(format: format)
    } catch {
      return nil
    }
  }

  private static func colorSpace(from name: CFString?) -> CGColorSpace? {
    guard let name else { return nil }
    return CGColorSpace(name: name)
  }
}
