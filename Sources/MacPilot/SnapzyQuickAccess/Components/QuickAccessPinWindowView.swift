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
  @Environment(\.colorScheme) private var colorScheme
  @State private var isFileDragActive = false
  @State private var isPointerInZoomHUDZone = false

  private let cornerRadius = NSWindow.defaultCornerRadius

  var body: some View {
    ZStack {
      dragSurface
      content
        .allowsHitTesting(false)

      if state.isLocked {
        lockedChrome
      } else {
        unlockedChrome
        zoomHUD
      }
    }
    .frame(width: state.displaySize.width, height: state.displaySize.height)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(pinBorder)
    .background(Color.clear)
    .onContinuousHover { phase in
      switch phase {
      case .active(let location):
        isPointerInZoomHUDZone = QuickAccessPinZoomHUDPolicy
          .zone(in: state.displaySize)
          .contains(location)
      case .ended:
        isPointerInZoomHUDZone = false
      }
    }
  }

  // MARK: - Image and text surface

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

  /// Full bleed.  The panel already carries the window shadow, and the sizing
  /// policy keeps this frame on the image's own aspect ratio, so there is no
  /// letterbox to paint a backing colour for.
  private func screenshotImage(_ image: NSImage) -> some View {
    Image(nsImage: image)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: state.displaySize.width, height: state.displaySize.height)
      .clipped()
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
      .padding(.horizontal, QuickAccessPinTextMetrics.horizontalPadding)
      .padding(.top, QuickAccessPinTextMetrics.topPadding)
      .padding(.bottom, QuickAccessPinTextMetrics.bottomPadding)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.97))
  }

  private var pinBorder: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .stroke(Color.white.opacity(PinnedScreenshotChromeStyle.borderOpacity(for: colorScheme)), lineWidth: 1)
  }

  // MARK: - Unlocked chrome

  /// Hover reveals one HUD capsule in the trailing top corner.  A pin at rest
  /// is a picture with nothing on it.
  private var unlockedChrome: some View {
    VStack {
      HStack {
        Spacer(minLength: 0)
        controlCapsule
      }
      Spacer(minLength: 0)
    }
    .padding(PinnedScreenshotChromeStyle.outerInset)
    .opacity(isChromeVisible ? 1 : 0)
    .allowsHitTesting(isChromeVisible)
    .animation(chromeAnimation, value: isChromeVisible)
  }

  /// A file drag orders the window out and runs its own event loop, so the
  /// pointer state is stale by the time the window comes back.  Holding the
  /// capsule up for the duration keeps the control the drag started from — the
  /// capsule itself — from disappearing under the cursor.
  private var isChromeVisible: Bool {
    QuickAccessPinChromeVisibility.isVisible(mouseInside: state.isMouseInside, isDraggingFile: isFileDragActive)
  }

  private var controlCapsule: some View {
    HStack(spacing: PinnedScreenshotChromeStyle.controlSpacing) {
      control(
        systemName: "lock.open",
        help: L10n.QuickAccess.lockPinnedWindow,
        action: toggleLock
      )

      if let fileURL = state.url {
        dragControl(fileURL: fileURL)
      }

      control(systemName: "xmark", help: L10n.PreferencesQuickAccess.unpinAction, action: onClose)
    }
    .modifier(PinCapsule())
  }

  private func control(systemName: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: PinnedScreenshotChromeStyle.glyphSize, weight: PinnedScreenshotChromeStyle.glyphWeight))
        .foregroundStyle(PinnedScreenshotChromeStyle.capsuleGlyph)
        .frame(width: PinnedScreenshotChromeStyle.controlSide, height: PinnedScreenshotChromeStyle.controlSide)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }

  /// The drag-out entry point.  The glyph is drawn over the drag view, which is
  /// the same `NSView` that has always started the `NSDraggingSession` — only
  /// its position changed, from a handle under the image to this control.
  private func dragControl(fileURL: URL) -> some View {
    QuickAccessPinDragHandleView(
      fileURL: fileURL,
      image: state.image ?? state.thumbnail ?? NSImage(),
      thumbnail: state.thumbnail ?? state.image ?? NSImage(),
      onDragStateChanged: { isFileDragActive = $0 }
    )
    .frame(width: PinnedScreenshotChromeStyle.controlSide, height: PinnedScreenshotChromeStyle.controlSide)
    .overlay {
      Image(systemName: "arrow.up.forward.app")
        .font(.system(size: PinnedScreenshotChromeStyle.glyphSize, weight: PinnedScreenshotChromeStyle.glyphWeight))
        .foregroundStyle(PinnedScreenshotChromeStyle.capsuleGlyph)
        .allowsHitTesting(false)
    }
    .help(L10n.AnnotateUI.dragToAppHelp)
    .accessibilityLabel(L10n.AnnotateUI.dragToAppHelp)
  }

  // MARK: - Locked chrome

  /// Locked means the image lets the mouse through everywhere except the
  /// hotspot, so this state has its own single-control chrome rather than the
  /// unlocked capsule at a different opacity.  The image itself never fades.
  private var lockedChrome: some View {
    ZStack(alignment: .topTrailing) {
      Color.clear
      if state.isPointerInLockHotspot {
        control(
          systemName: "lock.fill",
          help: L10n.QuickAccess.unlockPinnedWindow,
          action: toggleLock
        )
        .modifier(PinCapsule())
      }
    }
    .padding(PinnedScreenshotChromeStyle.outerInset)
  }

  private func toggleLock() {
    state.isLocked.toggle()
    onLockChanged()
  }

  // MARK: - Zoom HUD

  /// Not a permanent control row: it comes up while the image is actually being
  /// scaled, or when the pointer goes looking for it at the bottom centre.
  private var zoomHUD: some View {
    Group {
      if showsZoomHUD {
        HStack(spacing: 0) {
          hudControl(systemName: "minus", help: L10n.QuickAccess.zoomOutPinnedWindow) {
            stepZoom(-PinnedScreenshotChromeStyle.zoomHUDStep)
          }

          Button(action: resetZoom) {
            Text("\(state.zoomPercent)%")
              .font(.system(size: PinnedScreenshotChromeStyle.glyphSize, weight: PinnedScreenshotChromeStyle.glyphWeight))
              .monospacedDigit()
              .foregroundStyle(PinnedScreenshotChromeStyle.capsuleGlyph)
              .frame(height: PinnedScreenshotChromeStyle.controlSide)
              .frame(minWidth: 40)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(L10n.QuickAccess.fitPinnedWindow)
          .accessibilityLabel(L10n.QuickAccess.zoomPinnedWindow)

          hudControl(systemName: "plus", help: L10n.QuickAccess.zoomInPinnedWindow) {
            stepZoom(PinnedScreenshotChromeStyle.zoomHUDStep)
          }
        }
        .frame(width: PinnedScreenshotChromeStyle.zoomHUDWidth, height: PinnedScreenshotChromeStyle.zoomHUDHeight)
        .modifier(PinCapsuleSurface())
        .accessibilityElement(children: .contain)
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .padding(.bottom, PinnedScreenshotChromeStyle.outerInset)
    .allowsHitTesting(showsZoomHUD)
    .animation(chromeAnimation, value: showsZoomHUD)
  }

  private var showsZoomHUD: Bool {
    state.supportsZoom
      && !state.isLocked
      && QuickAccessPinZoomHUDPolicy.isVisible(
        pointerInZone: isPointerInZoomHUDZone,
        interactionIsLive: state.isZoomInteractionLive
      )
  }

  private func hudControl(systemName: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: PinnedScreenshotChromeStyle.glyphSize, weight: PinnedScreenshotChromeStyle.glyphWeight))
        .foregroundStyle(PinnedScreenshotChromeStyle.capsuleGlyph)
        .frame(width: PinnedScreenshotChromeStyle.controlSide, height: PinnedScreenshotChromeStyle.controlSide)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }

  private func stepZoom(_ step: CGFloat) {
    onZoomSizeChange(state.applyZoomStep(step), false)
  }

  private func resetZoom() {
    onZoomSizeChange(state.resetZoom(), true)
  }

  private var chromeAnimation: Animation? {
    reduceMotion ? nil : .easeInOut(duration: PinnedScreenshotChromeStyle.hoverAnimationDuration)
  }
}

