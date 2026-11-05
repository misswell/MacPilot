import AppKit
import SwiftUI

/// Keep query editing and input-method commands in the native field editor.
struct QuickSearchQueryField: NSViewRepresentable {
    let model: QuickSearchModel

    func makeNSView(context: Context) -> QuickSearchQueryTextField {
        let field = QuickSearchQueryTextField()
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: QuickSearchQueryTextField, context: Context) {
        field.placeholderString = model.t("quickSearchPlaceholder")
        if field.stringValue != model.query { field.stringValue = model.query }
        field.onQueryChange = { [weak model] in model?.updateQuery($0) }
        field.onCommand = { [weak model] in model?.handleSearchKeyAction($0) }
    }
}

final class QuickSearchQueryTextField: NSTextField, NSTextFieldDelegate {
    var onQueryChange: ((String) -> Void)?
    var onCommand: ((QuickSearchKeyAction) -> Void)?
    var compositionAtEventStart: () -> Bool = { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = true
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 15)
        textColor = .labelColor
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        delegate = self
        compositionAtEventStart = { [weak self] in
            (self?.window as? QuickSearchPanel)?.isHandlingComposedKey == true
        }
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.window as? QuickSearchPanel,
                  panel.isPresented, panel.isKeyWindow else { return }
            panel.makeFirstResponder(self)
            // The panel is nonactivating; AppKit does not reliably activate
            // the field editor's input context on its own. Without this,
            // pinyin never reaches the IME and only Latin keys are inserted.
            (panel.fieldEditor(false, for: self) as? NSTextView)?.inputContext?.activate()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?((currentEditor() as? NSTextView)?.string ?? stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []
        let action = QuickSearchKeyRouter.action(
            command: commandSelector,
            commandHeld: flags.contains(.command),
            controlHeld: flags.contains(.control),
            isComposingText: textView.hasMarkedText() || compositionAtEventStart()
        )
        guard action != .passThrough, let onCommand else { return false }
        onCommand(action)
        return true
    }
}

extension QuickSearchModel {
    func handleSearchKeyAction(_ action: QuickSearchKeyAction) {
        switch action {
        case .openSelection: performPrimaryAction()
        case .revealInFinder: revealSelectionInFinder()
        case .closePanel: closePanel()
        case .moveSelection(let delta): moveSelection(by: delta)
        case .passThrough: break
        }
    }
}
