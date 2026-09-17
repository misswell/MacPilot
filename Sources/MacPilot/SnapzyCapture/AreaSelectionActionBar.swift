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
//  The post-selection HUD is a single bar.  iShot's right-hand column
//  (圆角截图 / 调整选区 / 阴影或边框 / 刷新截图 / 重新选择) is folded into the
//  「更多」 menu instead of a second floating bar: the two bars had to be kept
//  apart by a collision solver, and three of the column's commands duplicated
//  gestures the frame already supports.
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

  /// Output-style toggle state mirrored from `SnapzyAreaSelectionController`
  /// so the 「更多」 menu can tick 圆角截图 / 阴影或边框. The controller owns the
  /// values; the bar only renders them (see `syncOutputStyleToggles`).
  var outputStyleState: (roundedCorners: Bool, shadow: Bool) = (false, false)

  private let rootStack = NSStackView()
  private var primaryRow: NSStackView?
  private var optionsRow: NSView?
  private var undoButton: NSButton?
  private var eraserButton: NSButton?
  private var widthValueLabel: NSTextField?
  private var widthSlider: NSSlider?
  private var shapeSegmented: NSSegmentedControl?
  private var fillCheckbox: NSButton?
  private var colorWell: NSColorWell?
  private var optionsCollapseButton: NSButton?
  private var swatchButtons: [NSButton] = []
  private var toolDisplayButtons: [SmartAnnotationTool: NSButton] = [:]
  private var groupMainButtons: [ToolGroup: NSButton] = [:]
  /// The tool the options row was last built for. Selecting an existing
  /// annotation on the canvas swaps `model.tool` outside the bar, so
  /// `syncWithModel` rebuilds the row whenever this drifts.
  private var optionsRowTool: SmartAnnotationTool?
  private var optionsRowCollapsed = false

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
    static let spotlight = 11
    static let eraser = 4
    static let undo = 5
    static let ocr = 6
    static let pin = 7
    static let save = 8
    static let close = 9
    static let copy = 10
    /// 「更多」 menu items. The former right-hand column lives here now.
    static let moreUpload = 21
    static let moreCrop = 22
    static let moreRefresh = 23
    static let moreAdjust = 24
    static let moreReselect = 25
    static let moreRoundedCorners = 26
    static let moreShadow = 27
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
    rootStack.spacing = 8
    rootStack.detachesHiddenViews = true
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
    // 高度按行的实际内容计算：主行按钮最高 28pt、选项行随控件而定。
    // 之前写死 38/36pt 行高会让声明的尺寸大于内容，NSStackView 顶部
    // 对齐时多余空间全部落到工具条底部，看起来上下留白不对称。
    let primaryHeight = primaryRow?.fittingSize.height ?? 0
    let optionsHeight = optionsVisible ? (optionsRow?.fittingSize.height ?? 0) : 0
    let contentHeight = optionsHeight > 0
      ? primaryHeight + Self.rowSpacing + optionsHeight
      : primaryHeight
    // 宽度跟随实际内容：空闲时橡皮/撤销隐藏，标注会话中它们出现，
    // 固定宽度会导致标注模式下内容溢出、空闲时右侧留白。
    let insets = rootStack.edgeInsets
    let primaryWidth = primaryRow?.fittingSize.width ?? 0
    let optionsWidth = optionsVisible ? (optionsRow?.fittingSize.width ?? 0) : 0
    let width = max(primaryWidth, optionsWidth) + insets.left + insets.right
    return NSSize(
      width: max(240, width),
      height: contentHeight + insets.top + insets.bottom
    )
  }

  private static let rowSpacing: CGFloat = 8

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
    // 按钮之间保持统一间距；隐藏的橡皮/撤销必须真正脱离布局，否则空闲时
    // 会在马赛克和分隔线之间留下一个大空洞（NSStackView 默认不脱离）。
    row.spacing = 4
    row.detachesHiddenViews = true

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

    // Tool groups with sub-tool menus (iShot's ▾ affordance).
    makeToolGroup(.shape, in: row)
    makeToolGroup(.pencil, in: row)
    makeToolGroup(.arrow, in: row)
    row.addArrangedSubview(makeSingleToolButton("t.square", titleKey: "scAnnotationText", tool: .text, tag: BarTag.text))
    row.addArrangedSubview(makeSingleToolButton("1.circle", titleKey: "scAnnotationCounter", tool: .counter, tag: BarTag.counter))
    row.addArrangedSubview(makeSingleToolButton("circle.lefthalf.filled", titleKey: "scAnnotationBlur", tool: .blur, tag: BarTag.mosaic))
    row.addArrangedSubview(makeSingleToolButton("circle.dashed.inset.filled", titleKey: "scAnnotationSpotlight", tool: .spotlight, tag: BarTag.spotlight))

    let eraser = makeSingleToolButton("eraser", titleKey: "scAnnotationEraser", tool: .eraser, tag: BarTag.eraser)
    eraser.isHidden = true
    row.addArrangedSubview(eraser)
    eraserButton = eraser

    let undo = makeSingleToolButton("arrow.uturn.backward", titleKey: "scUndo", tool: nil, tag: BarTag.undo)
    undo.isEnabled = false
    undo.isHidden = true
    row.addArrangedSubview(undo)
    undoButton = undo

    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    row.addArrangedSubview(separator)
    separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
    separator.heightAnchor.constraint(equalToConstant: 20).isActive = true

    row.addArrangedSubview(makeActionButton("text.viewfinder", titleKey: "scToolOCR", tag: BarTag.ocr))
    row.addArrangedSubview(makeActionButton("pin", titleKey: "scPin", tag: BarTag.pin))
    row.addArrangedSubview(makeActionButton("square.and.arrow.down", titleKey: "scToolSave", tag: BarTag.save))
    row.addArrangedSubview(makeActionButton("xmark", titleKey: "scClose", tag: BarTag.close))
    row.addArrangedSubview(makeActionButton("doc.on.doc", titleKey: "scCopy", tag: BarTag.copy))
    row.addArrangedSubview(makeMoreButton())

    row.translatesAutoresizingMaskIntoConstraints = false
    primaryRow = row
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
    widthSlider = nil
    colorWell = nil
    optionsCollapseButton = nil
    swatchButtons.removeAll()
    optionsRowCollapsed = false

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
    row.edgeInsets = NSEdgeInsets(top: 4, left: 22, bottom: 4, right: 8)

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

    if !row.arrangedSubviews.isEmpty {
      let collapseButton = makeOptionsCollapseButton()
      row.addArrangedSubview(collapseButton)
      optionsCollapseButton = collapseButton
    }
    row.translatesAutoresizingMaskIntoConstraints = false
    row.isHidden = row.arrangedSubviews.isEmpty || optionsRowCollapsed
    optionsRow = row
    rootStack.addArrangedSubview(row)
    invalidateIntrinsicContentSize()
  }

  private func makeOptionsCollapseButton() -> NSButton {
    let symbol = NSImage(
      systemSymbolName: "xmark",
      accessibilityDescription: AppText.value("scAnnotationHideOptions", language: .system)
    )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    let button = NSButton(
      image: symbol ?? NSImage(),
      target: self,
      action: #selector(hideOptionsPressed(_:))
    )
    configureBarButton(button, tooltipKey: "scAnnotationHideOptions")
    button.contentTintColor = NSColor.white.withAlphaComponent(0.72)
    button.widthAnchor.constraint(equalToConstant: 24).isActive = true
    button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    return button
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

  /// Line style lives on a plain button that pops its menu explicitly:
  /// NSPopUpButton's built-in tracking is unreliable inside the borderless,
  /// non-activating selection panel (the menu either never opens or the
  /// selection action is dropped through the responder chain), which made
  /// 实线/虚线/点线 impossible to switch.
  private var lineStyleButton: NSButton?

  private func makeLineStylePopUp(_ model: SmartAnnotationModel) -> NSView {
    let button = NSButton(
      image: Self.lineStylePreview(model.currentStyle.lineStyle),
      target: self,
      action: #selector(lineStylePressed(_:))
    )
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    button.layer?.cornerRadius = 6
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.toolTip = AppText.value("scAnnotationLineStyle", language: .system)
    button.setAccessibilityLabel(AppText.value("scAnnotationLineStyle", language: .system))
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 40).isActive = true
    button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    lineStyleButton = button
    return button
  }

  @objc private func lineStylePressed(_ sender: NSButton) {
    guard let model = annotationBinding?.model else { return }
    let menu = NSMenu()
    for lineStyle in SmartAnnotationLineStyle.allCases {
      let item = NSMenuItem(
        title: lineStyle.title(language: .system),
        action: #selector(lineStyleMenuItemSelected(_:)),
        keyEquivalent: ""
      )
      item.tag = lineStyleIndex(lineStyle)
      item.image = Self.lineStylePreview(lineStyle)
      item.state = model.currentStyle.lineStyle == lineStyle ? .on : .off
      // Explicit target: nil-targeted menu items dispatch through the
      // responder chain, which the non-activating panel does not guarantee.
      item.target = self
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
  }

  @objc private func lineStyleMenuItemSelected(_ sender: NSMenuItem) {
    annotationBinding?.model?.setLineStyle(lineStyle(forIndex: sender.tag))
    if let style = annotationBinding?.model?.currentStyle.lineStyle {
      lineStyleButton?.image = Self.lineStylePreview(style)
    }
  }

  /// 粗细直接用行内滑块：nonactivating 面板里 NSPopover（与当年的
  /// NSPopUpButton 一样）无法可靠弹出，行内控件是唯一确定可用的形态，
  /// 也让用户在画出第一个标注之前就能预设粗细。
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

    let slider = NSSlider(value: Double(model.currentStyle.lineWidth), minValue: 1, maxValue: 48, target: self, action: #selector(widthSliderChanged(_:)))
    slider.isContinuous = true
    slider.controlSize = .small
    slider.toolTip = AppText.value(titleKey, language: .system)
    slider.setAccessibilityLabel(AppText.value(titleKey, language: .system))
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(equalToConstant: 72).isActive = true
    widthSlider = slider

    let value = NSTextField(labelWithString: "\(Int(model.currentStyle.lineWidth.rounded()))")
    value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    value.textColor = .white
    value.toolTip = AppText.value(titleKey, language: .system)
    widthValueLabel = value

    stack.addArrangedSubview(icon)
    stack.addArrangedSubview(slider)
    stack.addArrangedSubview(value)
    return stack
  }

  @objc private func widthSliderChanged(_ sender: NSSlider) {
    annotationBinding?.model?.setLineWidth(CGFloat(sender.doubleValue.rounded()))
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
    widthSlider?.doubleValue = Double(model.currentStyle.lineWidth)
    lineStyleButton?.image = Self.lineStylePreview(model.currentStyle.lineStyle)
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
    case BarTag.spotlight: tool = .spotlight
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
      item.target = self
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
      let wasAlreadySelected = model.tool == tool
      model.selectTool(tool)
      // The tool-drift check inside syncWithModel rebuilds the options row.
      syncWithModel()
      if wasAlreadySelected {
        toggleOptionsRow()
      }
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
    case .spotlight: return .spotlight
    case .eraser: return .eraser
    case .crop: return .crop
    case .watermark: return nil
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
    makeMoreMenu().popUp(
      positioning: nil,
      at: NSPoint(x: 0, y: sender.frame.height + 2),
      in: sender
    )
  }

  /// Builds the 「更多」 menu. The former right-hand side column (圆角截图 /
  /// 调整选区 / 阴影或边框 / 刷新截图 / 重新选择) lives here so the post-selection
  /// HUD is one bar.
  ///
  /// The frame commands are omitted while an annotation session is live: the
  /// canvas owns the frame then, so 调整选区 has nothing to enter, 刷新截图 would
  /// swap the bitmap the annotations are drawn on, and 重新选择 would tear the
  /// session down from underneath the editor. The style toggles stay: they are
  /// non-terminal and are applied when the session commits.
  func makeMoreMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(makeMoreItem(
      "icloud.and.arrow.up",
      titleKey: "scImageHostingUpload",
      tag: BarTag.moreUpload
    ))
    if !isAnnotating {
      menu.addItem(makeMoreItem(
        "scissors",
        titleKey: "scAnnotationCrop",
        tag: BarTag.moreCrop
      ))
      menu.addItem(.separator())
      menu.addItem(makeMoreItem(
        "arrow.clockwise",
        titleKey: "scToolRefresh",
        tag: BarTag.moreRefresh
      ))
      menu.addItem(makeMoreItem(
        "arrow.up.left.and.arrow.down.right",
        titleKey: "scAdjustSelection",
        tag: BarTag.moreAdjust
      ))
      menu.addItem(makeMoreItem(
        "rectangle.dashed",
        titleKey: "scToolReselect",
        tag: BarTag.moreReselect
      ))
    }
    menu.addItem(.separator())
    menu.addItem(makeMoreItem(
      "rectangle.dashed.inset.filled",
      titleKey: "scToolRoundedCorners",
      tag: BarTag.moreRoundedCorners,
      isOn: outputStyleState.roundedCorners
    ))
    menu.addItem(makeMoreItem(
      "circle.lefthalf.filled",
      titleKey: "scToolShadow",
      tag: BarTag.moreShadow,
      isOn: outputStyleState.shadow
    ))
    return menu
  }

  private func makeMoreItem(
    _ symbolName: String,
    titleKey: String,
    tag: Int,
    isOn: Bool = false
  ) -> NSMenuItem {
    let item = NSMenuItem(
      title: AppText.value(titleKey, language: .system),
      action: #selector(moreItemSelected(_:)),
      keyEquivalent: ""
    )
    item.tag = tag
    // Explicit target: nil-targeted menu items dispatch through the
    // responder chain, which the non-activating panel does not guarantee.
    item.target = self
    item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    item.state = isOn ? .on : .off
    return item
  }

  @objc private func moreItemSelected(_ sender: NSMenuItem) {
    handleMoreItem(tag: sender.tag)
  }

  /// Routes a 「更多」 menu selection. Internal so tests can cover the mapping
  /// without popping a real menu on the non-activating panel.
  func handleMoreItem(tag: Int) {
    switch tag {
    case BarTag.moreUpload: perform(.upload)
    case BarTag.moreCrop: perform(.annotateTool(.crop))
    case BarTag.moreRefresh: perform(.refreshCapture)
    case BarTag.moreAdjust: perform(.adjustSelection)
    case BarTag.moreReselect: perform(.newSelection)
    case BarTag.moreRoundedCorners: perform(.toggleRoundedCorners)
    case BarTag.moreShadow: perform(.toggleShadow)
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

  @objc private func hideOptionsPressed(_ sender: NSButton) {
    guard let optionsRow, optionsCollapseButton != nil else { return }
    optionsRowCollapsed = true
    optionsRow.isHidden = true
    invalidateIntrinsicContentSize()
    layoutDidChange?()
  }

  private func toggleOptionsRow() {
    guard let optionsRow, optionsCollapseButton != nil else { return }
    optionsRowCollapsed.toggle()
    optionsRow.isHidden = optionsRowCollapsed
    invalidateIntrinsicContentSize()
    layoutDidChange?()
  }

  @objc private func shapeSegmentChanged(_ sender: NSSegmentedControl) {
    guard let model = annotationBinding?.model else { return }
    model.selectTool(sender.selectedSegment == 1 ? .ellipse : .rectangle)
    syncWithModel()
  }

  @objc private func fillChanged(_ sender: NSButton) {
    annotationBinding?.model?.setFillEnabled(sender.state == .on)
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

// MARK: - Post-selection HUD Layout

/// 纯函数布局：把唯一的截图操作栏放在选区附近并保证完整落在屏幕内。
/// 优先放选区下方，下方放不下时改放上方（取空间更大的一侧）；
/// 水平以选区为中心并夹回屏幕。近全屏选区上下都没有空间时，操作栏
/// 收进选区内侧底部，避免夹回屏幕后骑跨选区边框。
///
/// 录屏选区操作栏共用同一套算术（`RecordingSelectionBarLayout` 转发到这里），
/// 两个入口的 HUD 位置因此始终一致。
nonisolated enum AreaSelectionBarLayout {
  static let gap: CGFloat = 16
  static let edgeMargin: CGFloat = 8
  /// 全屏/近全屏时操作栏收进选区内侧的底边距。
  static let insideInset: CGFloat = 20

  static func resolve(
    selectionRect: CGRect,
    barSize: CGSize,
    bounds: CGSize
  ) -> CGRect {
    let maxX = max(edgeMargin, bounds.width - barSize.width - edgeMargin)
    let maxY = max(edgeMargin, bounds.height - barSize.height - edgeMargin)
    let spaceBelow = selectionRect.minY - edgeMargin
    let spaceAbove = bounds.height - edgeMargin - selectionRect.maxY
    let preferBelow = spaceBelow >= barSize.height || spaceBelow >= spaceAbove
    let proposedY = preferBelow
      ? selectionRect.minY - gap - barSize.height
      : selectionRect.maxY + gap
    let frame = CGRect(
      x: min(maxX, max(edgeMargin, selectionRect.midX - barSize.width / 2)),
      y: min(maxY, max(edgeMargin, proposedY)),
      width: barSize.width,
      height: barSize.height
    )
    guard frame.intersects(selectionRect) else { return frame }
    return CGRect(
      x: min(maxX, max(edgeMargin, selectionRect.midX - barSize.width / 2)),
      y: min(maxY, max(edgeMargin, selectionRect.minY + insideInset)),
      width: barSize.width,
      height: barSize.height
    )
  }
}
