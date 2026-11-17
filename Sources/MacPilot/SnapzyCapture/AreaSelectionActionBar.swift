//
//  AreaSelectionActionBar.swift
//  MacPilot's iShot-style post-selection controls.
//
//  The bar deliberately stays in AppKit.  The selection overlay is an
//  NSPanel that must remain above other applications, and AppKit buttons keep
//  the first click/keyboard focus behaviour deterministic while the panel is
//  non-activating.
//
//  Interaction model (matching Snapzy's InlineAreaControlDeck): one permanent
//  horizontal tool row where every implemented annotation tool has its own
//  button, with dividers as the only grouping; undo/redo sit beside the tools.
//  The capture actions (OCR/pin/upload/save/copy/更多/close) live in a separate
//  vertical column anchored to the right edge of the selected screenshot, so
//  they are always visible without widening or displacing the tool deck. When
//  an annotation session is active the column adds the terminal actions
//  (完成 / Copy & Close) and the deck adds a contextual properties row for the
//  current tool, expanded by default.
//
//  iShot's former right-hand column commands (圆角截图 / 调整选区 / 阴影或边框 /
//  刷新截图 / 重新选择) stay in 「更多」: three of them duplicate gestures the
//  frame already supports, and the column itself is now reserved for the
//  always-visible actions.
//
//  Its chrome is not bespoke: the card and the round tool chips are all drawn
//  from `CaptureChromeStyle`, so the toolbar moves as one surface whenever that
//  palette is retuned.  The pinned-screenshot window deliberately does *not*
//  share it — a pin is a floating picture, not a tool, and carries its own
//  `PinnedScreenshotChromeStyle`.
//

import AppKit
import Combine

@MainActor
final class AreaSelectionActionBar: NSView {
  /// One AppKit card renders in two roles: the horizontal tool deck below the
  /// selection, and the vertical action column beside it. They share the same
  /// chips, typography and dispatch path but never occupy the same surface.
  enum Mode {
    case tools
    case actions
  }

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

  private let mode: Mode
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
  private var redoButton: NSButton?
  private var eraserButton: NSButton?
  private var completeButton: NSButton?
  private var copyAndCloseButton: NSButton?
  /// Tool chips stay visible for the whole post-selection lifetime: the first
  /// click starts the annotation session with that tool, later clicks switch
  /// tools. Nothing is hidden behind a stage or a dropdown.
  private var toolViews: [NSView] = []
  private var primaryActionViews: [NSView] = []
  private var widthValueLabel: NSTextField?
  private var widthSlider: NSSlider?
  private var shapeSegmented: NSSegmentedControl?
  private var fillCheckbox: NSButton?
  private var colorWell: NSColorWell?
  private var optionsCollapseButton: NSButton?
  private var swatchButtons: [NSButton] = []
  /// Every circular tool chip the bar has built. Internal so the chrome tests
  /// can assert they come out of `CaptureChromeStyle` rather than ad-hoc
  /// numbers.
  var chipButtons: [NSButton] = []
  private var toolDisplayButtons: [SmartAnnotationTool: NSButton] = [:]
  private var toolTagMap: [Int: SmartAnnotationTool] = [:]
  /// The tool the options row was last built for. Selecting an existing
  /// annotation on the canvas swaps `model.tool` outside the bar, so
  /// `syncWithModel` rebuilds the row whenever this drifts.
  private var optionsRowTool: SmartAnnotationTool?
  private var optionsRowCollapsed = false

  private enum BarTag {
    static let text = 1
    static let counter = 2
    static let mosaic = 3
    static let spotlight = 11
    static let eraser = 4
    static let undo = 5
    static let redo = 14
    static let copyAndClose = 15
    static let ocr = 6
    static let pin = 7
    static let save = 8
    static let close = 9
    static let copy = 10
    static let annotate = 12
    static let finish = 13
    static let upload = 16
    /// 「更多」 menu items. The former right-hand column lives here now.
    static let moreCrop = 22
    static let moreRefresh = 23
    static let moreAdjust = 24
    static let moreReselect = 25
    static let moreRoundedCorners = 26
    static let moreShadow = 27
    static let moreScrolling = 28
  }

