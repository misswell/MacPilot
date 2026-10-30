import AppKit
import Darwin
import SwiftUI

/// Facts about how this process was started, read once at launch.
enum AppLaunchContext {
    /// True when the login item started the app. The parent of a login item is
    /// `loginwindow`; reading this later is unreliable, because the parent can
    /// be reaped and its pid reused.
    static let wasLaunchedAtLogin: Bool = parentProcessName() == "loginwindow"

    private static func parentProcessName() -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getppid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let count = UInt32(mib.count)
        let result = mib.withUnsafeMutableBufferPointer { pointer -> Int32 in
            sysctl(pointer.baseAddress, count, &info, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return withUnsafePointer(to: &info.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
        }
    }
}

/// Which page the main window shows, and whether its content exists at all.
///
/// The subtle part is the close: AppKit announces it while the window is still
/// on screen, so the release is deferred a turn — and if the user reopened the
/// window in the meantime, that close must not win.
struct MainWindowContentState {
    private(set) var isLoaded: Bool
    private(set) var generation = 0

    init(loadedAtLaunch: Bool) {
        isLoaded = loadedAtLaunch
    }

    mutating func load() {
        generation += 1
        isLoaded = true
    }

    /// Identifies the content this close is answering.
    mutating func beginClose() -> Int {
        generation
    }

    /// Releases the content unless something has loaded it since `beginClose`.
    mutating func completeClose(requestedGeneration: Int) {
        guard requestedGeneration == generation else { return }
        isLoaded = false
    }
}

/// Owns the window independently of the lifetime of its SwiftUI content.
///
/// Every request has to end with a visible window. This path failed silently
/// for a long time because a request that arrived before the window existed was
/// parked (`pendingRequest`) with nothing that could ever drain it, and because
/// raising the window from inside the status menu's tracking loop can be undone
/// when the loop ends. So: leave the tracking loop first, always leave a way to
/// create the window, and record what actually happened.
@MainActor
final class MainWindowOpener: NSObject, ObservableObject {
    /// How a request ended. Logged to `DiagnosticLog` so a silent failure has
    /// evidence next time instead of another round of guessing.
    enum Outcome: String {
        case raisedExistingWindow
        /// No usable window: the request now waits for the scene to build one.
        case queuedForWindowCreation
        case noWindowAndNoCreator
    }

    private let loadContent: () -> Void
    private let activate: () -> Void
    private let schedule: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let record: @MainActor (Outcome) -> Void
    private let isWindowUsable: @MainActor (NSWindow) -> Bool
    private var window: NSWindow?
    private var raise: (() -> Void)?
    /// SwiftUI's `openWindow(id:)` for the main scene, kept for the process
    /// lifetime: a closed window must not take the only way back with it.
    private var createWindow: (() -> Void)?
    private var pendingRequest = false
    /// Newest request, and the one a reveal has already answered. A request
    /// that arrives while the window is still being built must not be answered
    /// twice — once by the attachment drain and once by its own turn.
    private var latestRequest = 0
    private var answeredRequest = 0
    private(set) var lastOutcome: Outcome?

