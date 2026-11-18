import AppKit
import SwiftUI

struct ImageViewerCanvasView: NSViewRepresentable {
    let controller: ImageViewerWindowController

    func makeNSView(context: Context) -> ImageViewerCanvas {
        let view = ImageViewerCanvas()
        view.controller = controller
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ view: ImageViewerCanvas, context: Context) {
        view.needsDisplay = true
    }
}

final class ImageViewerCanvas: NSView {
    weak var controller: ImageViewerWindowController?

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        reportViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportViewport()
    }

    private func reportViewport() {
        let size = bounds.size
        let backing = window?.backingScaleFactor ?? 1
        Task { @MainActor [weak controller] in controller?.setViewport(size, backing: backing) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard let controller, let frame = controller.frame,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let geometry = controller.geometry
        let scale = geometry.pointScale(frame.originalSize, in: bounds.size, backing: window?.backingScaleFactor ?? 1)
        let size = CGSize(width: frame.originalSize.width * scale, height: frame.originalSize.height * scale)
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: bounds.midX + geometry.pan.x, y: bounds.midY + geometry.pan.y)
        context.rotate(by: geometry.radians)
        context.draw(frame.image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { controller?.perform(.fit) }
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.pan(by: CGPoint(x: event.deltaX, y: -event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        zoom(exp(min(1.0, max(-1.0, event.scrollingDeltaY * 0.025))), event: event)
    }

    override func magnify(with event: NSEvent) {
        zoom(max(0.1, 1 + event.magnification), event: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard !urls.isEmpty, let onOpen = controller?.onOpen else { return false }
        onOpen(urls)
        return true
    }

    private func droppedFiles(_ sender: any NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return ImageViewerFileRouter.documents(in: urls as? [URL] ?? [])
    }

    private func zoom(_ factor: CGFloat, event: NSEvent) {
        let position = convert(event.locationInWindow, from: nil)
        controller?.zoom(by: factor, anchor: CGPoint(x: position.x - bounds.midX, y: position.y - bounds.midY))
    }
}