  init(mode: Mode = .tools, onAction: @escaping (AreaSelectionAction) -> Void) {
    self.mode = mode
    self.onAction = onAction
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = CaptureChromeStyle.cardCornerRadius
    layer?.borderWidth = 1
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = Float(CaptureChromeStyle.shadowOpacity)
    layer?.shadowRadius = CaptureChromeStyle.shadowRadius
    layer?.shadowOffset = CaptureChromeStyle.shadowOffset
    resolveChromeColors()

    rootStack.orientation = .vertical
    rootStack.alignment = .leading
    rootStack.spacing = CaptureChromeStyle.barRowSpacing
    rootStack.detachesHiddenViews = true
    rootStack.edgeInsets = CaptureChromeStyle.barContentInset
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rootStack)

    switch mode {
    case .tools:
      NSLayoutConstraint.activate([
        rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
        rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        rootStack.topAnchor.constraint(equalTo: topAnchor),
        rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
      rootStack.addArrangedSubview(makePrimaryRow())
    case .actions:
      rootStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
      NSLayoutConstraint.activate([
        rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
        rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        rootStack.topAnchor.constraint(equalTo: topAnchor),
        rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
      rootStack.addArrangedSubview(makeActionColumn())
    }
    applyStageVisibility()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    switch mode {
    case .tools:
      // The tool deck is a compact horizontal card: tool row plus the
      // contextual properties row while it is expanded.
      let size = rootStack.fittingSize
      return NSSize(width: max(240, size.width), height: size.height)
    case .actions:
      // The action column hangs beside the screenshot, so it is tall and
      // narrow instead of widening the bar itself.
      let size = rootStack.fittingSize
      return NSSize(width: max(46, size.width), height: size.height)
    }
  }

  private static let rowSpacing: CGFloat = 8

  // MARK: - Chrome Style

  /// Layer colours are resolved `CGColor`s, so they do not follow the system
  /// appearance on their own.  Re-resolve them from `CaptureChromeStyle` every
  /// time the effective appearance changes.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    resolveChromeColors()
  }

  private func resolveChromeColors() {
    // Semantic colours only flatten to concrete RGB when they are resolved, so
    // resolve them inside this view's appearance rather than the process one.
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = CaptureChromeStyle.cardFill.cgColor
      layer?.borderColor = CaptureChromeStyle.cardStroke.cgColor
      refreshChips()
      refreshSwatchRings()
      lineStyleButton?.layer?.backgroundColor = CaptureChromeStyle.chipFillOnCard.cgColor
      lineStyleButton?.layer?.borderColor = CaptureChromeStyle.chipStroke.cgColor
    }
  }

  /// The one chip that carries the session's current tool is filled with the
  /// accent colour; every other chip keeps the resting wash.
  private func refreshChips() {
    let activeButton = annotationBinding?.model.flatMap { model in
      toolDisplayButtons[model.tool]
    }
    for button in chipButtons {
      let active = button === activeButton
      button.layer?.backgroundColor = (active
        ? CaptureChromeStyle.chipFillActive
        : CaptureChromeStyle.chipFillOnCard).cgColor
      button.layer?.borderColor = CaptureChromeStyle.chipStroke.cgColor
      button.contentTintColor = active
        ? CaptureChromeStyle.glyphOnAccent
        : CaptureChromeStyle.glyph
    }
  }

  private func refreshSwatchRings() {
    guard let current = annotationBinding?.model?.currentStyle.color else { return }
    for button in swatchButtons {
      let selected = swatchColor(forTag: button.tag) == current
      button.layer?.borderWidth = selected ? 2 : 1
      button.layer?.borderColor = (selected
        ? NSColor.controlAccentColor
        : CaptureChromeStyle.swatchRing).cgColor
    }
  }

  // MARK: - Annotation Session Binding

  func bindAnnotationSession(_ binding: AnnotationBinding?) {
    // A new session starts with the properties row expanded; the collapse is
    // a per-session choice, not a setting that leaks into the next capture.
    let wasAnnotating = isAnnotating
    annotationBinding = binding
    if binding != nil, !wasAnnotating {
      optionsRowCollapsed = false
    }
    modelCancellable?.cancel()
    modelCancellable = nil
    if let model = binding?.model {
      modelCancellable = model.objectWillChange
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
          self?.syncWithModel()
        }
    }
    // The eraser/undo controls stay mounted; only the terminal annotation
    // actions and the properties row depend on the session. The action column
    // has no properties row: it only reveals its terminal actions.
    applyStageVisibility()
    if mode == .tools {
      rebuildOptionsRow()
      syncWithModel()
    }
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
    row.spacing = CaptureChromeStyle.barItemSpacing
    row.detachesHiddenViews = true

    let grip = NSImageView(
      image: NSImage(
        systemSymbolName: "line.3.horizontal",
        accessibilityDescription: AppText.value("scToolDragBar", language: .system)
      ) ?? NSImage()
    )
    grip.contentTintColor = CaptureChromeStyle.glyphFaint
    grip.imageScaling = .scaleProportionallyDown
    grip.toolTip = AppText.value("scToolDragBar", language: .system)
    grip.translatesAutoresizingMaskIntoConstraints = false
    row.addArrangedSubview(grip)
    grip.widthAnchor.constraint(equalToConstant: 14).isActive = true
    grip.heightAnchor.constraint(equalToConstant: 20).isActive = true
    row.setCustomSpacing(2, after: grip)

    // Every implemented tool gets its own button. Snapzy's InlineAreaControlDeck
    // groups tools with dividers only; it never hides a variant behind a
    // primary button plus chevron menu. The previous grouped design forced two
    // clicks for the most common tools (rectangle/ellipse, pencil/highlighter,
    // arrow/line) and is deliberately gone.
    let groups: [[SmartAnnotationTool]] = [
      [.rectangle, .filledRectangle, .ellipse],
      [.arrow, .line, .pencil, .highlighter],
      [.text, .watermark, .counter],
      [.blur, .spotlight],
      [.eraser],
    ]
    for (groupIndex, group) in groups.enumerated() {
      if groupIndex > 0 {
        row.addArrangedSubview(makeDivider())
      }
      for tool in group {
        let tag = 30 + (SmartAnnotationTool.allCases.firstIndex(of: tool) ?? 0)
        let button = makeSingleToolButton(
          tool.systemImage,
          titleKey: tool.titleKey,
          tool: tool,
          tag: tag
        )
        toolTagMap[tag] = tool
        row.addArrangedSubview(button)
        toolViews.append(button)
        if tool == .eraser { eraserButton = button }
      }
    }

    row.addArrangedSubview(makeDivider())

    let undo = makeSingleToolButton("arrow.uturn.backward", titleKey: "scUndo", tool: nil, tag: BarTag.undo)
    undo.isEnabled = false
    row.addArrangedSubview(undo)
    undoButton = undo

    let redo = makeSingleToolButton("arrow.uturn.forward", titleKey: "scRedo", tool: nil, tag: BarTag.redo)
    redo.isEnabled = false
    row.addArrangedSubview(redo)
    redoButton = redo

    row.translatesAutoresizingMaskIntoConstraints = false
    primaryRow = row
    return row
  }

