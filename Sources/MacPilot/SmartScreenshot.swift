import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Vision

struct SmartCaptureElement: Equatable, Sendable {
    let role: String
    let frame: CGRect
}

enum SmartCaptureTargetResolver {
    private static let acceptedRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea",
        "AXPopUpButton", "AXMenuItem", "AXImage", "AXCell", "AXStaticText", "AXGroup",
        "AXScrollArea", "AXSheet", "AXWebArea", "AXMenu", "AXMenuBar", "AXSplitGroup",
        "AXTable", "AXOutline", "AXRow", "AXColumn", "AXToolbar", "AXHeading", "AXParagraph",
        "AXList", "AXForm", "AXGrid", "AXDocument", "AXLandmark", "AXRegion", "AXBlockQuote",
        "AXComboBox", "AXSlider", "AXDisclosureTriangle", "AXTabGroup"
    ]

    static func resolve(elementChain: [SmartCaptureElement], windowFrame: CGRect?) -> CGRect? {
        for element in elementChain where acceptedRoles.contains(element.role) {
            guard element.frame.width >= 12, element.frame.height >= 12 else { continue }
            if let windowFrame, windowFrame.width > 0, windowFrame.height > 0 {
                let ratio = element.frame.width * element.frame.height
                    / (windowFrame.width * windowFrame.height)
                guard ratio <= 0.95 else { continue }
            }
            return element.frame.integral
        }
        return windowFrame?.integral
    }
}

struct SmartCaptureShortcutBinding: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: InputSourceShortcutModifiers

    static let `default` = Self(keyCode: UInt16(kVK_F1), modifiers: [])

    init(keyCode: UInt16 = UInt16(kVK_F1), modifiers: InputSourceShortcutModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var displayName: String {
        modifiers.symbolDescription + MacPilotKeyCode.displayName(for: keyCode)
    }

    func matches(keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        guard self.keyCode == keyCode, !isRepeat else { return false }
        return InputSourceShortcutModifiers(flags) == modifiers
    }
}

enum SmartCaptureSelectionGeometry {
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).integral
    }

    static func isMeaningful(_ rect: CGRect, minimumSize: CGFloat = 4) -> Bool {
        rect.width >= minimumSize && rect.height >= minimumSize
    }
}

enum SmartCaptureShortcut {
    static func matches(
        keyCode: UInt16,
        flags: CGEventFlags,
        isRepeat: Bool,
        binding: SmartCaptureShortcutBinding = .default
    ) -> Bool {
        binding.matches(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
    }
}

private final class SmartShortcutContext: @unchecked Sendable {
    weak var controller: SmartScreenshotController?
    private let lock = NSLock()
    private var selecting = false
    private var binding: SmartCaptureShortcutBinding

    init(controller: SmartScreenshotController, binding: SmartCaptureShortcutBinding) {
        self.controller = controller
        self.binding = binding
    }

    func setSelecting(_ value: Bool) {
        lock.lock()
        selecting = value
        lock.unlock()
    }

    func shouldConsumeEscape(keyCode: UInt16) -> Bool {
        lock.lock()
        let value = selecting && keyCode == UInt16(kVK_Escape)
        lock.unlock()
        return value
    }

    func update(binding: SmartCaptureShortcutBinding) {
        lock.lock()
        self.binding = binding
        lock.unlock()
    }

    func currentBinding() -> SmartCaptureShortcutBinding {
        lock.lock()
        let binding = self.binding
        lock.unlock()
        return binding
    }
}

private func smartShortcutEventCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<SmartShortcutContext>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in context.controller?.reenableShortcutTap() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if context.shouldConsumeEscape(keyCode: keyCode) {
        Task { @MainActor in context.controller?.cancelSelection() }
        return nil
    }
    guard context.currentBinding().matches(keyCode: keyCode, flags: event.flags, isRepeat: isRepeat) else {
        return Unmanaged.passUnretained(event)
    }
    Task { @MainActor in context.controller?.startSelection() }
    return nil
}

private func smartSelectionEventCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<SmartShortcutContext>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in context.controller?.reenableSelectionTap() }
        return Unmanaged.passUnretained(event)
    }
    let location = event.location
    Task { @MainActor in
        switch type {
        case .mouseMoved:
            context.controller?.selectionPointerMoved(toQuartzPoint: location)
        case .leftMouseDown:
            context.controller?.selectionMouseDown(atQuartzPoint: location)
        case .leftMouseDragged:
            context.controller?.selectionMouseDragged(toQuartzPoint: location)
        case .leftMouseUp:
            context.controller?.selectionMouseUp(atQuartzPoint: location)
        case .rightMouseDown:
            context.controller?.cancelSelection()
        case .rightMouseDragged:
            context.controller?.selectionPointerMoved(toQuartzPoint: location)
        default:
            break
        }
    }
    switch type {
    case .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged:
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}

