import AppKit
import Combine
import MacPilotDisplayControlCore

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
    private var subscriptions: MenuBarDisplaySubscriptions?
    private var iconSubscriptions = Set<AnyCancellable>()
    private var statusItem: NSStatusItem?
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
        iconName: @escaping @MainActor () -> String = { "timer" }
    ) {
        center = notificationCenter
        self.screens = screens
        self.pointer = pointer
        self.debounce = debounce
        self.insertionDelay = insertionDelay
        self.menuFactory = menuFactory
        self.iconName = iconName
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
        guard menuFactory != nil, !reinserting, statusItem == nil else { return }
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
        guard trackingMenus.isEmpty else {
            // The cancelled task may already sit between removal and
            // reinstall. Tracking ending would re-run the dance, but leaving
            // the item removed until then hides the menu-bar icon for as
            // long as any menu stays open — restore it immediately.
            needsReinsert = true
            if reinserting { finishInsertion() }
            return
        }
        reinsertTask = Task { @MainActor [weak self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, self.revision == token, self.trackingMenus.isEmpty,
                  !self.screens().isEmpty else { return }
            self.reinserting = true
            self.isInserted = false
            if let item = self.statusItem {
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            }
            do { try await Task.sleep(for: self.insertionDelay) } catch { return }
            guard self.revision == token else { return }
            self.finishInsertion()
            self.needsReinsert = false
            self.reinsertTask = nil
        }
    }

    private func finishInsertion() {
        isInserted = true
        reinserting = false
        installStatusItem()
    }

    private func installStatusItem() {
        guard menuFactory != nil, statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "MacPilotStatusItem"
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(openMenu(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        item.button?.setAccessibilityLabel("MacPilot")
        lastIconName = nil
        updateIcon()
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

    @objc private func openMenu(_ sender: NSStatusBarButton) {
        guard let menuFactory else { return }
        captureTarget()
        let menu = menuFactory(self)
        openingOwnedMenu = true
        sender.highlight(true)
        defer { sender.highlight(false); openingOwnedMenu = false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
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
