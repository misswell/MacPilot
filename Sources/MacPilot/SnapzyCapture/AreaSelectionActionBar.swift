//
//  AreaSelectionActionBar.swift
//  MacPilot's PixPin-style post-selection controls.
//
//  The bar deliberately stays in AppKit.  The selection overlay is an
//  NSPanel that must remain above other applications, and AppKit buttons keep
//  the first click/keyboard focus behaviour deterministic while the panel is
//  non-activating.
//

import AppKit

@MainActor
final class AreaSelectionActionBar: NSView {
  private struct ButtonDefinition {
    let imageName: String
    let tooltip: String
    let action: AreaSelectionAction
    let separatorAfter: Bool
  }

  private let onAction: (AreaSelectionAction) -> Void
  private let stackView = NSStackView()
  private var actionsByTag: [Int: AreaSelectionAction] = [:]

  init(onAction: @escaping (AreaSelectionAction) -> Void) {
    self.onAction = onAction
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
    layer?.cornerRadius = 14
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.35
    layer?.shadowRadius = 10
    layer?.shadowOffset = CGSize(width: 0, height: -3)

    stackView.orientation = .horizontal
    stackView.alignment = .centerY
    stackView.spacing = 2
    stackView.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    let grip = NSImageView(
      image: NSImage(
        systemSymbolName: "line.3.horizontal",
        accessibilityDescription: "拖动工具栏"
      ) ?? NSImage()
    )
    grip.contentTintColor = NSColor.white.withAlphaComponent(0.28)
    grip.imageScaling = .scaleProportionallyDown
    grip.toolTip = "拖动工具栏"
    grip.setAccessibilityLabel("拖动工具栏")
    grip.translatesAutoresizingMaskIntoConstraints = false
    stackView.addArrangedSubview(grip)
    grip.widthAnchor.constraint(equalToConstant: 12).isActive = true
    grip.heightAnchor.constraint(equalToConstant: 18).isActive = true

    let definitions: [ButtonDefinition] = [
      .init(imageName: "square", tooltip: "调整选区", action: .adjustSelection, separatorAfter: false),
      .init(imageName: "pencil", tooltip: "标注", action: .annotateTool(.pencil), separatorAfter: false),
      .init(imageName: "arrow.up.right", tooltip: "箭头标注", action: .annotateTool(.arrow), separatorAfter: false),
      .init(imageName: "textformat", tooltip: "文字标注", action: .annotateTool(.text), separatorAfter: false),
      .init(imageName: "1.circle", tooltip: "序号标注", action: .annotateTool(.counter), separatorAfter: false),
      .init(imageName: "circle.lefthalf.filled", tooltip: "马赛克/模糊", action: .annotateTool(.blur), separatorAfter: true),
      .init(imageName: "scissors", tooltip: "裁剪", action: .annotateTool(.crop), separatorAfter: false),
      .init(imageName: "text.viewfinder", tooltip: "识别文字", action: .ocr, separatorAfter: false),
      .init(imageName: "pin", tooltip: "置顶", action: .pin, separatorAfter: false),
      .init(imageName: "square.and.arrow.down", tooltip: "保存截图", action: .save, separatorAfter: false),
      .init(imageName: "square.on.square", tooltip: "复制图片", action: .copy, separatorAfter: false),
      .init(imageName: "xmark", tooltip: "关闭", action: .cancel, separatorAfter: false),
      .init(imageName: "ellipsis", tooltip: "更多操作", action: .more, separatorAfter: false),
    ]

    for (index, definition) in definitions.enumerated() {
      let tag = index + 1
      actionsByTag[tag] = definition.action
      stackView.addArrangedSubview(makeButton(definition, tag: tag))
      if definition.separatorAfter {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 20).isActive = true
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    // Compact PixPin-style bar: 12pt grip + thirteen 28pt cells, one
    // separator, and stack spacing. Keeping this stable makes the bar
    // placement around a moving selection cheap.
    let width: CGFloat = 426
    return NSSize(width: width, height: 38)
  }

  private func makeButton(_ definition: ButtonDefinition, tag: Int) -> NSButton {
    let symbol = NSImage(systemSymbolName: definition.imageName, accessibilityDescription: definition.tooltip)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
    let image = symbol ?? NSImage(named: NSImage.actionTemplateName)!
    let button = NSButton(image: image, target: self, action: #selector(buttonPressed(_:)))
    button.tag = tag
    button.bezelStyle = .recessed
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.contentTintColor = .white
    button.toolTip = definition.tooltip
    button.setAccessibilityLabel(definition.tooltip)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return button
  }

  @objc private func buttonPressed(_ sender: NSButton) {
    onAction(actionsByTag[sender.tag] ?? .capture)
  }
}

@MainActor
final class AreaSelectionSideActionBar: NSView {
  private let onAction: (AreaSelectionAction) -> Void
  private let stackView = NSStackView()
  private var actionsByTag: [Int: AreaSelectionAction] = [:]

  init(onAction: @escaping (AreaSelectionAction) -> Void) {
    self.onAction = onAction
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    stackView.orientation = .vertical
    stackView.alignment = .centerX
    stackView.spacing = 8
    stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    addButton("rectangle.dashed", tooltip: "重新选择", action: .newSelection)
    addButton("arrow.up.left.and.arrow.down.right", tooltip: "调整选区", action: .adjustSelection)
    addButton("text.viewfinder", tooltip: "识别文字", action: .ocr)
    addButton("arrow.clockwise", tooltip: "保存截图", action: .save)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 44, height: 4 * 40 + 3 * 8)
  }

  private func addButton(_ name: String, tooltip: String, action: AreaSelectionAction) {
    let symbol = NSImage(systemSymbolName: name, accessibilityDescription: tooltip)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
    let image = symbol ?? NSImage(named: NSImage.actionTemplateName)!
    let button = NSButton(image: image, target: self, action: #selector(buttonPressed(_:)))
    let tag = actionsByTag.count + 1
    actionsByTag[tag] = action
    button.tag = tag
    button.isBordered = false
    button.bezelStyle = .recessed
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.contentTintColor = .white
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
    button.wantsLayer = true
    button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor
    button.layer?.cornerRadius = 20
    button.layer?.shadowColor = NSColor.black.cgColor
    button.layer?.shadowOpacity = 0.35
    button.layer?.shadowRadius = 8
    button.layer?.shadowOffset = .zero
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 40).isActive = true
    button.heightAnchor.constraint(equalToConstant: 40).isActive = true
    stackView.addArrangedSubview(button)
  }

  @objc private func buttonPressed(_ sender: NSButton) {
    onAction(actionsByTag[sender.tag] ?? .capture)
  }
}