@MainActor
final class SmartScreenshotController {
    nonisolated private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "SmartCapture")
    private let language: () -> AppLanguage
    private let onCapture: (CGImage) -> Void
    private let onError: (Error) -> Void
    private var shortcutTap: CFMachPort?
    private var shortcutSource: CFRunLoopSource?
    private var shortcutContext: SmartShortcutContext?
    private var fallbackKeyMonitor: Any?
    private var selectionTap: CFMachPort?
    private var selectionSource: CFRunLoopSource?
    private var overlays: [SmartCaptureOverlayPanel] = []
    private var currentTarget: CGRect?
    private var manualSelectionStart: CGPoint?
    private var manualSelectionRect: CGRect?
    private var pinControllers: [UUID: SmartPinWindowController] = [:]
    private var quickAccessControllers: [UUID: SmartQuickAccessWindowController] = [:]
    private var isSelecting = false
    private var pendingTargetUpdate: DispatchWorkItem?
    private var latestPointerLocation: CGPoint?
    private var shortcutBinding: SmartCaptureShortcutBinding

    init(
        language: @escaping () -> AppLanguage,
        onCapture: @escaping (CGImage) -> Void,
        onError: @escaping (Error) -> Void,
        shortcutBinding: SmartCaptureShortcutBinding = .default
    ) {
        self.language = language
        self.onCapture = onCapture
        self.onError = onError
        self.shortcutBinding = shortcutBinding
    }

    func start() {
        guard shortcutTap == nil, fallbackKeyMonitor == nil else { return }
        let context = SmartShortcutContext(controller: self, binding: shortcutBinding)
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: smartShortcutEventCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            Self.logger.error("Global F1 event tap could not be created; installing NSEvent fallback")
            fallbackKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard context.currentBinding().matches(
                    keyCode: event.keyCode,
                    flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
                    isRepeat: event.isARepeat
                ) else { return }
                Task { @MainActor in self?.startSelection() }
            }
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        shortcutContext = context
        shortcutTap = tap
        shortcutSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.logger.info("Global F1 event tap enabled")
    }

    func updateShortcutBinding(_ binding: SmartCaptureShortcutBinding) {
        shortcutBinding = binding
        shortcutContext?.update(binding: binding)
    }

    func stop() {
        cancelSelection()
        pendingTargetUpdate?.cancel()
        pendingTargetUpdate = nil
        latestPointerLocation = nil
        manualSelectionStart = nil
        manualSelectionRect = nil
        if let shortcutSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), shortcutSource, .commonModes) }
        if let shortcutTap { CFMachPortInvalidate(shortcutTap) }
        shortcutSource = nil
        shortcutTap = nil
        shortcutContext = nil
        if let fallbackKeyMonitor { NSEvent.removeMonitor(fallbackKeyMonitor) }
        fallbackKeyMonitor = nil
        let controllers = Array(pinControllers.values)
        pinControllers.removeAll(keepingCapacity: false)
        for controller in controllers { controller.close() }
        let quickAccessControllers = Array(self.quickAccessControllers.values)
        self.quickAccessControllers.removeAll(keepingCapacity: false)
        for controller in quickAccessControllers { controller.close() }
    }

    func reenableShortcutTap() {
        if let shortcutTap { CGEvent.tapEnable(tap: shortcutTap, enable: true) }
    }

    func startSelection() {
        guard !isSelecting else { return }
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
            Self.logger.error("Selection rejected because required permissions are unavailable")
            return
        }
        isSelecting = true
        shortcutContext?.setSelecting(true)
        let initialPoint = NSEvent.mouseLocation
        currentTarget = SmartAXTargetQuery.target(at: initialPoint)
        Self.logger.info("Selection started; initial target available: \(self.currentTarget != nil)")
        overlays = NSScreen.screens.map { screen in
            let panel = SmartCaptureOverlayPanel(screen: screen)
            panel.overlayView.targetFrame = currentTarget
            panel.overlayView.onMove = { [weak self] point in self?.updateTarget(at: point) }
            panel.overlayView.onMouseDown = { [weak self] point in self?.beginManualSelection(at: point) }
            panel.overlayView.onMouseDragged = { [weak self] point in self?.updateManualSelection(to: point) }
            panel.overlayView.onMouseUp = { [weak self] point in self?.finishManualSelection(at: point) }
            panel.overlayView.onCancel = { [weak self] in self?.cancelSelection() }
            panel.orderFrontRegardless()
            return panel
        }
        installSelectionTap()
        NSCursor.crosshair.set()
    }

    func cancelSelection() {
        guard isSelecting || !overlays.isEmpty else { return }
        isSelecting = false
        pendingTargetUpdate?.cancel()
        pendingTargetUpdate = nil
        latestPointerLocation = nil
        manualSelectionStart = nil
        manualSelectionRect = nil
        shortcutContext?.setSelecting(false)
        removeSelectionTap()
        currentTarget = nil
        let current = overlays
        overlays.removeAll(keepingCapacity: false)
        for panel in current {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        NSCursor.arrow.set()
    }

    func pin(image: CGImage) {
        let id = UUID()
        let controller = SmartPinWindowController(image: image, language: language()) { [weak self] in
            Self.logger.info("Pin controller removed")
            self?.pinControllers.removeValue(forKey: id)
        }
        pinControllers[id] = controller
        controller.show()
    }

    func showQuickAccess(image: CGImage) {
        // Keep only the latest result preview alive. This bounds retained image
        // memory when the user captures repeatedly without opening the actions.
        let previous = Array(quickAccessControllers.values)
        quickAccessControllers.removeAll(keepingCapacity: false)
        for controller in previous { controller.close() }
        let id = UUID()
        let controller = SmartQuickAccessWindowController(
            image: image,
            language: language(),
            onPin: { [weak self] image in self?.pin(image: image) },
            onClose: { [weak self] in
                self?.quickAccessControllers.removeValue(forKey: id)
            }
        )
        quickAccessControllers[id] = controller
        controller.show()
    }

    func reenableSelectionTap() {
        if let selectionTap { CGEvent.tapEnable(tap: selectionTap, enable: true) }
    }

    func selectionPointerMoved(toQuartzPoint point: CGPoint) {
        guard let appKitPoint = SmartAXTargetQuery.appKitPoint(fromQuartzPoint: point) else { return }
        updateTarget(at: appKitPoint)
    }

    func selectionMouseDown(atQuartzPoint point: CGPoint) {
        guard let appKitPoint = SmartAXTargetQuery.appKitPoint(fromQuartzPoint: point) else { return }
        beginManualSelection(at: appKitPoint)
    }

    func selectionMouseDragged(toQuartzPoint point: CGPoint) {
        guard let appKitPoint = SmartAXTargetQuery.appKitPoint(fromQuartzPoint: point) else { return }
        updateManualSelection(to: appKitPoint)
    }

    func selectionMouseUp(atQuartzPoint point: CGPoint) {
        guard let appKitPoint = SmartAXTargetQuery.appKitPoint(fromQuartzPoint: point) else { return }
        finishManualSelection(at: appKitPoint)
    }

    private func installSelectionTap() {
        removeSelectionTap()
        guard let context = shortcutContext else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: smartSelectionEventCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            Self.logger.error("Selection mouse event tap could not be created")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        selectionTap = tap
        selectionSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeSelectionTap() {
        if let selectionSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), selectionSource, .commonModes) }
        if let selectionTap { CFMachPortInvalidate(selectionTap) }
        selectionSource = nil
        selectionTap = nil
    }

    private func updateTarget(at appKitPoint: CGPoint) {
        guard isSelecting, manualSelectionStart == nil else { return }
        latestPointerLocation = appKitPoint
        guard pendingTargetUpdate == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isSelecting, let point = self.latestPointerLocation else { return }
            self.pendingTargetUpdate = nil
            self.resolveTarget(at: point)
        }
        pendingTargetUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    private func resolveTarget(at appKitPoint: CGPoint) {
        let target = SmartAXTargetQuery.target(at: appKitPoint)
        guard target != currentTarget else { return }
        currentTarget = target
        for overlay in overlays { overlay.overlayView.targetFrame = target }
    }

    private func beginManualSelection(at point: CGPoint) {
        guard isSelecting else { return }
        manualSelectionStart = point
        manualSelectionRect = CGRect(origin: point, size: .zero)
        currentTarget = nil
        updateOverlaySelection()
    }

    private func updateManualSelection(to point: CGPoint) {
        guard let start = manualSelectionStart, isSelecting else { return }
        manualSelectionRect = SmartCaptureSelectionGeometry.rect(from: start, to: point)
        updateOverlaySelection()
    }

    private func finishManualSelection(at point: CGPoint) {
        guard manualSelectionStart != nil else { return }
        updateManualSelection(to: point)
        let rect = manualSelectionRect ?? .zero
        let start = manualSelectionStart ?? point
        manualSelectionStart = nil
        manualSelectionRect = nil
        if SmartCaptureSelectionGeometry.isMeaningful(rect) {
            guard let quartzPoint = SmartAXTargetQuery.quartzPoint(fromAppKitPoint: CGPoint(x: rect.midX, y: rect.midY)) else {
                cancelSelection()
                return
            }
            finishCapture(rect: rect, quartzClickPoint: quartzPoint)
        } else {
            commit(at: start)
        }
    }

    private func updateOverlaySelection() {
        for overlay in overlays {
            overlay.overlayView.selectionRect = manualSelectionRect
            overlay.overlayView.targetFrame = manualSelectionRect == nil ? currentTarget : nil
        }
    }

    private func commit(at point: CGPoint) {
        let target = currentTarget.flatMap { $0.contains(point) ? $0 : nil }
            ?? SmartAXTargetQuery.target(at: point)
        guard let target else {
            Self.logger.error("Selection click had no capture target")
            return
        }
        guard let quartzPoint = SmartAXTargetQuery.quartzPoint(fromAppKitPoint: point) else {
            Self.logger.error("Selection click could not be converted to display coordinates")
            cancelSelection()
            return
        }
        Self.logger.info("Committing smart capture target \(String(describing: target), privacy: .public)")
        finishCapture(rect: target, quartzClickPoint: quartzPoint)
    }

    private func finishCapture(rect: CGRect, quartzClickPoint: CGPoint) {
        guard !rect.isEmpty else {
            cancelSelection()
            return
        }
        cancelSelection()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            do {
                let image = try await SmartScreenImageCapture.capture(
                    appKitRect: rect,
                    quartzClickPoint: quartzClickPoint
                )
                self?.onCapture(image)
            } catch {
                self?.onError(error)
            }
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

private enum SmartAXTargetQuery {
    private static let maximumDepth = 25

    static func target(at appKitPoint: CGPoint) -> CGRect? {
        guard let quartzPoint = quartzPoint(fromAppKitPoint: appKitPoint) else { return windowFrame(at: appKitPoint) }
        let system = AXUIElementCreateSystemWide()
        var rawElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(quartzPoint.x), Float(quartzPoint.y), &rawElement) == .success,
              let rawElement else { return windowFrame(at: appKitPoint) }
        let window = windowFrame(at: appKitPoint)
        var chain: [SmartCaptureElement] = []
        var current: AXUIElement? = rawElement
        var depth = 0
        while let element = current, depth < maximumDepth {
            if let candidate = snapshot(element) { chain.append(candidate) }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(parentValue, to: AXUIElement.self)
            depth += 1
        }
        return SmartCaptureTargetResolver.resolve(elementChain: chain, windowFrame: window)
    }

    private static func snapshot(_ element: AXUIElement) -> SmartCaptureElement? {
        var roleValue: CFTypeRef?
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let role = roleValue as? String,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size),
              let frame = appKitRect(fromQuartzRect: CGRect(origin: origin, size: size)) else { return nil }
        return SmartCaptureElement(role: role, frame: frame)
    }

    private static func windowFrame(at point: CGPoint) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID != getpid(),
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  let frame = appKitRect(fromQuartzRect: bounds), frame.contains(point),
                  frame.width >= 40, frame.height >= 40 else { continue }
            return frame.integral
        }
        return nil
    }

    static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint? {
        guard let mapping = DisplayMapping.best(forAppKitPoint: point) else { return nil }
        return CGPoint(
            x: mapping.quartzFrame.minX + point.x - mapping.appKitFrame.minX,
            y: mapping.quartzFrame.maxY - (point.y - mapping.appKitFrame.minY)
        )
    }

    static func appKitPoint(fromQuartzPoint point: CGPoint) -> CGPoint? {
        guard let mapping = DisplayMapping.best(forQuartzPoint: point) else { return nil }
        return CGPoint(
            x: mapping.appKitFrame.minX + point.x - mapping.quartzFrame.minX,
            y: mapping.appKitFrame.maxY - (point.y - mapping.quartzFrame.minY)
        )
    }

    static func quartzRect(fromAppKitRect rect: CGRect) -> CGRect? {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        let converted = points.compactMap { point -> CGPoint? in
            guard let mapping = DisplayMapping.best(forAppKitPoint: point) else { return nil }
            return CGPoint(
                x: mapping.quartzFrame.minX + point.x - mapping.appKitFrame.minX,
                y: mapping.quartzFrame.maxY - (point.y - mapping.appKitFrame.minY)
            )
        }
        guard converted.count == points.count else { return nil }
        return boundingRect(of: converted)
    }

    static func displayCount(intersectingAppKitRect rect: CGRect) -> Int {
        NSScreen.screens.reduce(into: 0) { count, screen in
            let intersection = screen.frame.intersection(rect)
            if intersection.width > 0, intersection.height > 0 { count += 1 }
        }
    }

    private static func appKitRect(fromQuartzRect rect: CGRect) -> CGRect? {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        let converted = points.compactMap { point -> CGPoint? in
            guard let mapping = DisplayMapping.best(forQuartzPoint: point) else { return nil }
            return CGPoint(
                x: mapping.appKitFrame.minX + point.x - mapping.quartzFrame.minX,
                y: mapping.appKitFrame.maxY - (point.y - mapping.quartzFrame.minY)
            )
        }
        guard converted.count == points.count else { return nil }
        return boundingRect(of: converted)
    }

    private static func boundingRect(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }

    private struct DisplayMapping {
        let quartzFrame: CGRect
        let appKitFrame: CGRect

        static func all() -> [Self] {
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return Self(
                    quartzFrame: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)),
                    appKitFrame: screen.frame
                )
            }
        }

        static func best(forAppKitPoint point: CGPoint) -> Self? {
            all().min { distance(point, to: $0.appKitFrame) < distance(point, to: $1.appKitFrame) }
        }

        static func best(forQuartzPoint point: CGPoint) -> Self? {
            all().min { distance(point, to: $0.quartzFrame) < distance(point, to: $1.quartzFrame) }
        }

        private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class SmartCaptureOverlayPanel: NSPanel {
    let overlayView: SmartCaptureOverlayView

    init(screen: NSScreen) {
        overlayView = SmartCaptureOverlayView(screenFrame: screen.frame)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        contentView = overlayView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

private final class SmartCaptureOverlayView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    var targetFrame: CGRect? { didSet { needsDisplay = true } }
    var selectionRect: CGRect? { didSet { needsDisplay = true } }
    private let screenFrame: CGRect
    private var trackingAreaReference: NSTrackingArea?

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseMoved(with event: NSEvent) { onMove?(globalPoint(event)) }
    override func mouseDown(with event: NSEvent) { onMouseDown?(globalPoint(event)) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(globalPoint(event)) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(globalPoint(event)) }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if let selectionRect, !selectionRect.isEmpty {
            let local = selectionRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            NSGraphicsContext.current?.saveGraphicsState()
            NSColor.clear.setFill()
            local.fill(using: .copy)
            NSGraphicsContext.current?.restoreGraphicsState()
            let path = NSBezierPath(rect: local.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            NSColor.white.setStroke()
            path.stroke()
            let label = "\(Int(selectionRect.width)) × \(Int(selectionRect.height))"
            label.draw(
                at: CGPoint(x: local.minX + 8, y: max(8, local.minY - 24)),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.65)
                ]
            )
            return
        }
        guard let targetFrame else { return }
        let local = targetFrame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        NSGraphicsContext.current?.saveGraphicsState()
        NSColor.clear.setFill()
        local.fill(using: .copy)
        NSGraphicsContext.current?.restoreGraphicsState()
        let path = NSBezierPath(roundedRect: local.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
        path.lineWidth = 3
        NSColor.systemBlue.setStroke()
        path.stroke()
        let label = "\(Int(targetFrame.width)) × \(Int(targetFrame.height))"
        label.draw(
            at: CGPoint(x: local.minX + 8, y: max(8, local.minY - 24)),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.65)
            ]
        )
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: screenFrame.minX + local.x, y: screenFrame.minY + local.y)
    }
}

