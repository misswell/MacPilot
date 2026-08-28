//
//  AreaSelectionActionBar.swift
//  MacPilot's iShot-style post-selection controls.
//
//  The bar deliberately stays in AppKit.  The selection overlay is an
//  NSPanel that must remain above other applications, and AppKit buttons keep
//  the first click/keyboard focus behaviour deterministic while the panel is
//  non-activating.
//
//  Interaction model (matching iShot's capture flow): row one hosts the tool
//  group buttons, the eraser, undo, and the terminal actions.  When an
//  annotation session is active the bar binds to the `SmartAnnotationModel`
//  and reveals a contextual second row with that tool's options — shape
//  switch, fill, line style, stroke width, and the colour palette.
//

import AppKit
import Combine

@MainActor
final class AreaSelectionActionBar: NSView {
  /// Binding to the live annotation session. `nil` while no tool has been
  /// picked yet: tool buttons then start a session instead of switching tools.
  struct AnnotationBinding {
    weak var model: SmartAnnotationModel?
    let commit: (AreaSelectionAction) -> Void

    init(model: SmartAnnotationModel, commit: @escaping (AreaSelectionAction) -> Void) {
      self.model = model
      self.commit = commit
    }
  }

  /// Invoked when the bar's size changes (options row appears/disappears) so
  /// the overlay can re-anchor the bars around the selected frame.
  var layoutDidChange: (() -> Void)?

  private let onAction: (AreaSelectionAction) -> Void
  private var annotationBinding: AnnotationBinding?
  private var modelCancellable: AnyCancellable?

  private let rootStack = NSStackView()
  private var optionsRow: NSView?
  private var undoButton: NSButton?
  private var eraserButton: NSButton?
  private var widthValueLabel: NSTextField?
  private var shapeSegmented: NSSegmentedControl?
  private var fillCheckbox: NSButton?
  private var colorWell: NSColorWell?
  private var swatchButtons: [NSButton] = []
  private var toolDisplayButtons: [SmartAnnotationTool: NSButton] = [:]
  private var groupMainButtons: [ToolGroup: NSButton] = [:]
  /// The tool the options row was last built for. Selecting an existing
  /// annotation on the canvas swaps `model.tool` outside the bar, so
  /// `syncWithModel` rebuilds the row whenever this drifts.
  private var optionsRowTool: SmartAnnotationTool?

  private enum ToolGroup: CaseIterable {
    case shape
    case pencil
    case arrow

    var tools: [SmartAnnotationTool] {
      switch self {
      case .shape: return [.rectangle, .ellipse]
      case .pencil: return [.pencil, .highlighter]
      case .arrow: return [.arrow, .line]
      }
    }

    var fallbackTool: SmartAnnotationTool { tools[0] }

    var selectorTag: Int {
      switch self {
      case .shape: return 101
      case .pencil: return 102
      case .arrow: return 103
      }
    }

    static func matching(selectorTag tag: Int) -> ToolGroup? {
      allCases.first { $0.selectorTag == tag }
    }
  }

  private enum BarTag {
    static let text = 1
    static let counter = 2
    static let mosaic = 3
    static let eraser = 4
    static let undo = 5
    static let ocr = 6
    static let pin = 7
    static let save = 8
    static let close = 9
    static let copy = 10
  }

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

