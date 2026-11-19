import AppKit
import SwiftUI

@MainActor
final class ImageViewerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, ObservableObject {
    let id = UUID()
    let folder: URL
    @Published private(set) var browser: ImageViewerBrowserStore
    @Published private(set) var geometry = ImageViewerGeometry()
    @Published private(set) var frame: ImageViewerFrame?
    @Published private(set) var errorKey: String?
    @Published private(set) var indexError = false
    @Published private(set) var loading = true
    @Published private(set) var information: ImageViewerInformation?
    @Published private(set) var informationError: String?
    @Published var showsInformation = false {
        didSet { if !showsInformation { cancelInformation() } }
    }
    @Published var language: AppLanguage {
        didSet { window?.toolbar?.items.forEach(configureToolbarItem) }
    }

    var onClose: ((ImageViewerWindowController) -> Void)?
    var onOpen: (([URL]) -> Void)?
    var onFocusChange: (() -> Void)?
    private weak var session: ImageViewerSession?
    private let animation = ImageViewerAnimationController()
    private var renderJob: UUID?
    private var animationJob: UUID?
    private var informationJob: UUID?
    private var printJob: UUID?
    private var renderRevision = 0
    private var generation = 0
    private var currentFrameIndex = 0
    private var viewport = CGSize(width: 780, height: 540)
    private var backing: CGFloat = 1
    private var renderedPixels = 0
    private(set) var isClosed = false

    var animationTimerCount: Int { animation.hasTimer ? 1 : 0 }
    var zoomPercent: Int? {
        frame.map { Int((geometry.pointScale($0.originalSize, in: viewport, backing: backing) * backing * 100).rounded()) }
    }

    init(url: URL, session: ImageViewerSession, language: AppLanguage) {
        self.session = session
        self.language = language
        folder = url.deletingLastPathComponent()
        browser = ImageViewerBrowserStore(url: url)
        let document = ImageViewerDocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        super.init(window: document)
        document.isReleasedWhenClosed = false
        document.identifier = NSUserInterfaceItemIdentifier("MacPilot.ImageViewer.\(id)")
        document.minSize = CGSize(width: 420, height: 290)
        document.collectionBehavior.insert(.fullScreenPrimary)
        document.delegate = self
        document.viewer = self
        document.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "MacPilot.ImageViewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        document.toolbar = toolbar
        document.contentView = NSHostingView(rootView: ImageViewerWindowContent(controller: self))
        document.center()
    }

    required init?(coder: NSCoder) { nil }

    func t(_ key: String) -> String { AppText.value(key, language: language) }

    func begin(show: Bool) {
        window?.representedURL = browser.url
        window?.title = browser.url.lastPathComponent
        if show { reveal() }
        reload()
        session?.subscribe(to: folder, id: id) { [weak self] result in
            guard let self, !self.isClosed else { return }
            switch result {
            case .success(let index):
                self.browser.install(index)
                self.prefetch()
            case .failure: self.indexError = true
            }
        }
    }