@MainActor
private enum SmartScreenImageCapture {
    nonisolated private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "SmartCapture")

    static func capture(appKitRect: CGRect, quartzClickPoint: CGPoint) async throws -> CGImage {
        guard let quartzRect = SmartAXTargetQuery.quartzRect(fromAppKitRect: appKitRect) else {
            throw ScreenCaptureError.noDisplayFound
        }
        if #unavailable(macOS 15.2), SmartAXTargetQuery.displayCount(intersectingAppKitRect: appKitRect) > 1 {
            throw ScreenCaptureError.captureFailed(
                "The selected region spans multiple displays. Multi-display region capture requires macOS 15.2 or later."
            )
        }
        if #available(macOS 15.2, *) {
            do {
                return try await captureDisplayAgnosticRect(quartzRect)
            } catch {
                Self.logger.error("Display-agnostic region capture failed; trying display enumeration: \(error.localizedDescription, privacy: .public)")
            }
        }

        var displays: [SCDisplay] = []
        for delay in [0, 80, 160, 320] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            let content = try await SCShareableContent.current
            displays = content.displays
            if !displays.isEmpty { break }
        }
        Self.logger.info("ScreenCaptureKit returned \(displays.count) displays")
        let display = displays.first(where: { $0.frame.contains(quartzClickPoint) })
            ?? displays.max { lhs, rhs in
                lhs.frame.intersection(quartzRect).area < rhs.frame.intersection(quartzRect).area
            }
        guard let display else {
            throw ScreenCaptureError.noDisplayFound
        }
        let configuration = SCStreamConfiguration()
        let clippedRect = quartzRect.intersection(display.frame)
        let sourceRect = clippedRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        guard !sourceRect.isEmpty else { throw ScreenCaptureError.captureFailed("The selected region is outside the display.") }
        let scaleX = CGFloat(display.width) / max(1, display.frame.width)
        let scaleY = CGFloat(display.height) / max(1, display.frame.height)
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(sourceRect.width * scaleX))
        configuration.height = max(1, Int(sourceRect.height * scaleY))
        configuration.scalesToFit = true
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
    }

    @available(macOS 15.2, *)
    private static func captureDisplayAgnosticRect(_ rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: ScreenCaptureError.captureFailed(
                        error?.localizedDescription ?? "ScreenCaptureKit returned no image."
                    ))
                }
            }
        }
    }
}