    rootStack.orientation = .vertical
    rootStack.alignment = .leading
    rootStack.spacing = 4
    rootStack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rootStack)
    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      rootStack.topAnchor.constraint(equalTo: topAnchor),
      rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    rootStack.addArrangedSubview(makePrimaryRow())
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    let optionsVisible = !(optionsRow?.isHidden ?? true)
    let height: CGFloat = optionsVisible
      ? Self.primaryRowHeight + 4 + Self.optionsRowHeight
      : Self.primaryRowHeight
    return NSSize(width: Self.primaryRowWidth, height: height)
  }

  private static let primaryRowHeight: CGFloat = 38
  private static let optionsRowHeight: CGFloat = 34
  private static let primaryRowWidth: CGFloat = 496

  // MARK: - Annotation Session Binding

  func bindAnnotationSession(_ binding: AnnotationBinding?) {
    annotationBinding = binding
    modelCancellable?.cancel()
    modelCancellable = nil
    if let model = binding?.model {
      modelCancellable = model.objectWillChange
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
          self?.syncWithModel()
        }
    }
    // The eraser and undo only make sense with a live annotation session —
    // reveal them on bind and hide them again when the session commits.
    let sessionActive = binding?.model != nil
    eraserButton?.isHidden = !sessionActive
    undoButton?.isHidden = !sessionActive
    rebuildOptionsRow()
    syncWithModel()
    invalidateIntrinsicContentSize()
    layoutDidChange?()
  }

  var isAnnotating: Bool {
    annotationBinding?.model != nil
  }

  // MARK: - Row One: Tools and Actions

  private func makePrimaryRow() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 2

    let grip = NSImageView(
      image: NSImage(
        systemSymbolName: "line.3.horizontal",
        accessibilityDescription: AppText.value("scToolDragBar", language: .system)
      ) ?? NSImage()
    )
    grip.contentTintColor = NSColor.white.withAlphaComponent(0.28)
    grip.imageScaling = .scaleProportionallyDown
    grip.toolTip = AppText.value("scToolDragBar", language: .system)
    grip.translatesAutoresizingMaskIntoConstraints = false
    row.addArrangedSubview(grip)
    grip.widthAnchor.constraint(equalToConstant: 12).isActive = true
    grip.heightAnchor.constraint(equalToConstant: 18).isActive = true
    row.setCustomSpacing(6, after: grip)

    // Tool groups with sub-tool menus (iShot's ▾ affordance).
    makeToolGroup(.shape, in: row)
    makeToolGroup(.pencil, in: row)
    makeToolGroup(.arrow, in: row)
    row.addArrangedSubview(makeSingleToolButton("textformat", titleKey: "scAnnotationText", tool: .text, tag: BarTag.text))
    row.addArrangedSubview(makeSingleToolButton("1.circle", titleKey: "scAnnotationCounter", tool: .counter, tag: BarTag.counter))
    row.addArrangedSubview(makeSingleToolButton("circle.lefthalf.filled", titleKey: "scAnnotationBlur", tool: .blur, tag: BarTag.mosaic))
    row.setCustomSpacing(6, after: row.arrangedSubviews.last ?? row)

    let eraser = makeSingleToolButton("eraser", titleKey: "scAnnotationEraser", tool: .eraser, tag: BarTag.eraser)
    eraser.isHidden = true
    row.addArrangedSubview(eraser)
    eraserButton = eraser

    let undo = makeSingleToolButton("arrow.uturn.backward", titleKey: "scUndo", tool: nil, tag: BarTag.undo)
    undo.isEnabled = false
    undo.isHidden = true
    row.addArrangedSubview(undo)
    undoButton = undo
    row.setCustomSpacing(6, after: undo)

    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    row.addArrangedSubview(separator)
    separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
    separator.heightAnchor.constraint(equalToConstant: 20).isActive = true
    row.setCustomSpacing(6, after: separator)

    row.addArrangedSubview(makeActionButton("text.viewfinder", titleKey: "scToolOCR", tag: BarTag.ocr))
    row.addArrangedSubview(makeActionButton("pin", titleKey: "scPin", tag: BarTag.pin))
    row.addArrangedSubview(makeActionButton("square.and.arrow.down", titleKey: "scToolSave", tag: BarTag.save))
    row.addArrangedSubview(makeActionButton("xmark", titleKey: "scClose", tag: BarTag.close))
    row.addArrangedSubview(makeActionButton("doc.on.doc", titleKey: "scCopy", tag: BarTag.copy))
    row.addArrangedSubview(makeMoreButton())

    row.translatesAutoresizingMaskIntoConstraints = false
    return row
  }

  private func makeToolGroup(_ group: ToolGroup, in row: NSStackView) {
    let container = NSStackView()
    container.orientation = .horizontal
    container.alignment = .centerY
    container.spacing = 0

    let main = makeGroupMainButton(group)
    let chevron = NSButton(image: Self.chevronImage, target: self, action: #selector(groupChevronPressed(_:)))
    chevron.isBordered = false
    chevron.imagePosition = .imageOnly
    chevron.contentTintColor = NSColor.white.withAlphaComponent(0.55)
    chevron.toolTip = AppText.value("scToolPickVariant", language: .system)
    chevron.setAccessibilityLabel(AppText.value("scToolPickVariant", language: .system))
    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true
    chevron.heightAnchor.constraint(equalToConstant: 26).isActive = true
    chevron.tag = group.selectorTag

    container.addArrangedSubview(main)
    container.addArrangedSubview(chevron)
    row.addArrangedSubview(container)
    groupMainButtons[group] = main
    for tool in group.tools {
      toolDisplayButtons[tool] = main
    }
  }

  private func makeGroupMainButton(_ group: ToolGroup) -> NSButton {
    let symbol = NSImage(
      systemSymbolName: group.fallbackTool.systemImage,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    let button = NSButton(image: symbol ?? NSImage(), target: self, action: #selector(groupMainPressed(_:)))
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.contentTintColor = .white
    button.toolTip = AppText.value(group.fallbackTool.titleKey, language: .system)
    button.setAccessibilityLabel(AppText.value(group.fallbackTool.titleKey, language: .system))
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 26).isActive = true
    button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    button.tag = group.selectorTag
    return button
  }

  private static var chevronImage: NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
    return NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
      .withSymbolConfiguration(config) ?? NSImage()
  }

  private func makeSingleToolButton(
    _ symbolName: String,
    titleKey: String,
    tool: SmartAnnotationTool?,
    tag: Int
  ) -> NSButton {
    let symbol = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    let button = NSButton(image: symbol ?? NSImage(), target: self, action: #selector(toolPressed(_:)))
    configureBarButton(button, tooltipKey: titleKey)
    button.tag = tag
    if let tool {
      toolDisplayButtons[tool] = button
    }
    return button
  }

  private func makeActionButton(_ symbolName: String, titleKey: String, tag: Int) -> NSButton {
    let symbol = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    let button = NSButton(image: symbol ?? NSImage(), target: self, action: #selector(actionPressed(_:)))
    configureBarButton(button, tooltipKey: titleKey)
    button.tag = tag
    return button
  }

  private func makeMoreButton() -> NSButton {
    let symbol = NSImage(
      systemSymbolName: "ellipsis",
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    let button = NSButton(image: symbol ?? NSImage(), target: self, action: #selector(morePressed(_:)))
    configureBarButton(button, tooltipKey: "scToolMore")
    return button
  }

  private func configureBarButton(_ button: NSButton, tooltipKey: String) {
    button.isBordered = false
    button.bezelStyle = .recessed
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.contentTintColor = .white
    let tooltip = AppText.value(tooltipKey, language: .system)
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
    button.wantsLayer = true
    button.layer?.cornerRadius = 6
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
  }

  // MARK: - Row Two: Contextual Options

  private func rebuildOptionsRow() {
    if let optionsRow {
      optionsRow.removeFromSuperview()
      self.optionsRow = nil
    }
    shapeSegmented = nil
    fillCheckbox = nil
    widthValueLabel = nil
    colorWell = nil
    swatchButtons.removeAll()

    guard let model = annotationBinding?.model else {
      optionsRowTool = nil
      invalidateIntrinsicContentSize()
      return
    }
    optionsRowTool = model.tool

    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 2, left: 22, bottom: 2, right: 8)

    switch model.tool {
    case .rectangle, .filledRectangle, .ellipse:
      row.addArrangedSubview(makeShapeSwitch(model))
      row.addArrangedSubview(makeFillCheckbox(model))
      row.addArrangedSubview(makeLineStylePopUp(model))
      row.addArrangedSubview(makeWidthControl(model, titleKey: "scAnnotationLineWidth"))
      row.addArrangedSubview(makeColorControls(model))
    case .arrow, .line:
      row.addArrangedSubview(makeLineStylePopUp(model))
      row.addArrangedSubview(makeWidthControl(model, titleKey: "scAnnotationLineWidth"))
      row.addArrangedSubview(makeColorControls(model))
    case .pencil, .highlighter:
      row.addArrangedSubview(makeWidthControl(model, titleKey: "scAnnotationLineWidth"))
      row.addArrangedSubview(makeColorControls(model))
    case .text, .counter:
      row.addArrangedSubview(makeWidthControl(model, titleKey: "scToolSize"))
      row.addArrangedSubview(makeColorControls(model))
    case .eraser:
      let clear = NSButton(
        title: AppText.value("scToolClearAll", language: .system),
        target: self,
        action: #selector(clearAllPressed(_:))
      )
      clear.bezelStyle = .rounded
      clear.contentTintColor = NSColor.systemRed
      clear.font = NSFont.systemFont(ofSize: 12, weight: .medium)
      row.addArrangedSubview(clear)
    case .blur, .watermark, .spotlight, .crop:
      break
    }

    row.translatesAutoresizingMaskIntoConstraints = false
    row.isHidden = row.arrangedSubviews.isEmpty
    optionsRow = row
    rootStack.addArrangedSubview(row)
    invalidateIntrinsicContentSize()
  }

  private func makeShapeSwitch(_ model: SmartAnnotationModel) -> NSView {
    let control = NSSegmentedControl(
      images: [
        NSImage(systemSymbolName: "rectangle", accessibilityDescription: nil) ?? NSImage(),
        NSImage(systemSymbolName: "oval", accessibilityDescription: nil) ?? NSImage(),
      ],
      trackingMode: .selectOne,
      target: self,
      action: #selector(shapeSegmentChanged(_:))
    )
    control.segmentStyle = .roundRect
    control.selectedSegment = model.tool == .ellipse ? 1 : 0
    control.setToolTip(AppText.value("scAnnotationRectangle", language: .system), forSegment: 0)
    control.setToolTip(AppText.value("scAnnotationEllipse", language: .system), forSegment: 1)
    shapeSegmented = control
    return control
  }

  private func makeFillCheckbox(_ model: SmartAnnotationModel) -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: AppText.value("scAnnotationFill", language: .system),
      target: self,
      action: #selector(fillChanged(_:))
    )
    checkbox.font = NSFont.systemFont(ofSize: 12)
    checkbox.state = model.currentStyle.fillEnabled ? .on : .off
    fillCheckbox = checkbox
    return checkbox
  }

  private func makeLineStylePopUp(_ model: SmartAnnotationModel) -> NSView {
    let menu = NSMenu()
    for lineStyle in SmartAnnotationLineStyle.allCases {
      let item = NSMenuItem(
        title: lineStyle.title(language: .system),
        action: #selector(lineStyleMenuItemSelected(_:)),
        keyEquivalent: ""
      )
      item.tag = lineStyleIndex(lineStyle)
      item.image = Self.lineStylePreview(lineStyle)
      menu.addItem(item)
    }
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.menu = menu
    button.preferredEdge = .maxY
    button.toolTip = AppText.value("scAnnotationLineStyle", language: .system)
    button.setAccessibilityLabel(AppText.value("scAnnotationLineStyle", language: .system))
    button.font = NSFont.systemFont(ofSize: 11)
    button.selectItem(withTag: lineStyleIndex(model.currentStyle.lineStyle))
    button.target = self
    button.action = #selector(lineStylePopUpChanged(_:))
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 58).isActive = true
    return button
  }

  private func makeWidthControl(_ model: SmartAnnotationModel, titleKey: String) -> NSView {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 4

    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: "line.3.horizontal",
        accessibilityDescription: AppText.value(titleKey, language: .system)
      ) ?? NSImage()
    )
    icon.contentTintColor = NSColor.white.withAlphaComponent(0.7)
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 12).isActive = true

    let value = NSTextField(labelWithString: "\(Int(model.currentStyle.lineWidth.rounded()))")
    value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    value.textColor = .white
    value.toolTip = AppText.value(titleKey, language: .system)
    widthValueLabel = value

    let button = NSButton(title: "", target: self, action: #selector(widthPressed(_:)))
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    button.layer?.cornerRadius = 6
    button.toolTip = AppText.value("scAnnotationLineWidth", language: .system)
    button.setAccessibilityLabel(AppText.value("scAnnotationLineWidth", language: .system))
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 40).isActive = true
    button.heightAnchor.constraint(equalToConstant: 24).isActive = true

    stack.addArrangedSubview(icon)
    stack.addArrangedSubview(value)
    stack.addArrangedSubview(button)
    return stack
  }

  private func makeColorControls(_ model: SmartAnnotationModel) -> NSView {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 4

    let well = NSColorWell()
    well.color = model.currentStyle.color.nsColor
    well.target = self
    well.action = #selector(customColorChanged(_:))
    well.toolTip = AppText.value("scAnnotationColor", language: .system)
    well.setAccessibilityLabel(AppText.value("scAnnotationColor", language: .system))
    well.translatesAutoresizingMaskIntoConstraints = false
    well.widthAnchor.constraint(equalToConstant: 22).isActive = true
    well.heightAnchor.constraint(equalToConstant: 22).isActive = true
    colorWell = well
    stack.addArrangedSubview(well)

    for preset in SmartAnnotationColor.presets {
      let button = NSButton(image: NSImage(), target: self, action: #selector(swatchPressed(_:)))
      button.isBordered = false
      button.wantsLayer = true
      button.layer?.backgroundColor = preset.nsColor.cgColor
      button.layer?.cornerRadius = 8
      button.tag = swatchTag(for: preset)
      button.toolTip = AppText.value("scAnnotationColor", language: .system)
      button.setAccessibilityLabel(AppText.value("scAnnotationColor", language: .system))
      button.translatesAutoresizingMaskIntoConstraints = false
      button.widthAnchor.constraint(equalToConstant: 16).isActive = true
      button.heightAnchor.constraint(equalToConstant: 16).isActive = true
      swatchButtons.append(button)
      stack.addArrangedSubview(button)
    }
    return stack
  }

  private static func lineStylePreview(_ style: SmartAnnotationLineStyle) -> NSImage {
    let image = NSImage(size: NSSize(width: 34, height: 10))
    image.lockFocus()
    NSColor.white.setStroke()
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 2, y: 5))
    path.line(to: NSPoint(x: 32, y: 5))
    path.lineWidth = 2
    switch style {
    case .solid: break
    case .dashed: path.setLineDash([5, 3], count: 2, phase: 0)
    case .dotted: path.setLineDash([1.5, 3], count: 2, phase: 0)
    }
    path.stroke()
    image.unlockFocus()
    return image
  }

  private func lineStyleIndex(_ style: SmartAnnotationLineStyle) -> Int {
    switch style {
    case .solid: return 0
    case .dashed: return 1
    case .dotted: return 2
    }
  }

  private func lineStyle(forIndex index: Int) -> SmartAnnotationLineStyle {
    switch index {
    case 1: return .dashed
    case 2: return .dotted
    default: return .solid
    }
  }

  private func swatchTag(for color: SmartAnnotationColor) -> Int {
    let presets = SmartAnnotationColor.presets
    return 200 + (presets.firstIndex(of: color) ?? 0)
  }

  private func swatchColor(forTag tag: Int) -> SmartAnnotationColor? {
    let index = tag - 200
    let presets = SmartAnnotationColor.presets
    guard presets.indices.contains(index) else { return nil }
    return presets[index]
  }

  // MARK: - Model Sync

  private func syncWithModel() {
    guard let model = annotationBinding?.model else { return }
    let activeTool = model.tool
    if activeTool != optionsRowTool {
      // The canvas can switch tools underneath the bar (selecting an existing
      // annotation swaps the tool); rebuild the contextual row for it.
      rebuildOptionsRow()
    }

    for (tool, button) in toolDisplayButtons {
      highlight(button, active: activeTool == tool)
    }
    for (group, button) in groupMainButtons {
      let current = group.tools.first { $0 == activeTool } ?? group.fallbackTool
      if let symbol = NSImage(
        systemSymbolName: current.systemImage,
        accessibilityDescription: nil
      )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
        button.image = symbol
      }
      let tooltip = AppText.value(current.titleKey, language: .system)
      button.toolTip = tooltip
      button.setAccessibilityLabel(tooltip)
    }
    undoButton?.isEnabled = !model.annotations.isEmpty
    widthValueLabel?.stringValue = "\(Int(model.currentStyle.lineWidth.rounded()))"
    shapeSegmented?.selectedSegment = activeTool == .ellipse ? 1 : 0
    fillCheckbox?.state = model.currentStyle.fillEnabled ? .on : .off
    colorWell?.color = model.currentStyle.color.nsColor
    for button in swatchButtons {
      guard let color = swatchColor(forTag: button.tag) else { continue }
      let selected = model.currentStyle.color == color
      button.layer?.borderWidth = selected ? 2 : 1
      button.layer?.borderColor = (selected
        ? NSColor.controlAccentColor
        : NSColor.white.withAlphaComponent(0.55)).cgColor
    }
  }

  private func highlight(_ button: NSButton, active: Bool) {
    button.layer?.backgroundColor = active
      ? NSColor.controlAccentColor.cgColor
      : NSColor.clear.cgColor
  }

  // MARK: - Actions

  @objc private func toolPressed(_ sender: NSButton) {
    let tool: SmartAnnotationTool
    switch sender.tag {
    case BarTag.text: tool = .text
    case BarTag.counter: tool = .counter
    case BarTag.mosaic: tool = .blur
    case BarTag.eraser: tool = .eraser
    case BarTag.undo:
      annotationBinding?.model?.undo()
      return
    default: return
    }
    selectTool(tool)
  }

  @objc private func groupMainPressed(_ sender: NSButton) {
    guard let group = ToolGroup.matching(selectorTag: sender.tag) else { return }
    let current = group.tools.first { $0 == annotationBinding?.model?.tool } ?? group.fallbackTool
    selectTool(current)
  }

  @objc private func groupChevronPressed(_ sender: NSButton) {
    guard let group = ToolGroup.matching(selectorTag: sender.tag) else { return }
    let menu = NSMenu()
    for (index, tool) in group.tools.enumerated() {
      let item = NSMenuItem(
        title: AppText.value(tool.titleKey, language: .system),
        action: #selector(groupVariantSelected(_:)),
        keyEquivalent: ""
      )
      item.tag = group.selectorTag * 10 + index + 1
      item.image = NSImage(
        systemSymbolName: tool.systemImage,
        accessibilityDescription: nil
      )?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.frame.height + 2), in: sender)
  }

  @objc private func groupVariantSelected(_ sender: NSMenuItem) {
    guard let group = ToolGroup.matching(selectorTag: sender.tag / 10) else { return }
    let index = sender.tag % 10 - 1
    guard group.tools.indices.contains(index) else { return }
    selectTool(group.tools[index])
  }

  private func selectTool(_ tool: SmartAnnotationTool) {
    if let model = annotationBinding?.model {
      model.selectTool(tool)
      // The tool-drift check inside syncWithModel rebuilds the options row.
      syncWithModel()
      return
    }
    guard let mapped = Self.areaSelectionTool(for: tool) else { return }
    onAction(.annotateTool(mapped))
  }

  private static func areaSelectionTool(for tool: SmartAnnotationTool) -> AreaSelectionAnnotationTool? {
    switch tool {
    case .rectangle, .filledRectangle: return .rectangle
    case .ellipse: return .ellipse
    case .arrow: return .arrow
    case .line: return .line
    case .pencil: return .pencil
    case .highlighter: return .highlighter
    case .text: return .text
    case .counter: return .counter
    case .blur: return .blur
    case .eraser: return .eraser
    case .crop: return .crop
    case .watermark, .spotlight: return nil
    }
  }

  @objc private func actionPressed(_ sender: NSButton) {
    let action: AreaSelectionAction
    switch sender.tag {
    case BarTag.ocr: action = .ocr
    case BarTag.pin: action = .pin
    case BarTag.save: action = .save
    case BarTag.close: action = .cancel
    case BarTag.copy: action = .copy
    default: return
    }
    perform(action)
  }

  @objc private func morePressed(_ sender: NSButton) {
    let menu = NSMenu()
    let upload = NSMenuItem(
      title: AppText.value("scImageHostingUpload", language: .system),
      action: #selector(moreItemSelected(_:)),
      keyEquivalent: ""
    )
    upload.tag = 1
    upload.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)
    menu.addItem(upload)
    let crop = NSMenuItem(
      title: AppText.value("scAnnotationCrop", language: .system),
      action: #selector(moreItemSelected(_:)),
      keyEquivalent: ""
    )
    crop.tag = 2
    crop.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
    menu.addItem(crop)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.frame.height + 2), in: sender)
  }

  @objc private func moreItemSelected(_ sender: NSMenuItem) {
    switch sender.tag {
    case 1: perform(.upload)
    case 2: perform(.annotateTool(.crop))
    default: break
    }
  }

  private func perform(_ action: AreaSelectionAction) {
    if let commit = annotationBinding?.commit {
      commit(action)
    } else {
      onAction(action)
    }
  }

  // MARK: - Options Row Handlers

  @objc private func shapeSegmentChanged(_ sender: NSSegmentedControl) {
    guard let model = annotationBinding?.model else { return }
    model.selectTool(sender.selectedSegment == 1 ? .ellipse : .rectangle)
    syncWithModel()
  }

  @objc private func fillChanged(_ sender: NSButton) {
    annotationBinding?.model?.setFillEnabled(sender.state == .on)
  }

  @objc private func lineStyleMenuItemSelected(_ sender: NSMenuItem) {
    annotationBinding?.model?.setLineStyle(lineStyle(forIndex: sender.tag))
  }

  @objc private func lineStylePopUpChanged(_ sender: NSPopUpButton) {
    guard let item = sender.selectedItem else { return }
    annotationBinding?.model?.setLineStyle(lineStyle(forIndex: item.tag))
  }

  @objc private func widthPressed(_ sender: NSButton) {
    guard let model = annotationBinding?.model else { return }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = WidthPopoverController(
      initialWidth: model.currentStyle.lineWidth
    ) { [weak model] width in
      model?.setLineWidth(width)
    }
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
  }

  @objc private func customColorChanged(_ sender: NSColorWell) {
    annotationBinding?.model?.setColor(SmartAnnotationColor(sender.color))
  }

  @objc private func swatchPressed(_ sender: NSButton) {
    guard let color = swatchColor(forTag: sender.tag) else { return }
    annotationBinding?.model?.setColor(color)
  }

  @objc private func clearAllPressed(_ sender: NSButton) {
    annotationBinding?.model?.removeAll()
  }
}

