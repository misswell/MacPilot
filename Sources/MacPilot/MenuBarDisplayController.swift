import AppKit
import Combine
import MacPilotDisplayControlCore

@MainActor
protocol MenuBarStatusItem: AnyObject {
    var autosaveName: NSStatusItem.AutosaveName! { get set }
    var isVisible: Bool { get set }
    var button: NSStatusBarButton? { get }
}

extension NSStatusItem: MenuBarStatusItem {}

struct MenuBarDisplay: Equatable, Sendable {
    let uuid: String
    let frame: CGRect
}

/// Owns reattachment after WindowServer changes the set of menu-bar replicas.
/// Screen reads and menu construction are injectable; tests never create a
/// status item or change the user's display configuration.
@MainActor
final class MenuBarDisplayController: NSObject, ObservableObject {
    @Published var isInserted = true
    @Published private(set) var targetUUID: String?
    /// Whether the user wants the menu-bar icon at all. Reattachment and
    /// self-healing respect it: a hidden icon must stay hidden across display
    /// topology changes and missed launch notifications.
    @Published private(set) var isEnabled = true
    private let center: NotificationCenter
    private let screens: @MainActor () -> [MenuBarDisplay]
    private let pointer: @MainActor () -> CGPoint
    private let menuFactory: (@MainActor (MenuBarDisplayController) -> NSMenu)?
    private let iconName: @MainActor () -> String
    private let debounce: Duration
    private let insertionDelay: Duration
    private var topology: [MenuBarDisplay]
    private var trackingMenus = Set<ObjectIdentifier>()
    private var needsReinsert = false
    private var reinserting = false
    private var revision = 0
    private var reinsertTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var subscriptions: MenuBarDisplaySubscriptions?
    private var iconSubscriptions = Set<AnyCancellable>()
    private var statusItem: (any MenuBarStatusItem)?
    private let makeStatusItem: @MainActor () -> any MenuBarStatusItem
    private let removeItem: @MainActor (any MenuBarStatusItem) -> Void
    private var lastIconName: String?
    private var openingOwnedMenu = false
    var usesNativeMenu: Bool { menuFactory != nil }