@MainActor
private final class SmartQuickAccessWindowController: NSObject, NSWindowDelegate {
    private var image: CGImage
    private let language: AppLanguage
    private let onPin: (CGImage) -> Void
    private let onClose: () -> Void
    private var panel: NSPanel?
    private var annotationController: SmartAnnotationWindowController?

    init(
        image: CGImage,
        language: AppLanguage,
        onPin: @escaping (CGImage) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.image = image
        self.language = language
        self.onPin = onPin
        self.onClose = onClose
    }

    func show() {
        let maxSize = CGSize(width: 420, height: 320)
        let scale = min(1, maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height))
        let size = CGSize(
            width: max(260, CGFloat(image.width) * scale),
            height: max(190, CGFloat(image.height) * scale + 48)
        )
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppText.value("scQuickAccessTitle", language: language)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        installContent(in: panel)
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        annotationController?.close()
        annotationController = nil
        panel?.contentView = nil
        panel = nil
        onClose()
    }

    private func installContent(in panel: NSPanel) {
        panel.contentView = NSHostingView(rootView: SmartQuickAccessView(
            image: image,
            language: language,
            onCopy: { [weak self] in self?.copyImage() },
            onAnnotate: { [weak self] in self?.openAnnotation() },
            onPin: { [weak self] in self?.pinImage() },
            onClose: { [weak self] in self?.close() }
        ))
    }

    private func copyImage() {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }

    private func pinImage() {
        let image = image
        close()
        onPin(image)
    }

    private func openAnnotation() {
        annotationController?.close()
        panel?.orderOut(nil)
        let controller = SmartAnnotationWindowController(
            image: image,
            language: language,
            onComplete: { [weak self] annotated in
                guard let self else { return }
                self.image = annotated
                if let panel = self.panel { self.installContent(in: panel) }
            },
            onClose: { [weak self] in
                self?.panel?.orderFrontRegardless()
                self?.annotationController = nil
            }
        )
        annotationController = controller
        controller.show()
    }
}