  /// The action column hangs beside the screenshot: OCR/pin/upload and the
  /// output actions are a single vertical list, never a block wedged into the
  /// tool bar. `detachesHiddenViews` keeps the terminal group out of the
  /// layout until an annotation session starts.
  private func makeActionColumn() -> NSStackView {
    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .centerX
    column.spacing = CaptureChromeStyle.barItemSpacing
    column.detachesHiddenViews = true

    let copyAndClose = makeActionButton(
      image: Self.copyAndCloseGlyph(),
      titleKey: "scCopyAndClose",
      tag: BarTag.copyAndClose
    )
    copyAndClose.isHidden = true
    copyAndCloseButton = copyAndClose
    let finish = makeActionButton("checkmark", titleKey: "scToolFinish", tag: BarTag.finish)
    finish.isHidden = true
    completeButton = finish

    let actions: [NSButton] = [
      makeActionButton("text.viewfinder", titleKey: "scToolOCR", tag: BarTag.ocr),
      makeActionButton("pin", titleKey: "scPin", tag: BarTag.pin),
      makeActionButton("icloud.and.arrow.up", titleKey: "scImageHostingUpload", tag: BarTag.upload),
      makeActionButton("square.and.arrow.down", titleKey: "scToolSave", tag: BarTag.save),
      makeActionButton("doc.on.doc", titleKey: "scCopy", tag: BarTag.copy),
      makeMoreButton(),
      copyAndClose,
      finish,
      makeActionButton("xmark", titleKey: "scClose", tag: BarTag.close),
    ]
    for action in actions {
      column.addArrangedSubview(action)
      primaryActionViews.append(action)
    }
    // Breathing room between capture utilities, output actions and the
    // terminal actions without adding dividers that would survive hiding.
    column.setCustomSpacing(CaptureChromeStyle.barRowSpacing, after: actions[2])
    column.setCustomSpacing(CaptureChromeStyle.barRowSpacing, after: actions[5])
    return column
  }

