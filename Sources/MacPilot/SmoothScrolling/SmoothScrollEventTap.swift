@preconcurrency import CoreGraphics
import Foundation

/// Keeps the system tap and its run-loop source in one lifetime, and permits
/// recovery tests without installing a real input hook in the user's session.
@MainActor
protocol SmoothScrollEventTap: AnyObject {
    var isValid: Bool { get }
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
    func invalidate()
}

@MainActor
final class SystemSmoothScrollEventTap: SmoothScrollEventTap {
    private let port: CFMachPort
    private let source: CFRunLoopSource

    init?(mask: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer) {
        guard let port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    var isValid: Bool { CFMachPortIsValid(port) }
    var isEnabled: Bool { CGEvent.tapIsEnabled(tap: port) }

    func setEnabled(_ enabled: Bool) {
        CGEvent.tapEnable(tap: port, enable: enabled)
    }

    func invalidate() {
        setEnabled(false)
        CFMachPortInvalidate(port)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
}