private struct SmartQuickAccessView: View {
    let image: CGImage
    let language: AppLanguage
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onCopy) { Label(AppText.value("scCopy", language: language), systemImage: "doc.on.doc") }
                Button(action: onAnnotate) { Label(AppText.value("scAnnotate", language: language), systemImage: "pencil.tip.crop.circle") }
                Button(action: onPin) { Label(AppText.value("scPin", language: language), systemImage: "pin") }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(AppText.value("scClose", language: language))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(.ultraThinMaterial)

            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .background(Color.black.opacity(0.04))
        }
    }
}

@MainActor
private final class SmartPinWindowController: NSObject, NSWindowDelegate {
    nonisolated private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "SmartCapture")
    private var image: CGImage
    private let language: AppLanguage
    private let onClose: () -> Void
    private var panel: NSPanel?
    private var annotationController: SmartAnnotationWindowController?

    init(image: CGImage, language: AppLanguage, onClose: @escaping () -> Void) {
        self.image = image
        self.language = language
        self.onClose = onClose
    }

    func show() {
        let maxSize = CGSize(width: 720, height: 520)
        let scale = min(1, maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height))
        let size = CGSize(width: max(180, CGFloat(image.width) * scale), height: max(120, CGFloat(image.height) * scale))
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppText.value("scPinTitle", language: language)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        installContent(in: panel)
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
        Self.logger.info("Pin window shown")
    }

    func close() {
        Self.logger.info("Pin close requested")
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        Self.logger.info("Pin window will close")
        annotationController?.close()
        annotationController = nil
        panel?.contentView = nil
        panel = nil
        onClose()
    }

    private func installContent(in panel: NSPanel) {
        panel.contentView = NSHostingView(rootView: SmartPinView(
            image: image,
            language: language,
            onCopy: { [weak self] in self?.copyImage() },
            onOCR: { [weak self] in self?.recognizeText() },
            onAnnotate: { [weak self] in self?.openAnnotation() },
            onClose: { [weak self] in self?.close() }
        ))
    }

    private func copyImage() {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }

    private func recognizeText() {
        let sendableImage = SendableSmartImage(value: image)
        Task { [weak self] in
            guard let text = try? await SmartOCRService.recognize(image: sendableImage), !text.isEmpty else {
                self?.showMessage(title: AppText.value("scOCR", language: self?.language ?? .system), message: AppText.value("scOCRNoText", language: self?.language ?? .system))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.showMessage(title: AppText.value("scOCRCopied", language: self?.language ?? .system), message: text)
        }
    }

    private func openAnnotation() {
        Self.logger.info("Annotation requested; hiding pin window")
        annotationController?.close()
        panel?.orderOut(nil)
        let controller = SmartAnnotationWindowController(
            image: image,
            language: language,
            onComplete: { [weak self] annotated in
                Self.logger.info("Annotation completed; updating pin image")
                guard let self else { return }
                self.image = annotated
                if let panel = self.panel { self.installContent(in: panel) }
            },
            onClose: { [weak self] in
                Self.logger.info("Annotation closed; restoring pin window")
                self?.panel?.orderFrontRegardless()
                self?.annotationController = nil
            }
        )
        annotationController = controller
        controller.show()
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(message.prefix(1_000))
        alert.addButton(withTitle: AppText.value("scOK", language: language))
        alert.runModal()
    }
}