  private func makeDivider() -> NSView {
    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
    separator.heightAnchor.constraint(equalToConstant: CaptureChromeStyle.barDividerHeight).isActive = true
    return separator
  }

  /// The only visibility switch: tools and capture actions are permanent; the
  /// terminal annotation actions (checkmark / Copy & Close) are contextual.
  /// Save/copy stay reachable while annotating because they commit the
  /// annotated pixels.
  private func applyStageVisibility() {
    let annotating = isAnnotating
    // Tools are never stage-gated and never hidden; only the terminal
    // annotation actions (checkmark / Copy & Close) are contextual.
    for view in toolViews { view.isHidden = false }
    undoButton?.isHidden = false
    redoButton?.isHidden = false
    for view in primaryActionViews { view.isHidden = false }
    completeButton?.isHidden = !annotating
    copyAndCloseButton?.isHidden = !annotating
    invalidateIntrinsicContentSize()
    layoutDidChange?()
  }

  /// Retained for tests and the controller: which tool chips are visible.
  var visibleToolButtons: [NSButton] {
    toolViews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
  }

  var toolButtonsByTool: [SmartAnnotationTool: NSButton] { toolDisplayButtons }
  var undoControl: NSButton? { undoButton }
  var redoControl: NSButton? { redoButton }
  var copyAndCloseControl: NSButton? { copyAndCloseButton }
  var finishControl: NSButton? { completeButton }

  private func makeSingleToolButton(
    _ symbolName: String,
    titleKey: String,
    tool: SmartAnnotationTool?,
    tag: Int
  ) -> NSButton {
    let button = makeChip(
      symbolName: symbolName,
      action: #selector(toolPressed(_:)),
      tooltipKey: titleKey
    )
    button.tag = tag
    if let tool {
      toolDisplayButtons[tool] = button
    }
    return button
  }

  private func makeActionButton(_ symbolName: String, titleKey: String, tag: Int) -> NSButton {
    makeActionButton(image: Self.chipGlyph(symbolName), titleKey: titleKey, tag: tag)
  }

  private func makeActionButton(image: NSImage, titleKey: String, tag: Int) -> NSButton {
    let button = makeChip(
      image: image,
      action: #selector(actionPressed(_:)),
      tooltipKey: titleKey
    )
    button.tag = tag
    return button
  }

  private func makeMoreButton() -> NSButton {
    makeChip(
      symbolName: "ellipsis",
      action: #selector(morePressed(_:)),
      tooltipKey: "scToolMore"
    )
  }