    init(
        notificationCenter: NotificationCenter = .default,
        screens: @escaping @MainActor () -> [MenuBarDisplay] = MenuBarDisplayController.liveScreens,
        pointer: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        debounce: Duration = .milliseconds(300),
        insertionDelay: Duration = .milliseconds(80),
        menuFactory: (@MainActor (MenuBarDisplayController) -> NSMenu)? = nil,
        iconName: @escaping @MainActor () -> String = { "timer" },
        makeStatusItem: @escaping @MainActor () -> any MenuBarStatusItem = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        },
        removeItem: @escaping @MainActor (any MenuBarStatusItem) -> Void = { item in
            if let item = item as? NSStatusItem { NSStatusBar.system.removeStatusItem(item) }
        }
    ) {
        center = notificationCenter
        self.screens = screens
        self.pointer = pointer
        self.debounce = debounce
        self.insertionDelay = insertionDelay
        self.menuFactory = menuFactory
        self.iconName = iconName
        self.makeStatusItem = makeStatusItem
        self.removeItem = removeItem
        topology = screens().sorted { $0.uuid < $1.uuid }
        super.init()
        var tokens: [NSObjectProtocol] = []
        for name in [NSApplication.didChangeScreenParametersNotification,
                     NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
                     NSApplication.didFinishLaunchingNotification] {
            tokens.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                let name = event.name
                let menuID = (event.object as? NSMenu).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.receive(name: name, menuID: menuID) }
            })
        }
        subscriptions = MenuBarDisplaySubscriptions(center: notificationCenter, tokens: tokens)
        if NSApp?.isRunning == true { installStatusItem() }
    }

    func observeIconChanges(_ publisher: AnyPublisher<Void, Never>) {
        publisher.sink { @Sendable [weak self] _ in
            // objectWillChange fires before the new state is stored.
            Task { @MainActor [weak self] in self?.updateIcon() }
        }.store(in: &iconSubscriptions)
    }

    /// Hides or shows the status item on the user's request.
    ///
    /// Disabling cancels any queued reattachment first: otherwise the
    /// reinstall that a topology change had already scheduled would bring the
    /// icon straight back.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        revision += 1
        reinsertTask?.cancel()
        reinsertTask = nil
        needsReinsert = false
        reinserting = false
        isInserted = enabled
        if enabled {
            installStatusItem()
        } else {
            removeStatusItem()
        }
    }

    func stop() {
        revision += 1
        reinsertTask?.cancel()
        reinsertTask = nil
        subscriptions = nil
        iconSubscriptions.removeAll()
        if reinserting { finishInsertion() }
        needsReinsert = false
        targetUUID = nil
    }

    /// Re-asserts the item on a slow tick, for the one failure that leaves no
    /// notification behind: our own reattachment removes the item, waits, then
    /// reinstalls, and a cancelled task can leave `reinserting` set with
    /// nothing scheduled. Nothing else produces that pair, so recovering it
    /// cannot fight a user who hid the icon on purpose.
    func startWatchdog(interval: Duration = .seconds(60)) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self, interval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                self?.selfHeal()
            }
        }
    }

    func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Recovers a reattachment this controller started and never finished.
    ///
    /// Skipped while a menu is open so a reinstall never fights the menu the
    /// user is looking at, and skipped unless both halves of the interrupted
    /// state are present — an item the user hid elsewhere is left alone.
    func selfHeal() {
        guard isEnabled, trackingMenus.isEmpty else { return }
        guard reinserting, statusItem == nil else { return }
        reinserting = false
        isInserted = true
        needsReinsert = false
        installStatusItem()
        DiagnosticLog.write("MenuBar", "Recovered an interrupted status item reattachment", level: .warning)
    }

    private func receive(name: Notification.Name, menuID: ObjectIdentifier?) {
        ensureInstalled()
        switch name {
        case NSApplication.didChangeScreenParametersNotification:
            let next = screens().sorted { $0.uuid < $1.uuid }
            guard next != topology else { return }
            topology = next
            targetUUID = nil
            needsReinsert = true
            scheduleReinsert()
        case NSMenu.didBeginTrackingNotification:
            guard let menuID else { return }
            if trackingMenus.isEmpty, !openingOwnedMenu { captureTarget() }
            trackingMenus.insert(menuID)
        case NSMenu.didEndTrackingNotification:
            guard let menuID else { return }
            trackingMenus.remove(menuID)
            if trackingMenus.isEmpty, needsReinsert { scheduleReinsert() }
        case NSApplication.didFinishLaunchingNotification:
            installStatusItem()
        default: break
        }
    }

    /// Self-heals every path that could leave the icon uninstalled: a launch
    /// notification missed, or a cancelled reattachment that never got to
    /// reinstall. Reattachment itself is guarded by `reinserting`.
    private func ensureInstalled() {
        guard isEnabled, menuFactory != nil, !reinserting, statusItem == nil else { return }
        installStatusItem()
    }

    private func captureTarget() {
        let point = pointer()
        targetUUID = screens().first(where: { $0.frame.contains(point) })?.uuid
    }

    private func scheduleReinsert() {
        revision += 1
        let token = revision
        reinsertTask?.cancel()
        // A cancelled task may have already taken the item out of the menu
        // bar and stopped before reinstalling it. Restoring synchronously —
        // before the new pass sleeps — keeps the icon on screen for the whole
        // window, and clears the guard the abandoned task left behind.
        if reinserting { finishInsertion() }
        guard isEnabled else { return }
        guard trackingMenus.isEmpty else {
            needsReinsert = true
            return
        }
        reinsertTask = Task { @MainActor [weak self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, self.revision == token, self.trackingMenus.isEmpty,
                  !self.screens().isEmpty else { return }
            self.reinserting = true
            self.isInserted = false
            if let item = self.statusItem {
                removeItem(item)
                self.statusItem = nil
            }
            // The item is out of the menu bar from here on. This sleep is
            // cancellable, so every exit — including a cancellation — has to
            // reinstall it. Returning straight out of a cancelled sleep left
            // `reinserting` true with no item and no task left to put one
            // back, which hid the icon until relaunch.
            defer {
                if self.reinserting { self.finishInsertion() }
            }
            do { try await Task.sleep(for: self.insertionDelay) } catch { return }
            guard self.revision == token else { return }
            self.finishInsertion()
            self.needsReinsert = false
            self.reinsertTask = nil
        }
    }

    private func finishInsertion() {
        isInserted = isEnabled
        reinserting = false
        installStatusItem()
    }

    private func installStatusItem() {
        guard isEnabled, menuFactory != nil, statusItem == nil else { return }
        let item = makeStatusItem()
        item.autosaveName = "MacPilotStatusItem"
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(openMenu(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        item.button?.setAccessibilityLabel("MacPilot")
        lastIconName = nil
        updateIcon()
        // AppKit restores visibility when autosaveName is assigned, including
        // a hidden value left by the previous removal. Our enabled setting
        // owns visibility, so a newly installed item must explicitly be shown.
        item.isVisible = true
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        removeItem(item)
        statusItem = nil
        lastIconName = nil
    }

    private func updateIcon() {
        ensureInstalled()
        let name = iconName()
        guard let button = statusItem?.button, lastIconName != name else { return }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "MacPilot")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        lastIconName = name
    }

    func prepareMenuSession() -> MenuBarMenuSession? {
        guard let menuFactory else { return nil }
        captureTarget()
        return MenuBarMenuSession(source: menuFactory(self))
    }

    @objc private func openMenu(_ sender: NSStatusBarButton) {
        guard let session = prepareMenuSession() else { return }
        openingOwnedMenu = true
        sender.highlight(true)
        defer { sender.highlight(false); openingOwnedMenu = false }
        _ = withExtendedLifetime(session) {
            session.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        }
    }

    static func liveScreens() -> [MenuBarDisplay] {
        let displays = MacDisplayTopologyDriver().displays()
        return NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let display = displays.first(where: { $0.displayID == id }) else { return nil }
            return MenuBarDisplay(uuid: display.uuid, frame: screen.frame)
        }
    }
}

private final class MenuBarDisplaySubscriptions: @unchecked Sendable {
    let center: NotificationCenter
    let tokens: [NSObjectProtocol]
    init(center: NotificationCenter, tokens: [NSObjectProtocol]) { self.center = center; self.tokens = tokens }
    deinit { for token in tokens { center.removeObserver(token) } }
}