private struct SmartPinView: View {
    let image: CGImage
    let language: AppLanguage
    let onCopy: () -> Void
    let onOCR: () -> Void
    let onAnnotate: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onCopy) { Label(AppText.value("scCopy", language: language), systemImage: "doc.on.doc") }
                Button(action: onOCR) { Label(AppText.value("scOCR", language: language), systemImage: "text.viewfinder") }
                Button(action: onAnnotate) { Label(AppText.value("scAnnotate", language: language), systemImage: "pencil.tip.crop.circle") }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.help(AppText.value("scClose", language: language))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(.ultraThinMaterial)

            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .background(Color.black.opacity(0.04))
        }
    }
}

private struct SendableSmartImage: @unchecked Sendable {
    let value: CGImage
}

private enum SmartOCRService {
    static func recognize(image: SendableSmartImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                let handler = VNImageRequestHandler(cgImage: image.value, options: [:])
                try handler.perform([request])
                return (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
            }
        }.value
    }
}

private enum SmartAnnotationTool: String, CaseIterable, Identifiable {
    case rectangle
    case arrow
    case text

    var id: String { rawValue }
    func title(language: AppLanguage) -> String {
        switch self {
        case .rectangle: AppText.value("scAnnotationRectangle", language: language)
        case .arrow: AppText.value("scAnnotationArrow", language: language)
        case .text: AppText.value("scAnnotationText", language: language)
        }
    }
}

