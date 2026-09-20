//
//  QuickAccessPinWindowView.swift
//  Snapzy
//
//  Floating image-first surface for pinned screenshots.
//

import AppKit
import SwiftUI

struct QuickAccessPinWindowView: View {
  @ObservedObject var state: QuickAccessPinWindowState

  let onClose: () -> Void
  let onDoubleClick: () -> Void
  let onContextMenu: (NSEvent) -> Void
  let onZoomSizeChange: (CGSize, Bool) -> Void
  let onLockChanged: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isZoomScrubbing = false
  @State private var isZoomHovering = false
  @State private var isDragHovering = false
  @State private var isDragActive = false

  private let cornerRadius = NSWindow.defaultCornerRadius
  private let dragHandleCornerRadius: CGFloat = 8
  private let controlInset = QuickAccessPinWindowSizing.chromeInset

  var body: some View {
    ZStack {
      dragSurface
      content
        .allowsHitTesting(false)
      chromeLayer
    }
    .frame(width: state.displaySize.width, height: state.displaySize.height)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(Color.white.opacity(0.22), lineWidth: 1)
    )
    .background(Color.clear)
  }

  private var dragSurface: some View {
    QuickAccessPinWindowDragView(
      isEnabled: !state.isLocked,
      onDoubleClick: onDoubleClick,
      onContextMenu: onContextMenu
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(!state.isLocked)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var content: some View {
    if let text = state.text {
      textCard(text)
    } else if let image = state.image {
      screenshotImage(image)
    } else {
      Color.clear
    }
  }

  private func screenshotImage(_ image: NSImage) -> some View {
    Image(nsImage: image)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: state.displaySize.width, height: state.displaySize.height)
      .background(Color.black.opacity(0.03))
      .clipped()
      .opacity(pinOpacity)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: state.isMouseInside)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: state.isLocked)
  }

  /// Clipboard-text pins render as a readable card: the text bubble the old
  /// text-pin window drew is now the whole content surface of the same window.
  private func textCard(_ text: String) -> some View {
    Text(text)
      .font(Font(QuickAccessPinTextMetrics.font))
      .foregroundStyle(Color(nsColor: .labelColor))
      .multilineTextAlignment(.leading)
      .lineLimit(nil)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuickAccessPinTextMetrics.padding)
      .padding(.top, QuickAccessPinTextMetrics.chromeBand)
      .padding(.bottom, QuickAccessPinTextMetrics.padding)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.97))
      .opacity(pinOpacity)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: state.isMouseInside)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: state.isLocked)
  }

  private var pinOpacity: Double {
    state.isLocked && state.isMouseInside ? 0.18 : 1
  }

  private var chromeLayer: some View {
    ZStack {
      unlockedControls
        .opacity(state.isLocked ? 0 : 1)
        .allowsHitTesting(!state.isLocked)

      lockButton
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(controlInset)
    }
    .opacity(isChromeVisible ? 1 : 0)
    .allowsHitTesting(isChromeVisible)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isChromeVisible)
  }

  private var isChromeVisible: Bool {
    QuickAccessPinWindowChromeVisibility.isVisible(
      mouseInside: state.isMouseInside,
      zoomScrubbing: isZoomScrubbing
    )
  }

  private var unlockedControls: some View {
    ZStack {
      chromeButton(systemName: "xmark", help: L10n.PreferencesQuickAccess.unpinAction, action: onClose)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(controlInset)

      if state.supportsZoom {
        zoomScrub
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .padding(.top, controlInset)
      }

      if let fileURL = state.url {
        dragHandle(fileURL: fileURL)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          .padding(.bottom, controlInset)
      }
    }
  }

  private var lockButton: some View {
    chromeButton(
      systemName: state.isLocked ? "lock.fill" : "lock.open",
      help: state.isLocked ? L10n.QuickAccess.unlockPinnedWindow : L10n.QuickAccess.lockPinnedWindow
    ) {
      state.isLocked.toggle()
      onLockChanged()
    }
  }

  private var zoomScrub: some View {
    HStack(spacing: 7) {
      Text("\(state.zoomPercent)%")
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .frame(width: 40, alignment: .trailing)

      Slider(
        value: zoomScrubValue,
        in: zoomScrubRange,
        step: 1,
        onEditingChanged: { isScrubbing in
          isZoomScrubbing = isScrubbing
        }
      )
      .controlSize(.mini)
      .frame(maxWidth: .infinity)
      .accessibilityLabel(L10n.QuickAccess.zoomPinnedWindow)

      Button(action: resetZoom) {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 14, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(L10n.QuickAccess.fitPinnedWindow)
    }
    .padding(.horizontal, 11)
    .frame(width: QuickAccessPinWindowSizing.zoomScrubWidth(for: state.displaySize.width), height: QuickAccessPinWindowSizing.chromeButtonSide)
    .background(
      Capsule(style: .continuous)
        .fill(Color.black.opacity(isZoomHovering || isZoomScrubbing ? 0.64 : 0.54))
    )
    .overlay(
      Capsule(style: .continuous)
        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
    .onHover { isZoomHovering = $0 }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isZoomHovering)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isZoomScrubbing)
    .help(L10n.QuickAccess.zoomPinnedWindow)
  }

  private var zoomScrubValue: Binding<Double> {
    Binding(
      get: { Double(state.zoomPercent) },
      set: { percent in onZoomSizeChange(state.setZoomPercent(Int(percent)), false) }
    )
  }

  private var zoomScrubRange: ClosedRange<Double> {
    let bounds = state.zoomScrubRange
    return Double(bounds.lowerBound)...Double(bounds.upperBound)
  }

  private func resetZoom() {
    onZoomSizeChange(state.resetZoom(), true)
  }

  private func dragHandle(fileURL: URL) -> some View {
    QuickAccessPinDragHandleView(
      fileURL: fileURL,
      image: state.image ?? state.thumbnail ?? NSImage(),
      thumbnail: state.thumbnail ?? state.image ?? NSImage(),
      onDragStateChanged: { isDragActive = $0 }
    )
    .frame(width: 72, height: 32)
    .overlay(
      HStack(spacing: 8) {
        dragGrip

        Image(systemName: "doc.fill")
          .font(.system(size: 15, weight: .semibold))
          .frame(width: 14)

        dragGrip
      }
      .foregroundStyle(dragForegroundColor)
      .allowsHitTesting(false)
    )
    .background(dragHandleFill(isActive: isDragHovering || isDragActive))
    .overlay(dragHandleStroke(isActive: isDragHovering || isDragActive))
    .scaleEffect(isDragHovering || isDragActive ? 1.015 : 1)
    .shadow(color: Color.black.opacity(isDragHovering || isDragActive ? 0.18 : 0.12), radius: 7, x: 0, y: 2)
    .onHover { isDragHovering = $0 }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isDragHovering)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isDragActive)
    .help(L10n.AnnotateUI.dragToAppHelp)
  }

  private var dragGrip: some View {
    VStack(spacing: 3) {
      ForEach(0..<3, id: \.self) { _ in
        Capsule(style: .continuous)
          .fill(Color.primary.opacity(0.34))
          .frame(width: 7, height: 1.3)
      }
    }
    .frame(width: 10)
  }

  private func chromeButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.primary)
        .frame(width: QuickAccessPinWindowSizing.chromeButtonSide, height: QuickAccessPinWindowSizing.chromeButtonSide)
        .background(
          Circle()
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.84))
        )
        .overlay(
          Circle()
            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
    }
    .buttonStyle(.plain)
    .help(help)
  }

  private var dragForegroundColor: Color {
    isDragHovering || isDragActive ? .primary : Color.primary.opacity(0.62)
  }

  private func dragHandleFill(isActive: Bool) -> some View {
    RoundedRectangle(cornerRadius: dragHandleCornerRadius, style: .continuous)
      .fill(Color(nsColor: .windowBackgroundColor).opacity(isActive ? 0.94 : 0.86))
  }

  private func dragHandleStroke(isActive: Bool) -> some View {
    RoundedRectangle(cornerRadius: dragHandleCornerRadius, style: .continuous)
      .strokeBorder(Color.primary.opacity(isActive ? 0.16 : 0.08), lineWidth: 1)
  }
}

enum QuickAccessPinWindowChromeVisibility {
  /// The scrubber's drag can overshoot the pin, and chrome that vanishes
  /// mid-drag would drop the value the user is aiming at.
  static func isVisible(mouseInside: Bool, zoomScrubbing: Bool) -> Bool {
    mouseInside || zoomScrubbing
  }
}
