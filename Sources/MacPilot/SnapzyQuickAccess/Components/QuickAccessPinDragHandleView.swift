//
//  QuickAccessPinDragHandleView.swift
//  Snapzy
//
//  Compact AppKit drag handle for pinned screenshots.
//

@preconcurrency import AppKit
import SwiftUI

struct QuickAccessPinDragHandleView: NSViewRepresentable {
  let fileURL: URL
  let image: NSImage
  let thumbnail: NSImage
  let onDragStateChanged: (Bool) -> Void

  func makeNSView(context: Context) -> QuickAccessPinDragHandleNSView {
    QuickAccessPinDragHandleNSView(
      fileURL: fileURL,
      image: image,
      thumbnail: thumbnail,
      onDragStateChanged: onDragStateChanged
    )
  }

  func updateNSView(_ nsView: QuickAccessPinDragHandleNSView, context: Context) {
    nsView.fileURL = fileURL
    nsView.image = image
    nsView.thumbnail = thumbnail
    nsView.onDragStateChanged = onDragStateChanged
  }
}

final class QuickAccessPinDragHandleNSView: NSView, NSDraggingSource {
  var fileURL: URL
  var image: NSImage
  var thumbnail: NSImage
  var onDragStateChanged: (Bool) -> Void

  private var sourceAccess: SandboxFileAccessManager.ScopedAccess?
  private var isDragging = false
  private weak var draggingWindow: NSWindow?
  private var savedWindowFrame: NSRect?
  private var activeDragFileURL: URL?
  private var shouldRetainActiveDragFile = false

  init(fileURL: URL, image: NSImage, thumbnail: NSImage, onDragStateChanged: @escaping (Bool) -> Void) {
    self.fileURL = fileURL
    self.image = image
    self.thumbnail = thumbnail
    self.onDragStateChanged = onDragStateChanged
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { false }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  override func mouseDown(with event: NSEvent) {
    guard !isDragging else { return }
    beginFileDrag(with: event)
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    isDragging = false
    shouldRetainActiveDragFile = operation != []
    onDragStateChanged(false)
    restoreDraggingWindow()
    cleanupActiveDragFileIfNeeded()
    sourceAccess?.stop()
    sourceAccess = nil
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Pinned screenshot drag ended",
      context: [
        "fileName": fileURL.lastPathComponent,
        "success": operation != [] ? "true" : "false",
      ]
    )
  }

  deinit {
    sourceAccess?.stop()
    sourceAccess = nil
    MainActor.assumeIsolated {
      restoreDraggingWindow()
      cleanupActiveDragFileIfNeeded()
    }
  }

  private func beginFileDrag(with event: NSEvent) {
    let dragFileURL = makeCurrentImageDragFileURL() ?? fileURL
    activeDragFileURL = dragFileURL == fileURL ? nil : dragFileURL
    shouldRetainActiveDragFile = false
    sourceAccess = SandboxFileAccessManager.shared.beginAccessingURL(dragFileURL)
    isDragging = true
    onDragStateChanged(true)
    draggingWindow = window
    savedWindowFrame = window?.frame

    let dragItem = NSDraggingItem(pasteboardWriter: dragFileURL as NSURL)
    let imageSize = NSSize(width: 120, height: 80)
    let dragImage = NSImage(size: imageSize)
    dragImage.lockFocus()
    thumbnail.draw(
      in: NSRect(origin: .zero, size: imageSize),
      from: .zero,
      operation: .sourceOver,
      fraction: 0.82
    )
    dragImage.unlockFocus()

    let mouseLocation = convert(event.locationInWindow, from: nil)
    dragItem.setDraggingFrame(
      NSRect(
        x: mouseLocation.x - imageSize.width / 2,
        y: mouseLocation.y - imageSize.height / 2,
        width: imageSize.width,
        height: imageSize.height
      ),
      contents: dragImage
    )

    draggingWindow?.orderOut(nil)

    let session = beginDraggingSession(with: [dragItem], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Pinned screenshot drag started",
      context: ["fileName": dragFileURL.lastPathComponent]
    )
  }

  private func restoreDraggingWindow() {
    guard let draggingWindow else {
      savedWindowFrame = nil
      return
    }

    if let savedWindowFrame {
      draggingWindow.setFrame(savedWindowFrame, display: false)
    }
    draggingWindow.orderFrontRegardless()
    self.draggingWindow = nil
    savedWindowFrame = nil
  }

  private func makeCurrentImageDragFileURL() -> URL? {
    let fileManager = FileManager.default
    let directory = TempCaptureManager.shared.tempCaptureDirectory
      .appendingPathComponent("PinDrags", isDirectory: true)
    let fileExtension = preferredFileExtension()
    let baseName = "\(fileURL.deletingPathExtension().lastPathComponent)-pinned"
    let outputURL = CaptureOutputNaming.makeUniqueFileURL(
      in: directory,
      baseName: baseName,
      fileExtension: fileExtension
    )

    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      guard let data = AnnotateExporter.imageData(from: image, for: fileExtension) else {
        return nil
      }
      try data.write(to: outputURL, options: .atomic)
      return outputURL
    } catch {
      DiagnosticLogger.shared.logError(
        .fileAccess,
        error,
        "Pinned screenshot drag file preparation failed",
        context: ["fileName": fileURL.lastPathComponent]
      )
      return nil
    }
  }

  private func preferredFileExtension() -> String {
    let ext = fileURL.pathExtension.lowercased()
    return ext.isEmpty ? "png" : ext
  }

  private func cleanupActiveDragFileIfNeeded() {
    guard let activeDragFileURL else { return }
    if !shouldRetainActiveDragFile {
      try? FileManager.default.removeItem(at: activeDragFileURL)
    }
    self.activeDragFileURL = nil
    shouldRetainActiveDragFile = false
  }
}