enum SmartAnnotation: Equatable {
    case rectangle(CGRect)
    case arrow(CGPoint, CGPoint)
    case text(String, CGPoint)
}

@MainActor
private final class SmartAnnotationModel: ObservableObject {
    @Published var tool: SmartAnnotationTool = .rectangle
    @Published var annotations: [SmartAnnotation] = []

    func undo() { if !annotations.isEmpty { annotations.removeLast() } }
}

@MainActor
private final class SmartAnnotationWindowController: NSObject, NSWindowDelegate {
    nonisolated private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "SmartCapture")
    private let image: CGImage
    private let language: AppLanguage
    private let onComplete: (CGImage) -> Void
    private let onClose: () -> Void
    private let model = SmartAnnotationModel()
    private var window: NSWindow?
    private var didNotifyClose = false

    init(
        image: CGImage,
        language: AppLanguage,
        onComplete: @escaping (CGImage) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.image = image
        self.language = language
        self.onComplete = onComplete
        self.onClose = onClose
    }

    func show() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppText.value("scAnnotateTitle", language: language)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SmartAnnotationEditor(
            image: image,
            language: language,
            model: model,
            onCancel: { [weak self] in self?.close() },
            onComplete: { [weak self] in self?.complete() }
        ))
        window.center()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }

    private func complete() {
        Self.logger.info("Rendering annotations")
        guard let rendered = SmartAnnotationRenderer.render(image: image, annotations: model.annotations) else { return }
        onComplete(rendered)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.logger.info("Annotation window will close")
        window?.contentView = nil
        window = nil
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose()
    }
}