    func reveal() {
        guard !isClosed, let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    func setViewport(_ size: CGSize, backing: CGFloat) {
        guard !isClosed, size.width > 1, size.height > 1,
              viewport != size || self.backing != backing else { return }
        viewport = size
        self.backing = backing
        if let frame { geometry.clamp(original: frame.originalSize, viewport: size, backing: backing) }
        requestMoreDetail()
    }

    func zoom(by scale: CGFloat, anchor: CGPoint = .zero) {
        guard let frame else { return }
        geometry.zoom(by: scale, original: frame.originalSize, viewport: viewport, backing: backing, anchor: anchor)
        requestMoreDetail()
    }

    func pan(by delta: CGPoint) {
        guard let frame else { return }
        geometry.move(delta, original: frame.originalSize, viewport: viewport, backing: backing)
    }

    func perform(_ command: ImageViewerCommand) {
        guard !isClosed else { return }
        switch command {
        case .previous: move(-1)
        case .next: move(1)
        case .zoomOut: zoom(by: 0.8)
        case .zoomIn: zoom(by: 1.25)
        case .fit: geometry.fit(); requestMoreDetail()
        case .actual: geometry.actualSize(); requestMoreDetail()
        case .left: geometry.rotate(-1); requestMoreDetail()
        case .right: geometry.rotate(1); requestMoreDetail()
        case .fullscreen: window?.toggleFullScreen(nil)
        case .info:
            showsInformation.toggle()
            if showsInformation { loadInformation() }
        case .printImage: printCurrent()
        }
    }

    func go(to page: Int) {
        if browser.go(to: page) { reload() }
    }

    private func move(_ delta: Int) {
        guard browser.move(delta) else { return }
        window?.representedURL = browser.url
        window?.title = browser.url.lastPathComponent
        geometry = ImageViewerGeometry()
        reload()
        prefetch(direction: delta)
    }

    func reload() {
        generation += 1
        currentFrameIndex = 0
        renderedPixels = 0
        frame = nil
        errorKey = nil
        loading = true
        cancelAnimation(reset: true)
        showsInformation = false
        session?.cancel(printJob)
        printJob = nil
        render(pixels: desiredPixels())
    }

    private func desiredPixels() -> Int {
        let target: CGFloat
        if let frame {
            let longest = max(frame.originalSize.width, frame.originalSize.height)
            let scale = geometry.pointScale(frame.originalSize, in: viewport, backing: backing)
            target = min(longest * (browser.url.pathExtension.lowercased() == "pdf" ? 8 : 1), longest * scale * backing)
        } else {
            target = max(viewport.width, viewport.height) * backing
        }
        return min(ImageViewerPipeline.maximumDisplayPixels, max(512, Int(ceil(target / 512)) * 512))
    }

    private func requestMoreDetail() {
        guard let frame, frame.frameCount == 1 else { return }
        let target = desiredPixels()
        if target > renderedPixels { render(pixels: target) }
    }

    private func render(pixels: Int) {
        session?.cancel(renderJob)
        renderRevision += 1
        let revision = renderRevision
        renderedPixels = pixels
        let request = ImageViewerRenderRequest(url: browser.url, page: browser.page, pixels: pixels)
        renderJob = session?.render(request) { [weak self] result in
            guard let self, !self.isClosed, self.renderRevision == revision else { return }
            self.renderJob = nil
            self.loading = false
            switch result {
            case .success(let frame):
                self.browser.updatePageCount(frame.pageCount)
                self.frame = frame
                self.geometry.clamp(original: frame.originalSize, viewport: self.viewport, backing: self.backing)
                self.updateAnimationVisibility()
                self.requestMoreDetail()
            case .failure(let error):
                if self.frame == nil { self.errorKey = Self.errorKey(error) }
            }
        }
    }

    private func prefetch(direction: Int = 1) {
        if let neighbor = browser.neighbor(direction) {
            session?.prefetch(neighbor, pixels: desiredPixels())
        }
    }

    private var visibleForAnimation: Bool {
        guard let window, !isClosed else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func updateAnimationVisibility() {
        guard visibleForAnimation else { cancelAnimation(); return }
        guard !animation.hasTimer, animationJob == nil, let frame,
              let next = animation.next(after: currentFrameIndex, description: frame) else { return }
        animation.schedule(after: frame.delay) { [weak self] in self?.decodeAnimationFrame(next) }
    }

    private func decodeAnimationFrame(_ index: Int) {
        guard visibleForAnimation else { return }
        let revision = generation
        let request = ImageViewerRenderRequest(url: browser.url, frame: index, pixels: min(2048, renderedPixels))
        animationJob = session?.render(request) { [weak self] result in
            guard let self, !self.isClosed, self.generation == revision else { return }
            self.animationJob = nil
            guard self.visibleForAnimation, case .success(let next) = result else { return }
            self.frame = next
            self.currentFrameIndex = index
            self.animation.displayed(index)
            self.updateAnimationVisibility()
        }
    }

    private func cancelAnimation(reset: Bool = false) {
        if reset { animation.reset() } else { animation.pause() }
        session?.cancel(animationJob)
        animationJob = nil
    }

    private func loadInformation() {
        let revision = generation
        informationJob = session?.information(ImageViewerRenderRequest(url: browser.url, page: browser.page, pixels: 0)) {
            [weak self] result in
            guard let self, self.showsInformation, !self.isClosed, revision == self.generation else { return }
            self.informationJob = nil
            switch result {
            case .success(let info): self.information = info
            case .failure(let error): self.informationError = Self.errorKey(error)
            }
        }
    }

    private func cancelInformation() {
        session?.cancel(informationJob)
        informationJob = nil
        information = nil
        informationError = nil
    }

    private func printCurrent() {
        guard frame != nil, printJob == nil, window?.attachedSheet == nil else { return }
        let revision = generation
        let rotation = geometry
        let request = ImageViewerRenderRequest(url: browser.url, page: browser.page, frame: currentFrameIndex,
                                               pixels: ImageViewerPipeline.maximumPrintPixels)
        printJob = session?.render(request, forPrint: true) { [weak self] result in
            guard let self, !self.isClosed, self.generation == revision, let window = self.window else { return }
            self.printJob = nil
            switch result {
            case .success(let frame):
                let settings = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
                settings.horizontalPagination = .fit
                settings.verticalPagination = .fit
                let size = settings.imageablePageBounds.size
                let view = ImageViewerPrintView(frame: CGRect(origin: .zero, size: size), image: frame.image, rotation: rotation)
                let operation = NSPrintOperation(view: view, printInfo: settings)
                operation.jobTitle = self.browser.url.lastPathComponent
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = self.t(Self.errorKey(error))
                alert.beginSheetModal(for: window)
            }
        }
    }

    private static func errorKey(_ error: Error) -> String { (error as? ImageViewerReadError)?.textKey ?? "viewerUnreadable" }

    func windowDidMiniaturize(_ notification: Notification) { updateAnimationVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateAnimationVisibility() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateAnimationVisibility() }
    func windowDidBecomeKey(_ notification: Notification) { onFocusChange?() }
    func windowDidResignKey(_ notification: Notification) { onFocusChange?() }
    func windowWillClose(_ notification: Notification) { dispose() }

    func dispose() {
        guard !isClosed else { return }
        isClosed = true
        generation += 1
        renderRevision += 1
        session?.cancel(renderJob)
        session?.cancel(printJob)
        cancelInformation()
        cancelAnimation(reset: true)
        session?.unsubscribe(from: folder, id: id)
        if let window {
            for sheet in window.sheets { window.endSheet(sheet, returnCode: .abort) }
            window.contentView = nil
            window.toolbar = nil
            window.delegate = nil
        }
        frame = nil
        onClose?(self)
        onClose = nil
        onOpen = nil
        onFocusChange = nil
    }

    private func itemIdentifier(_ command: ImageViewerCommand) -> NSToolbarItem.Identifier { .init(command.rawValue) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ImageViewerCommand.toolbar.map(itemIdentifier) + [.flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("previous"), .init("next"), .flexibleSpace, .init("zoomOut"), .init("fit"), .init("zoomIn"),
         .flexibleSpace, .init("left"), .init("right"), .init("info")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard ImageViewerCommand(rawValue: identifier.rawValue) != nil else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        configureToolbarItem(item)
        return item
    }

    private func configureToolbarItem(_ item: NSToolbarItem) {
        guard let command = ImageViewerCommand(rawValue: item.itemIdentifier.rawValue) else { return }
        item.label = t(command.key)
        item.paletteLabel = item.label
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: command.icon, accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(toolbarAction(_:))
    }

    @objc private func toolbarAction(_ sender: NSToolbarItem) {
        if let command = ImageViewerCommand(rawValue: sender.itemIdentifier.rawValue) { perform(command) }
    }
}

private final class ImageViewerPrintView: NSView {
    let image: CGImage
    let rotation: ImageViewerGeometry

    init(frame: CGRect, image: CGImage, rotation: ImageViewerGeometry) {
        self.image = image
        self.rotation = rotation
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let original = CGSize(width: image.width, height: image.height)
        let scale = rotation.fitScale(original, in: bounds.size)
        let size = CGSize(width: original.width * scale, height: original.height * scale)
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: rotation.radians)
        context.draw(image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
    }
}