// MARK: - Width Popover

@MainActor
private final class WidthPopoverController: NSViewController {
  private let initialWidth: CGFloat
  private let onChange: (CGFloat) -> Void

  init(initialWidth: CGFloat, onChange: @escaping (CGFloat) -> Void) {
    self.initialWidth = initialWidth
    self.onChange = onChange
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let slider = NSSlider(
      value: Double(initialWidth),
      minValue: 1,
      maxValue: 48,
      target: self,
      action: #selector(sliderChanged(_:))
    )
    slider.frame = NSRect(x: 16, y: 34, width: 168, height: 22)
    slider.autoresizingMask = [.width]

    let label = NSTextField(labelWithString: "\(Int(initialWidth.rounded()))")
    label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    label.frame = NSRect(x: 16, y: 8, width: 168, height: 18)
    label.alignment = .right
    label.autoresizingMask = [.width]
    label.textColor = .labelColor

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 62))
    container.addSubview(slider)
    container.addSubview(label)
    view = container
  }

  @objc private func sliderChanged(_ sender: NSSlider) {
    let value = CGFloat(sender.doubleValue.rounded())
    onChange(value)
    if let label = view.subviews.compactMap({ $0 as? NSTextField }).first {
      label.stringValue = "\(Int(value))"
    }
  }
}