private struct SmartAnnotationEditor: View {
    let image: CGImage
    let language: AppLanguage
    @ObservedObject var model: SmartAnnotationModel
    let onCancel: () -> Void
    let onComplete: () -> Void
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var showingTextEntry = false
    @State private var pendingText = ""
    @State private var textPoint = CGPoint.zero

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(AppText.value("scAnnotationTool", language: language), selection: $model.tool) {
                    ForEach(SmartAnnotationTool.allCases) { Text($0.title(language: language)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Button(AppText.value("scUndo", language: language), action: model.undo).disabled(model.annotations.isEmpty)
                Spacer()
                Button(AppText.value("scCancel", language: language), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(AppText.value("scDone", language: language), action: onComplete)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)

            GeometryReader { geometry in
                let fitted = fittedRect(imageSize: CGSize(width: image.width, height: image.height), in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.08)
                    Image(decorative: image, scale: 1).resizable().frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                    Canvas { context, _ in
                        drawAnnotations(context: &context, in: fitted)
                        drawDraft(context: &context, in: fitted)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard fitted.contains(value.location) else { return }
                            if dragStart == nil { dragStart = value.startLocation }
                            dragCurrent = value.location
                        }
                        .onEnded { value in finishDrag(value.location, fitted: fitted) })
                }
            }
        }
        .sheet(isPresented: $showingTextEntry) {
            VStack(spacing: 16) {
                Text(AppText.value("scAnnotationTextTitle", language: language)).font(.headline)
                TextField(AppText.value("scText", language: language), text: $pendingText).textFieldStyle(.roundedBorder)
                HStack {
                    Button(AppText.value("scCancel", language: language)) { showingTextEntry = false }
                    Button(AppText.value("scAdd", language: language)) {
                        if !pendingText.isEmpty { model.annotations.append(.text(pendingText, textPoint)) }
                        pendingText = ""
                        showingTextEntry = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 360)
        }
    }

    private func fittedRect(imageSize: CGSize, in available: CGSize) -> CGRect {
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func finishDrag(_ end: CGPoint, fitted: CGRect) {
        guard let start = dragStart, fitted.contains(start), fitted.contains(end) else {
            dragStart = nil; dragCurrent = nil; return
        }
        switch model.tool {
        case .rectangle:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            if rect.width > 3, rect.height > 3 { model.annotations.append(.rectangle(normalized(rect, in: fitted))) }
        case .arrow:
            if hypot(end.x - start.x, end.y - start.y) > 4 {
                model.annotations.append(.arrow(normalized(start, in: fitted), normalized(end, in: fitted)))
            }
        case .text:
            textPoint = normalized(end, in: fitted)
            showingTextEntry = true
        }
        dragStart = nil
        dragCurrent = nil
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    private func normalized(_ value: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: (value.minX - rect.minX) / rect.width, y: (value.minY - rect.minY) / rect.height, width: value.width / rect.width, height: value.height / rect.height)
    }

    private func drawAnnotations(context: inout GraphicsContext, in rect: CGRect) {
        for annotation in model.annotations { draw(annotation, context: &context, in: rect) }
    }

    private func drawDraft(context: inout GraphicsContext, in rect: CGRect) {
        guard let start = dragStart, let end = dragCurrent else { return }
        switch model.tool {
        case .rectangle:
            let value = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            context.stroke(Path(value), with: .color(.red), lineWidth: 3)
        case .arrow: drawArrow(from: start, to: end, context: &context)
        case .text: break
        }
    }

    private func draw(_ annotation: SmartAnnotation, context: inout GraphicsContext, in rect: CGRect) {
        switch annotation {
        case .rectangle(let value):
            let denormalized = CGRect(x: rect.minX + value.minX * rect.width, y: rect.minY + value.minY * rect.height, width: value.width * rect.width, height: value.height * rect.height)
            context.stroke(Path(denormalized), with: .color(.red), lineWidth: 3)
        case .arrow(let start, let end):
            drawArrow(from: CGPoint(x: rect.minX + start.x * rect.width, y: rect.minY + start.y * rect.height), to: CGPoint(x: rect.minX + end.x * rect.width, y: rect.minY + end.y * rect.height), context: &context)
        case .text(let text, let point):
            context.draw(Text(text).font(.system(size: 18, weight: .bold)).foregroundColor(.red), at: CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height), anchor: .topLeading)
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, context: inout GraphicsContext) {
        var path = Path(); path.move(to: start); path.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head: CGFloat = 14
        path.move(to: end); path.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
        path.move(to: end); path.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
        context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}

enum SmartAnnotationRenderer {
    static func render(image: CGImage, annotations: [SmartAnnotation]) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setFillColor(NSColor.systemRed.cgColor)
        context.setLineWidth(max(3, CGFloat(width) / 350))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for annotation in annotations {
            switch annotation {
            case .rectangle(let rect):
                context.stroke(CGRect(x: rect.minX * bounds.width, y: (1 - rect.maxY) * bounds.height, width: rect.width * bounds.width, height: rect.height * bounds.height))
            case .arrow(let start, let end):
                let a = CGPoint(x: start.x * bounds.width, y: (1 - start.y) * bounds.height)
                let b = CGPoint(x: end.x * bounds.width, y: (1 - end.y) * bounds.height)
                context.move(to: a); context.addLine(to: b)
                let angle = atan2(b.y - a.y, b.x - a.x), head = max(14, CGFloat(width) / 45)
                context.move(to: b); context.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 6), y: b.y - head * sin(angle - .pi / 6)))
                context.move(to: b); context.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 6), y: b.y - head * sin(angle + .pi / 6)))
                context.strokePath()
            case .text(let text, let point):
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
                let fontSize = max(18, CGFloat(width) / 35)
                (text as NSString).draw(at: CGPoint(x: point.x * bounds.width, y: (1 - point.y) * bounds.height - fontSize), withAttributes: [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: NSColor.systemRed])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        return context.makeImage()
    }
}