// MARK: - Chrome surfaces

/// The capsule a control row is drawn into.  Its radius is half its height,
/// which is also the pin's radius minus the edge inset, so the two curves stay
/// concentric without asking the system to derive it.
private struct PinCapsule: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, PinnedScreenshotChromeStyle.controlSpacing)
      .frame(height: PinnedScreenshotChromeStyle.controlHeight)
      .modifier(PinCapsuleSurface())
  }
}

/// A system-HUD surface: dark translucent fill, light hairline, soft shadow.
/// Deliberately free of `glassEffect` and of any `Material` — both sample what
/// is behind them, and a control that only looks right over some part of the
/// user's screenshot is a control that disappears over the rest of it.
private struct PinCapsuleSurface: ViewModifier {
  private var shape: Capsule {
    Capsule()
  }

  func body(content: Content) -> some View {
    content
      .background(shape.fill(Color.black.opacity(PinnedScreenshotChromeStyle.capsuleFillOpacity)))
      .overlay(shape.strokeBorder(Color.white.opacity(PinnedScreenshotChromeStyle.capsuleStrokeOpacity), lineWidth: 1))
      .shadow(
        color: Color(nsColor: .black).opacity(PinnedScreenshotChromeStyle.chromeShadowOpacity),
        radius: PinnedScreenshotChromeStyle.chromeShadowRadius,
        x: 0,
        y: -PinnedScreenshotChromeStyle.chromeShadowOffset
      )
  }
}

// MARK: - Chrome policies

enum QuickAccessPinChromeVisibility {
  /// The capsule is a hover affordance, so it follows the pointer into the
  /// window.  It also has to survive a file drag, which hides the window and
  /// stops the pointer state from updating while it runs.
  static func isVisible(mouseInside: Bool, isDraggingFile: Bool) -> Bool {
    mouseInside || isDraggingFile
  }
}

/// When the bottom zoom HUD earns its space on the image.  Wheel, pinch and the
/// HUD's own buttons all end up changing the scale, so recency of the scale is
/// the signal; the zone gives the pointer somewhere to go for explicit control.
enum QuickAccessPinZoomHUDPolicy {
  static func isVisible(pointerInZone: Bool, interactionIsLive: Bool) -> Bool {
    pointerInZone || interactionIsLive
  }

  /// The bottom-centre band that keeps the HUD up.  Wider than the HUD itself
  /// so the pointer can reach the controls without missing them, and expressed
  /// in the view's local space, where `y` grows downwards from the top edge.
  static func zone(in size: CGSize) -> CGRect {
    let width = min(PinnedScreenshotChromeStyle.zoomHUDZoneWidth, size.width)
    let height = min(PinnedScreenshotChromeStyle.zoomHUDZoneHeight, size.height)
    return CGRect(
      x: (size.width - width) / 2,
      y: size.height - height,
      width: width,
      height: height
    )
  }
}