// MARK: - Side Action Bar

@MainActor
final class AreaSelectionSideActionBar: NSView {
  private let onAction: (AreaSelectionAction) -> Void
  private let stackView = NSStackView()
  private var actionsByTag: [Int: AreaSelectionAction] = [:]
  private var roundedButton: NSButton?
  private var shadowButton: NSButton?
  private var buttonCount = 0

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

    // iShot's right-hand column: rounded corners, adjust, shadow, refresh,
    // reselect. Rounded/shadow are toggles applied to the final output.
    roundedButton = addButton(
      "rectangle.dashed.inset.filled",
      tooltipKey: "scToolRoundedCorners",
      action: .toggleRoundedCorners,
      isToggle: true
    )
    addButton(
      "arrow.up.left.and.arrow.down.right",
      tooltipKey: "scAdjustSelection",
      action: .adjustSelection
    )
    shadowButton = addButton(
      "circle.lefthalf.filled",
      tooltipKey: "scToolShadow",
      action: .toggleShadow,
      isToggle: true
    )
    addButton("arrow.clockwise", tooltipKey: "scToolRefresh", action: .refreshCapture)
    addButton("rectangle.dashed", tooltipKey: "scToolReselect", action: .newSelection)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Mirrors the output-style toggle state into the two toggle buttons.
  func setToggleStates(roundedCorners: Bool, shadow: Bool) {
    setToggled(roundedButton, on: roundedCorners)
    setToggled(shadowButton, on: shadow)
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 44, height: CGFloat(buttonCount) * 40 + CGFloat(max(0, buttonCount - 1)) * 8)
  }

  @discardableResult
  private func addButton(
    _ name: String,
    tooltipKey: String,
    action: AreaSelectionAction,
    isToggle: Bool = false
  ) -> NSButton {
    let tooltip = AppText.value(tooltipKey, language: .system)
    let symbol = NSImage(systemSymbolName: name, accessibilityDescription: tooltip)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
    let image = symbol ?? NSImage(named: NSImage.actionTemplateName)!
    let button = NSButton(image: image, target: self, action: #selector(buttonPressed(_:)))
    buttonCount += 1
    let tag = buttonCount
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
    button.layer?.borderWidth = 0
    button.layer?.shadowColor = NSColor.black.cgColor
    button.layer?.shadowOpacity = 0.35
    button.layer?.shadowRadius = 8
    button.layer?.shadowOffset = .zero
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 40).isActive = true
    button.heightAnchor.constraint(equalToConstant: 40).isActive = true
    _ = isToggle
    stackView.addArrangedSubview(button)
    return button
  }

  private func setToggled(_ button: NSButton?, on: Bool) {
    guard let button else { return }
    button.layer?.backgroundColor = on
      ? NSColor.controlAccentColor.cgColor
      : NSColor.black.withAlphaComponent(0.84).cgColor
    button.layer?.borderWidth = on ? 2 : 0
    button.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
  }

  @objc private func buttonPressed(_ sender: NSButton) {
    onAction(actionsByTag[sender.tag] ?? .capture)
  }
}
