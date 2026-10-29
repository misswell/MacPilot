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
@MainActor
final class MainWindowOpener: NSObject, ObservableObject {
    private let loadContent: () -> Void
    private let activate: () -> Void
    private var showWindow: (() -> Void)?
    private var pendingRequest = false

    init(center: NotificationCenter = .default, loadContent: @escaping () -> Void, activate: @escaping () -> Void) {
        self.loadContent = loadContent
        self.activate = activate
        super.init()
        center.addObserver(self, selector: #selector(requestOpen), name: .macPilotShowMainWindow, object: nil)
    }

    @objc func requestOpen() {
        guard let showWindow else {
            pendingRequest = true
            return
        }
        loadContent()
        showWindow()
        activate()
    }

    func attach(window: NSWindow) {
        // SwiftUI can discard the content on close, but the resident app must
        // keep the same window available for the next menu or Dock request.
        window.isReleasedWhenClosed = false
        attach { [window] in window.makeKeyAndOrderFront(nil) }
    }

    // Also provides a window-free seam for lifecycle tests.
    func attach(show: @escaping () -> Void) {
        showWindow = show
        guard pendingRequest else { return }
        pendingRequest = false
        requestOpen()
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
    }
}
