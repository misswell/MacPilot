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
    stackView.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    let definitions: [ButtonDefinition] = [
      .init(imageName: "square", tooltip: "选择区域", action: .capture, separatorAfter: false),
      .init(imageName: "pencil", tooltip: "标注", action: .annotate, separatorAfter: false),
      .init(imageName: "arrow.up.right", tooltip: "箭头标注", action: .annotate, separatorAfter: false),
      .init(imageName: "textformat", tooltip: "文字标注", action: .annotate, separatorAfter: false),
      .init(imageName: "1.circle", tooltip: "序号标注", action: .annotate, separatorAfter: false),
      .init(imageName: "circle.lefthalf.filled", tooltip: "马赛克/模糊", action: .annotate, separatorAfter: true),
      .init(imageName: "eraser", tooltip: "清除标注", action: .annotate, separatorAfter: false),
      .init(imageName: "arrow.uturn.backward", tooltip: "撤销", action: .annotate, separatorAfter: true),
      .init(imageName: "scissors", tooltip: "裁剪", action: .annotate, separatorAfter: false),
      .init(imageName: "text.viewfinder", tooltip: "识别文字", action: .ocr, separatorAfter: false),
      .init(imageName: "pin", tooltip: "置顶", action: .pin, separatorAfter: false),
      .init(imageName: "square.and.arrow.down", tooltip: "保存截图", action: .save, separatorAfter: false),
      .init(imageName: "square.on.square", tooltip: "复制图片", action: .copy, separatorAfter: false),
      .init(imageName: "xmark", tooltip: "关闭", action: .cancel, separatorAfter: false),
      .init(imageName: "ellipsis", tooltip: "更多操作", action: .capture, separatorAfter: false),
    ]

    for definition in definitions {
      stackView.addArrangedSubview(makeButton(definition))
      if definition.separatorAfter {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 30).isActive = true
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    // Fifteen 40pt cells plus the separators and horizontal insets.  Keeping
    // this stable makes the bar placement around a moving selection cheap.
    NSSize(width: 15 * 40 + 4 * 3 + 20, height: 58)
  }

  private func makeButton(_ definition: ButtonDefinition) -> NSButton {
    let image = NSImage(
      systemSymbolName: definition.imageName,
      accessibilityDescription: definition.tooltip
    ) ?? NSImage(named: NSImage.actionTemplateName)!
    let button = NSButton(image: image, target: self, action: #selector(buttonPressed(_:)))
    button.tag = actionTag(definition.action)
    button.bezelStyle = .recessed
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyUpOrDown
    button.contentTintColor = .white
    button.toolTip = definition.tooltip
    button.setAccessibilityLabel(definition.tooltip)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 38).isActive = true
    button.heightAnchor.constraint(equalToConstant: 42).isActive = true
    return button
  }

  @objc private func buttonPressed(_ sender: NSButton) {
    onAction(action(forTag: sender.tag))
  }

  private func actionTag(_ action: AreaSelectionAction) -> Int {
    switch action {
    case .capture: return 1
    case .copy: return 2
    case .save: return 3
    case .annotate: return 4
    case .ocr: return 5
    case .pin: return 6
    case .cancel: return 7
    }
  }

  private func action(forTag tag: Int) -> AreaSelectionAction {
    switch tag {
    case 2: return .copy
    case 3: return .save
    case 4: return .annotate
    case 5: return .ocr
    case 6: return .pin
    case 7: return .cancel
    default: return .capture
    }
  }
}

@MainActor
final class AreaSelectionSideActionBar: NSView {
  private let onAction: (AreaSelectionAction) -> Void
  private let stackView = NSStackView()

  init(onAction: @escaping (AreaSelectionAction) -> Void) {
    self.onAction = onAction
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
    layer?.cornerRadius = 26
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.3
    layer?.shadowRadius = 8

    stackView.orientation = .vertical
    stackView.alignment = .centerX
    stackView.spacing = 5
    stackView.edgeInsets = NSEdgeInsets(top: 6, left: 5, bottom: 6, right: 5)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    addButton("rectangle.dashed", tooltip: "重新选择", action: .capture)
    addButton("arrow.up.left.and.arrow.down.right", tooltip: "调整选区", action: .capture)
    addButton("text.viewfinder", tooltip: "识别文字", action: .ocr)
    addButton("arrow.clockwise", tooltip: "保存截图", action: .save)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 58, height: 4 * 38 + 3 * 5 + 12)
  }

  private func addButton(_ name: String, tooltip: String, action: AreaSelectionAction) {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: tooltip)
      ?? NSImage(named: NSImage.actionTemplateName)!
    let button = NSButton(image: image, target: self, action: #selector(buttonPressed(_:)))
    button.tag = actionTag(action)
    button.isBordered = false
    button.bezelStyle = .recessed
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyUpOrDown
    button.contentTintColor = .white
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 40).isActive = true
    button.heightAnchor.constraint(equalToConstant: 36).isActive = true
    stackView.addArrangedSubview(button)
  }

  @objc private func buttonPressed(_ sender: NSButton) {
    onAction(action(forTag: sender.tag))
  }

  private func actionTag(_ action: AreaSelectionAction) -> Int {
    switch action {
    case .capture: return 1
    case .copy: return 2
    case .save: return 3
    case .annotate: return 4
    case .ocr: return 5
    case .pin: return 6
    case .cancel: return 7
    }
  }

  private func action(forTag tag: Int) -> AreaSelectionAction {
    switch tag {
    case 2: return .copy
    case 3: return .save
    case 4: return .annotate
    case 5: return .ocr
    case 6: return .pin
    case 7: return .cancel
    default: return .capture
    }
  }
}
