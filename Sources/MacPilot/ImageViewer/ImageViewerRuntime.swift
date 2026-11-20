import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class ImageViewerRuntime: ObservableObject {
    @Published private(set) var hasKeyDocument = false
    var language: AppLanguage {
        didSet { windows.all.forEach { $0.language = language } }
    }
    var settings: ImageViewerSettings {
        didSet { windows.all.forEach { $0.settings = settings } }
    }
    private(set) var session: ImageViewerSession?
    private(set) var windows = ImageViewerWindowRegistry()
    private(set) var isClosed = false
    private var pendingFolders: [URL: UUID] = [:]
    private var panel: NSOpenPanel?
    private let presentWindows: Bool
    var onIdle: (() -> Void)?

    var taskCount: Int { (session?.taskCount ?? 0) + windows.all.reduce(0) { $0 + $1.animationTimerCount } }

    init(language: AppLanguage, settings: ImageViewerSettings = ImageViewerSettings(), presentWindows: Bool = true) {
        self.language = language
        self.settings = settings
        self.presentWindows = presentWindows
    }

    func chooseFiles(multiple: Bool = false) { choose(folder: false, multiple: multiple) }
    func chooseFolder() { choose(folder: true, multiple: false) }

    private func choose(folder: Bool, multiple: Bool) {
        guard !isClosed, panel == nil else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = folder
        picker.canChooseFiles = !folder
        picker.allowsMultipleSelection = multiple
        if !folder {
            picker.allowedContentTypes = [.image, .pdf] + ImageViewerFileKind.extensions.sorted().compactMap {
                UTType(filenameExtension: $0)
            }
        }
        picker.prompt = AppText.value("viewerOpen", language: language)
        panel = picker
        NSApp.activate()
        picker.begin { [weak self, weak picker] response in
            guard let self, let picker, !self.isClosed, self.panel === picker else { return }
            self.panel = nil
            guard response == .OK else { return }
            if folder, let url = picker.url { self.openFolder(url) }
            else { self.open(picker.urls) }
        }
    }

    func open(_ urls: [URL]) {
        guard !isClosed else { return }
        for url in ImageViewerFileRouter.documents(in: urls) {
            if let current = windows.window(showing: url) {
                current.reload()
                if presentWindows { current.reveal() }
            } else {
                let document = ImageViewerWindowController(
                    url: url, session: activeSession(), language: language, settings: settings
                )
                document.onClose = { [weak self] closed in
                    self?.windows.remove(closed)
                    self?.releaseIdleSession()
                    self?.updateFocus()
                }
                document.onOpen = { [weak self] urls in self?.open(urls) }
                document.onFocusChange = { [weak self] in self?.updateFocus() }
                windows.insert(document)
                document.begin(show: presentWindows)
            }
        }
    }

    func openFolder(_ url: URL) {
        guard !isClosed, url.isFileURL else { return }
        let folder = url.standardizedFileURL
        guard pendingFolders[folder] == nil else { return }
        let id = UUID()
        pendingFolders[folder] = id
        activeSession().subscribe(to: folder, id: id) { [weak self] result in
            guard let self, !self.isClosed, self.pendingFolders.removeValue(forKey: folder) == id else { return }
            var message: String?
            switch result {
            case .success(let index):
                if let first = index.files.first { self.open([first]) }
                else { message = "viewerEmptyFolder" }
            case .failure: message = "viewerIndexError"
            }
            self.session?.unsubscribe(from: folder, id: id)
            self.releaseIdleSession()
            if let message, self.presentWindows {
                let alert = NSAlert()
                alert.messageText = AppText.value(message, language: self.language)
                if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
                else { alert.runModal() }
            }
        }
    }

    private func activeSession() -> ImageViewerSession {
        if let session { return session }
        let newSession = ImageViewerSession()
        session = newSession
        return newSession
    }

    private func releaseIdleSession() {
        guard windows.isEmpty, pendingFolders.isEmpty else { return }
        session?.close()
        session = nil
        if !isClosed, panel == nil { onIdle?() }
    }

    private func updateFocus() {
        let focused = (NSApp?.keyWindow as? ImageViewerDocumentWindow)?.viewer
        let next = focused.map { !$0.isClosed } ?? false
        if next != hasKeyDocument { hasKeyDocument = next }
    }

    func perform(_ command: ImageViewerCommand) {
        guard !isClosed, let window = NSApp.keyWindow as? ImageViewerDocumentWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        window.viewer?.perform(command)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        panel?.cancel(nil)
        panel = nil
        pendingFolders.removeAll()
        session?.close()
        for document in windows.all {
            let window = document.window
            document.dispose()
            window?.close()
        }
        session = nil
        hasKeyDocument = false
    }
}