    init(
        center: NotificationCenter = .default,
        loadContent: @escaping () -> Void,
        activate: @escaping () -> Void,
        // The menu is still tracking when this runs; the next turn is the
        // first moment ordering the window front cannot be undone by the
        // menu closing again.
        schedule: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.async(execute: work)
        },
        record: @escaping @MainActor (Outcome) -> Void = { outcome in
            DiagnosticLog.write("MainWindow", "open request outcome=\(outcome.rawValue)", level: .info)
        },
        // A window that survived in name only (ordered out and dropped by the
        // scene) must not be treated as somewhere to show content.
        isWindowUsable: @escaping @MainActor (NSWindow) -> Bool = { $0.isVisible }
    ) {
        self.loadContent = loadContent
        self.activate = activate
        self.schedule = schedule
        self.record = record
        self.isWindowUsable = isWindowUsable
        super.init()
        center.addObserver(self, selector: #selector(requestOpen), name: .macPilotShowMainWindow, object: nil)
    }

    @objc func requestOpen() {
        // Load first, while the menu is still closing: the window then appears
        // with its content instead of flashing empty.
        loadContent()
        // Outstanding until a window is actually on screen; an attachment that
        // arrives meanwhile drains it.
        pendingRequest = true
        latestRequest &+= 1
        let token = latestRequest
        schedule { [weak self] in
            guard let self, self.latestRequest == token else { return }
            self.reveal(answer: token)
        }
    }

    /// Ends the request with a window on screen: raise the one we own, or have
    /// the scene build a new one.
    private func reveal(answer token: Int) {
        guard answeredRequest != token else { return }
        answeredRequest = token
        revealNow()
    }

    private func revealNow() {
        if let raise {
            raise()
            window?.orderFrontRegardless()
            // Activation is cooperative on modern macOS. Forcing the window
            // front regardless means a refused activation still shows the
            // window instead of looking like a dead menu item.
            activate()
            if window.map(isWindowUsable) ?? true {
                pendingRequest = false
                finish(.raisedExistingWindow)
                return
            }
            // The scene dropped this window; the only way back is a new one.
            window = nil
            self.raise = nil
        }
        guard let createWindow else {
            // Keep the request outstanding: a window that attaches later still
            // has to answer it.
            finish(.noWindowAndNoCreator)
            return
        }
        finish(.queuedForWindowCreation)
        createWindow()
    }

    private func finish(_ outcome: Outcome) {
        lastOutcome = outcome
        record(outcome)
    }

    func attach(window: NSWindow) {
        // SwiftUI can discard the content on close, but the resident app must
        // keep the same window available for the next menu or Dock request.
        window.isReleasedWhenClosed = false
        self.window = window
        attach { [weak window] in window?.makeKeyAndOrderFront(nil) }
    }

    /// Provides the scene's `openWindow(id:)` so a request can rebuild a window
    /// the scene dropped.
    func install(createWindow: @escaping () -> Void) {
        self.createWindow = createWindow
    }

    // Also provides a window-free seam for lifecycle tests.
    func attach(show: @escaping () -> Void) {
        raise = show
        guard pendingRequest else { return }
        pendingRequest = false
        // This answers the queued request: the turn it scheduled must not
        // reveal a second time.
        answeredRequest = latestRequest
        revealNow()
    }
}

private struct MainWindowAttachment: NSViewRepresentable {
    let opener: MainWindowOpener

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.opener = opener
        return view
    }

    func updateNSView(_ view: WindowAttachmentView, context: Context) {
        view.opener = opener
        if let window = view.window { opener.attach(window: window) }
    }

    final class WindowAttachmentView: NSView {
        weak var opener: MainWindowOpener?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { opener?.attach(window: window) }
        }
    }
}

/// The main window's content, built only while the window is actually in use.
///
/// A hidden window is not free. `orderOut` keeps the whole view graph, its
/// layout cache and every symbol it rendered alive for the rest of the session,
/// which is most of the memory of an app that spends its life in the menu bar.
/// The scene keeps the window itself — menus, keyboard shortcuts and frame
/// restoration belong to it — while `ContentView` comes and goes with it.
struct MainWindowRoot: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.openWindow) private var openWindow
    let opener: MainWindowOpener

    init(opener: MainWindowOpener) {
        self.opener = opener
    }

    var body: some View {
        Group {
            if model.mainContent.isLoaded {
                ContentView()
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(MainWindowAttachment(opener: opener))
        // The opener outlives this view, so the scene's only way to rebuild a
        // window it dropped has to outlive it too.
        .onAppear {
            let openWindow = openWindow
            opener.install(createWindow: { openWindow(id: "main") })
        }
    }
}