  /// A circular `CaptureChromeStyle` chip.
  /// A symbol drawn on a chip-sized canvas.
  ///
  /// The canvas is not decoration: an `NSButton` adds required content-size
  /// constraints from its image and its baseline, so a 17×14 glyph fights the
  /// chip's own 28×28 constraints and the solver settles on a 28×33 box — fine
  /// while the button is invisible, an oval blob once it carries a fill. Give
  /// the button an image that already *is* the chip and nothing is left to
  /// fight. A drawing handler (rather than a bitmap) keeps it crisp at any
  /// backing scale.
  private static func chipGlyph(_ symbolName: String) -> NSImage {
    let side = CaptureChromeStyle.chipSide
    let canvasSize = NSSize(width: side, height: side)
    let glyph = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 13.5, weight: .semibold))
    let image = NSImage(size: canvasSize, flipped: false) { _ in
      guard let glyph else { return true }
      let size = glyph.size
      glyph.draw(
        in: NSRect(
          x: (side - size.width) / 2,
          y: (side - size.height) / 2,
          width: size.width,
          height: size.height
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
      )
      return true
    }
    image.isTemplate = true
    return image
  }

  /// Copy & Close has no single SF Symbol that reads as "two documents plus a
  /// check": draw the pair on one template canvas so the chip is never blank.
  private static func copyAndCloseGlyph() -> NSImage {
    let side = CaptureChromeStyle.chipSide
    let canvasSize = NSSize(width: side, height: side)
    let documents = NSImage(
      systemSymbolName: "doc.on.doc",
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    let check = NSImage(
      systemSymbolName: "checkmark.circle.fill",
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
    let image = NSImage(size: canvasSize, flipped: false) { _ in
      documents?.draw(
        in: NSRect(x: side * 0.12, y: side * 0.26, width: side * 0.60, height: side * 0.60),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
      )
      check?.draw(
        in: NSRect(x: side * 0.54, y: side * 0.06, width: side * 0.40, height: side * 0.40),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
      )
      return true
    }
    image.isTemplate = true
    return image
  }

  private func makeChip(
    symbolName: String,
    action: Selector,
    tooltipKey: String
  ) -> NSButton {
    makeChip(image: Self.chipGlyph(symbolName), action: action, tooltipKey: tooltipKey)
  }

  private func makeChip(
    image: NSImage,
    action: Selector,
    tooltipKey: String
  ) -> NSButton {
    let button = NSButton(image: image, target: self, action: action)
    configureChip(button, tooltipKey: tooltipKey)
    return button
  }

  private func configureChip(_ button: NSButton, tooltipKey: String) {
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    let tooltip = AppText.value(tooltipKey, language: .system)
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
    button.wantsLayer = true
    button.layer?.cornerRadius = CaptureChromeStyle.chipCornerRadius
    button.layer?.borderWidth = 1
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: CaptureChromeStyle.chipSide).isActive = true
    button.heightAnchor.constraint(equalToConstant: CaptureChromeStyle.chipSide).isActive = true
    chipButtons.append(button)
    refreshChips()
  }

  // MARK: - Row Two: Contextual Options

  private func rebuildOptionsRow() {
    if let optionsRow {
      optionsRow.removeFromSuperview()
      self.optionsRow = nil
    }
    // The discarded row owned a chip: drop it from the list so it can be
    // released and a rebuilt row does not re-style a dead button.
    if let optionsCollapseButton {
      chipButtons.removeAll { $0 === optionsCollapseButton }
    }
    shapeSegmented = nil
    fillCheckbox = nil
    widthValueLabel = nil
    widthSlider = nil
    colorWell = nil
    optionsCollapseButton = nil
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
    row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 2, right: 0)

    switch model.tool {
    case .rectangle, .filledRectangle, .ellipse:
      row.addArrangedSubview(makeShapeSwitch(model))
      // A filled rectangle is always filled; its fill checkbox would be a
      // control with no visible effect.
      if model.tool != .filledRectangle {
        row.addArrangedSubview(makeFillCheckbox(model))
      }
      row.addArrangedSubview(makeLineStylePopUp(model))
      row.addArrangedSubview(makeWidthControl(model, titleKey: "scAnnotationLineWidth"))
      row.addArrangedSubview(makeOpacityControl(model))
      row.addArrangedSubview(makeColorControls(model))
    case .arrow, .line:
      row.addArrangedSubview(makeLineStylePopUp(model))
      row.addArrangedSubview(makeWidthControl(model, titleKey: "scAnnotationLineWidth"))
      row.addArrangedSubview(makeOpacityControl(model))
      row.addArrangedSubview(makeColorControls(model))
    case .pencil:
      row.addArrangedSubview(makeWidthControl(model, titleKey: "scAnnotationLineWidth"))
      row.addArrangedSubview(makeOpacityControl(model))
      row.addArrangedSubview(makeColorControls(model))
    case .highlighter:
      row.addArrangedSubview(makeColorControls(model))
    case .text, .watermark, .counter:
      row.addArrangedSubview(makeWidthControl(model, titleKey: "scToolSize"))
      row.addArrangedSubview(makeOpacityControl(model))
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
    case .blur, .spotlight, .crop:
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
    makeChip(
      symbolName: "xmark",
      action: #selector(hideOptionsPressed(_:)),
      tooltipKey: "scAnnotationHideOptions"
    )
  }

  private func makeShapeSwitch(_ model: SmartAnnotationModel) -> NSView {
    let control = NSSegmentedControl(
      images: [
        NSImage(systemSymbolName: "rectangle", accessibilityDescription: nil) ?? NSImage(),
        NSImage(systemSymbolName: "rectangle.fill", accessibilityDescription: nil) ?? NSImage(),
        NSImage(systemSymbolName: "oval", accessibilityDescription: nil) ?? NSImage(),
      ],
      trackingMode: .selectOne,
      target: self,
      action: #selector(shapeSegmentChanged(_:))
    )
    control.segmentStyle = .roundRect
    control.selectedSegment = Self.shapeSwitchIndex(for: model.tool)
    control.setToolTip(AppText.value("scAnnotationRectangle", language: .system), forSegment: 0)
    control.setToolTip(AppText.value("scAnnotationFilledRectangle", language: .system), forSegment: 1)
    control.setToolTip(AppText.value("scAnnotationEllipse", language: .system), forSegment: 2)
    shapeSegmented = control
    return control
  }

  private static let shapeSwitchTools: [SmartAnnotationTool] = [
    .rectangle, .filledRectangle, .ellipse,
  ]

  private static func shapeSwitchIndex(for tool: SmartAnnotationTool) -> Int {
    shapeSwitchTools.firstIndex(of: tool) ?? 0
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
    button.layer?.backgroundColor = CaptureChromeStyle.chipFillOnCard.cgColor
    button.layer?.cornerRadius = 12
    button.layer?.borderWidth = 1
    button.layer?.borderColor = CaptureChromeStyle.chipStroke.cgColor
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.contentTintColor = CaptureChromeStyle.glyph
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
    icon.contentTintColor = CaptureChromeStyle.glyphMuted
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 12).isActive = true

    let slider = StreakSlider(value: Double(model.currentStyle.lineWidth), minValue: 1, maxValue: 48, target: self, action: #selector(widthSliderChanged(_:)))
    slider.isContinuous = true
    slider.onEditingEnded = { [weak self] in
      self?.annotationBinding?.model?.endStyleEditing()
    }
    slider.controlSize = .small
    slider.toolTip = AppText.value(titleKey, language: .system)
    slider.setAccessibilityLabel(AppText.value(titleKey, language: .system))
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(equalToConstant: 72).isActive = true
    widthSlider = slider

    let value = NSTextField(labelWithString: "\(Int(model.currentStyle.lineWidth.rounded()))")
    value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    value.textColor = CaptureChromeStyle.glyph
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

  @objc private func opacitySliderChanged(_ sender: NSSlider) {
    annotationBinding?.model?.setOpacity(CGFloat(sender.doubleValue))
  }

  /// NSSlider fires continuously while dragging. The model merges consecutive
  /// changes for one field, and this subclass closes the streak on mouse-up so
  /// the next drag starts a fresh undo step.
  private final class StreakSlider: NSSlider {
    var onEditingEnded: (() -> Void)?
    override func mouseUp(with event: NSEvent) {
      super.mouseUp(with: event)
      onEditingEnded?()
    }
  }

  private func makeOpacityControl(_ model: SmartAnnotationModel) -> NSView {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 4

    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: "circle.lefthalf.filled",
        accessibilityDescription: AppText.value("scAnnotationOpacity", language: .system)
      ) ?? NSImage()
    )
    icon.contentTintColor = CaptureChromeStyle.glyphMuted
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 12).isActive = true

    let slider = StreakSlider(
      value: Double(model.currentStyle.opacity),
      minValue: 0.05,
      maxValue: 1,
      target: self,
      action: #selector(opacitySliderChanged(_:))
    )
    slider.isContinuous = true
    slider.controlSize = .small
    slider.toolTip = AppText.value("scAnnotationOpacity", language: .system)
    slider.setAccessibilityLabel(AppText.value("scAnnotationOpacity", language: .system))
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(equalToConstant: 64).isActive = true
    slider.onEditingEnded = { [weak self] in
      self?.annotationBinding?.model?.endStyleEditing()
    }

    let value = NSTextField(labelWithString: "\(Int((model.currentStyle.opacity * 100).rounded()))%")
    value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    value.textColor = CaptureChromeStyle.glyph
    value.toolTip = AppText.value("scAnnotationOpacity", language: .system)
    stack.addArrangedSubview(icon)
    stack.addArrangedSubview(slider)
    stack.addArrangedSubview(value)
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

  /// Template image: only its alpha matters, so the same preview stays legible
  /// on the chip in the bar and inside a system menu.
  private static func lineStylePreview(_ style: SmartAnnotationLineStyle) -> NSImage {
    let image = NSImage(size: NSSize(width: 34, height: 10))
    image.lockFocus()
    NSColor.black.setStroke()
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
    image.isTemplate = true
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
    guard mode == .tools else { return }
    guard let model = annotationBinding?.model else { return }
    let activeTool = model.tool
    if activeTool != optionsRowTool {
      // The canvas can switch tools underneath the bar (selecting an existing
      // annotation swaps the tool); rebuild the contextual row for it.
      rebuildOptionsRow()
    }

    for (tool, button) in toolDisplayButtons {
      let tooltip = AppText.value(tool.titleKey, language: .system)
      button.toolTip = tooltip
      button.setAccessibilityLabel(tooltip)
    }
    undoButton?.isEnabled = model.canUndo
    redoButton?.isEnabled = model.canRedo
    widthValueLabel?.stringValue = "\(Int(model.currentStyle.lineWidth.rounded()))"
    widthSlider?.doubleValue = Double(model.currentStyle.lineWidth)
    lineStyleButton?.image = Self.lineStylePreview(model.currentStyle.lineStyle)
    shapeSegmented?.selectedSegment = Self.shapeSwitchIndex(for: activeTool)
    fillCheckbox?.state = model.currentStyle.fillEnabled ? .on : .off
    colorWell?.color = model.currentStyle.color.nsColor
    refreshChips()
    refreshSwatchRings()
  }

  // MARK: - Actions

  @objc private func toolPressed(_ sender: NSButton) {
    switch sender.tag {
    case BarTag.undo:
      annotationBinding?.model?.undo()
      return
    case BarTag.redo:
      annotationBinding?.model?.redo()
      return
    default:
      break
    }
    guard let tool = toolTagMap[sender.tag] else { return }
    selectTool(tool)
  }

  private func selectTool(_ tool: SmartAnnotationTool) {
    if let model = annotationBinding?.model {
      let wasAlreadySelected = model.tool == tool
      model.endStyleEditing()
      model.selectTool(tool)
      // The tool-drift check inside syncWithModel rebuilds the options row.
      syncWithModel()
      // Clicking the already-active tool is the explicit way back to a
      // properties row the user collapsed. Switching tools never collapses it.
      if wasAlreadySelected && optionsRowCollapsed {
        toggleOptionsRow()
      }
      return
    }
    guard let mapped = Self.areaSelectionTool(for: tool) else { return }
    onAction(.annotateTool(mapped))
  }

  private static func areaSelectionTool(for tool: SmartAnnotationTool) -> AreaSelectionAnnotationTool? {
    switch tool {
    case .rectangle: return .rectangle
    case .filledRectangle: return .filledRectangle
    case .ellipse: return .ellipse
    case .arrow: return .arrow
    case .line: return .line
    case .pencil: return .pencil
    case .highlighter: return .highlighter
    case .text: return .text
    case .watermark: return .watermark
    case .counter: return .counter
    case .blur: return .blur
    case .spotlight: return .spotlight
    case .eraser: return .eraser
    case .crop: return .crop
    }
  }

  @objc private func actionPressed(_ sender: NSButton) {
    let action: AreaSelectionAction
    switch sender.tag {
    case BarTag.ocr: action = .ocr
    case BarTag.pin: action = .pin
    case BarTag.upload: action = .upload
    case BarTag.save: action = .save
    case BarTag.close: action = .cancel
    case BarTag.copy: action = .copy
    case BarTag.annotate: action = .annotate
    case BarTag.copyAndClose: action = .copyAndClose
    case BarTag.finish: action = .capture
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
    if !isAnnotating {
      menu.addItem(makeMoreItem(
        "arrow.down.to.line.compact",
        titleKey: "scScrollingCaptureNow",
        tag: BarTag.moreScrolling
      ))
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
    case BarTag.moreCrop: perform(.annotateTool(.crop))
    case BarTag.moreRefresh: perform(.refreshCapture)
    case BarTag.moreScrolling: perform(.scrollingCapture)
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
    guard let model = annotationBinding?.model,
          Self.shapeSwitchTools.indices.contains(sender.selectedSegment) else { return }
    model.selectTool(Self.shapeSwitchTools[sender.selectedSegment])
    syncWithModel()
  }

  @objc private func fillChanged(_ sender: NSButton) {
    annotationBinding?.model?.setFillEnabled(sender.state == .on)
    annotationBinding?.model?.endStyleEditing()
  }

  @objc private func customColorChanged(_ sender: NSColorWell) {
    annotationBinding?.model?.setColor(SmartAnnotationColor(sender.color))
    annotationBinding?.model?.endStyleEditing()
  }

  @objc private func swatchPressed(_ sender: NSButton) {
    guard let color = swatchColor(forTag: sender.tag) else { return }
    annotationBinding?.model?.setColor(color)
    annotationBinding?.model?.endStyleEditing()
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

  /// Places the tool deck without covering the action column that hangs beside
  /// the screenshot. The default anchor is still below/above the selection; if
  /// a small selection makes the wide deck run into the column, the deck first
  /// moves above the selection at its centred x, then beside the column.
  static func resolve(
    selectionRect: CGRect,
    barSize: CGSize,
    bounds: CGSize,
    avoiding railFrame: CGRect
  ) -> CGRect {
    let base = resolve(selectionRect: selectionRect, barSize: barSize, bounds: bounds)
    guard base.intersects(railFrame) else { return base }
    let maxX = max(edgeMargin, bounds.width - barSize.width - edgeMargin)
    let maxY = max(edgeMargin, bounds.height - barSize.height - edgeMargin)
    func candidate(x: CGFloat, y: CGFloat) -> CGRect? {
      let frame = CGRect(
        x: min(maxX, max(edgeMargin, x)),
        y: min(maxY, max(edgeMargin, y)),
        width: barSize.width,
        height: barSize.height
      )
      let insideBounds = frame.minX >= edgeMargin - 0.5
        && frame.minY >= edgeMargin - 0.5
        && frame.maxX <= bounds.width - edgeMargin + 0.5
        && frame.maxY <= bounds.height - edgeMargin + 0.5
      return insideBounds && !frame.intersects(railFrame) ? frame : nil
    }
    let spacing: CGFloat = 8
    // Keeping the deck centred under the selection matters more than keeping
    // it below: when the side column hangs into the below slot, the deck first
    // moves above the selection at the same centred x, then beside the column.
    let candidates = [
      candidate(x: base.minX, y: selectionRect.maxY + gap),
      candidate(x: railFrame.minX - spacing - barSize.width, y: base.minY),
      candidate(x: railFrame.maxX + spacing, y: base.minY),
      candidate(x: base.minX, y: railFrame.minY - spacing - barSize.height),
    ].compactMap { $0 }
    return candidates.first ?? base
  }
}

/// Placement of the vertical action column beside the screenshot. It prefers
/// the selection's right edge, falls back to the left edge, and only tucks
/// inside the selection (top-right) when a near-fullscreen selection leaves no
/// room outside. It never reflows into the tool deck.
nonisolated enum AreaSelectionRailLayout {
  static let gap: CGFloat = 10
  static let edgeMargin: CGFloat = 8
  static let insideInset: CGFloat = 20

  static func resolve(
    selectionRect: CGRect,
    railSize: CGSize,
    bounds: CGSize
  ) -> CGRect {
    let maxX = max(edgeMargin, bounds.width - railSize.width - edgeMargin)
    let maxY = max(edgeMargin, bounds.height - railSize.height - edgeMargin)
    let spaceRight = bounds.width - edgeMargin - selectionRect.maxX
    let proposedX = spaceRight >= railSize.width + gap
      ? selectionRect.maxX + gap
      : selectionRect.minX - gap - railSize.width
    var x = min(maxX, max(edgeMargin, proposedX))
    var y = min(maxY, max(edgeMargin, selectionRect.maxY - railSize.height))
    let frame = CGRect(x: x, y: y, width: railSize.width, height: railSize.height)
    guard frame.intersects(selectionRect) else { return frame }
    x = min(maxX, max(edgeMargin, selectionRect.maxX - railSize.width - insideInset))
    y = min(maxY, max(edgeMargin, selectionRect.maxY - railSize.height - insideInset))
    return CGRect(x: x, y: y, width: railSize.width, height: railSize.height)
  }
}
