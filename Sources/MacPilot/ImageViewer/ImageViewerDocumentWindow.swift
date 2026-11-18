import AppKit

enum ImageViewerCommand: String, CaseIterable, Identifiable {
    case previous, next, zoomOut, fit, zoomIn, actual, left, right, info, fullscreen, printImage

    var id: Self { self }
    var key: String { "viewerCommand_" + rawValue }
    var icon: String {
        switch self {
        case .previous: "chevron.left"
        case .next: "chevron.right"
        case .zoomOut: "minus.magnifyingglass"
        case .fit: "arrow.down.right.and.arrow.up.left"
        case .zoomIn: "plus.magnifyingglass"
        case .actual: "1.magnifyingglass"
        case .left: "rotate.left"
        case .right: "rotate.right"
        case .info: "info.circle"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .printImage: "printer"
        }
    }

    static let toolbar: [Self] = [.previous, .next, .zoomOut, .fit, .zoomIn, .left, .right, .info]
}

final class ImageViewerDocumentWindow: NSWindow {
    weak var viewer: ImageViewerWindowController?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isKeyWindow, event.windowNumber == windowNumber,
           attachedSheet == nil, NSApp.modalWindow == nil,
           !(firstResponder is NSTextView), !(firstResponder is NSControl),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let viewer {
            switch event.keyCode {
            case 123: viewer.perform(.previous); return
            case 124: viewer.perform(.next); return
            case 126, 116:
                if viewer.browser.pageCount > 1 { viewer.go(to: viewer.browser.page - 1); return }
            case 125, 121:
                if viewer.browser.pageCount > 1 { viewer.go(to: viewer.browser.page + 1); return }
            default: break
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyWindow, attachedSheet == nil, NSApp.modalWindow == nil,
              let viewer, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let command: ImageViewerCommand?
        if modifiers == [.command, .control], key == "f" {
            command = .fullscreen
        } else if modifiers == .command || modifiers == [.command, .shift] {
            switch key {
            case "+", "=": command = .zoomIn
            case "-": command = .zoomOut
            case "0": command = .fit
            case "1": command = .actual
            case "[": command = .left
            case "]": command = .right
            case "i": command = .info
            case "p": command = .printImage
            default: command = nil
            }
        } else {
            command = nil
        }
        if let command { viewer.perform(command); return true }
        return super.performKeyEquivalent(with: event)
    }
}
