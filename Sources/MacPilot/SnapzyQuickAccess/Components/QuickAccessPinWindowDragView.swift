//
//  QuickAccessPinWindowDragView.swift
//  Snapzy
//
//  AppKit event surface for moving a pinned screenshot or text pin.
//

@preconcurrency import AppKit
import SwiftUI

struct QuickAccessPinWindowDragView: NSViewRepresentable {
  let isEnabled: Bool
  let onDoubleClick: () -> Void
  let onContextMenu: (NSEvent) -> Void

  func makeNSView(context: Context) -> QuickAccessPinWindowDragNSView {
    QuickAccessPinWindowDragNSView(
      isEnabled: isEnabled,
      onDoubleClick: onDoubleClick,
      onContextMenu: onContextMenu
    )
  }

  func updateNSView(_ nsView: QuickAccessPinWindowDragNSView, context: Context) {
    nsView.isEnabled = isEnabled
    nsView.onDoubleClick = onDoubleClick
    nsView.onContextMenu = onContextMenu
  }
}

final class QuickAccessPinWindowDragNSView: NSView {
  var isEnabled: Bool
  var onDoubleClick: () -> Void
  var onContextMenu: (NSEvent) -> Void

  init(
    isEnabled: Bool,
    onDoubleClick: @escaping () -> Void,
    onContextMenu: @escaping (NSEvent) -> Void
  ) {
    self.isEnabled = isEnabled
    self.onDoubleClick = onDoubleClick
    self.onContextMenu = onContextMenu
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
    guard isEnabled else {
      super.mouseDown(with: event)
      return
    }

    if event.clickCount == 2 {
      onDoubleClick()
      return
    }

    // NSWindow's movable-background path is not reliable through an
    // NSHostingView. Start the native window drag from the AppKit surface so
    // any left-button drag on the pin content moves the whole pin.
    window?.performDrag(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    guard isEnabled else {
      super.rightMouseDown(with: event)
      return
    }
    onContextMenu(event)
  }
}
