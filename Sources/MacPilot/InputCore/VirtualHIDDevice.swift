import CoreFoundation
import Foundation
import MacPilotRemoteProtocol

// The SDK does not ship `IOHIDUserDevice.h`, but IOKit exports the C symbols.
// Re-declared here as private file-scoped bindings so the rest of the app
// never sees them. `IOHIDUserDeviceTerminate` is not exported, so the device
// is released through its CF retain count instead.

@_silgen_name("IOHIDUserDeviceCreate")
private func IOHIDUserDeviceCreate(_ allocator: CFAllocator?, _ properties: CFDictionary) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDUserDeviceHandleReport")
private func IOHIDUserDeviceHandleReport(_ device: AnyObject, _ report: UnsafePointer<UInt8>, _ reportLength: CFIndex) -> Int32

/// Assembles the HID reports the virtual pointing device emits. Pure logic,
/// so the wire-adjacent encoding is testable without touching IOKit.
enum VirtualHIDReportBuilder {
    /// Report layout, 7 bytes: button bits + 5 padding bits, X int16 LE,
    /// Y int16 LE, vertical wheel int8, horizontal (AC Pan) int8.
    static func report(
        dx: Int16,
        dy: Int16,
        buttons: UInt8,
        wheel: Int8 = 0,
        pan: Int8 = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 7)
        bytes[0] = buttons & 0b0000_0111
        bytes.replaceSubrange(1..<3, with: withUnsafeBytes(of: dx.littleEndian) { Array($0) })
        bytes.replaceSubrange(3..<5, with: withUnsafeBytes(of: dy.littleEndian) { Array($0) })
        bytes[5] = UInt8(bitPattern: wheel)
        bytes[6] = UInt8(bitPattern: pan)
        return bytes
    }

    /// Standard HID descriptor for a relative pointing device: three buttons,
    /// 16-bit X/Y, vertical wheel and AC Pan (horizontal wheel). All integers
    /// little endian, matching what HID expects on the wire.
    static let reportDescriptor: [UInt8] = [
        0x05, 0x01, // Usage Page (Generic Desktop)
        0x09, 0x02, // Usage (Mouse)
        0xA1, 0x01, // Collection (Application)
        0x09, 0x01, //   Usage (Pointer)
        0xA1, 0x00, //   Collection (Physical)
        0x05, 0x09, //     Usage Page (Buttons)
        0x19, 0x01, //     Usage Minimum (1)
        0x29, 0x03, //     Usage Maximum (3)
        0x15, 0x00, //     Logical Minimum (0)
        0x25, 0x01, //     Logical Maximum (1)
        0x95, 0x03, //     Report Count (3)
        0x75, 0x01, //     Report Size (1)
        0x81, 0x02, //     Input (Data, Var, Abs)
        0x95, 0x01, //     Report Count (1)
        0x75, 0x05, //     Report Size (5)
        0x81, 0x03, //     Input (Const, Var, Abs) — padding
        0x05, 0x01, //     Usage Page (Generic Desktop)
        0x09, 0x30, //     Usage (X)
        0x09, 0x31, //     Usage (Y)
        0x16, 0x01, 0x80, // Logical Minimum (-32767)
        0x26, 0xFF, 0x7F, // Logical Maximum (32767)
        0x75, 0x10, //     Report Size (16)
        0x95, 0x02, //     Report Count (2)
        0x81, 0x06, //     Input (Data, Var, Rel)
        0x09, 0x38, //     Usage (Wheel)
        0x15, 0x81, //     Logical Minimum (-127)
        0x25, 0x7F, //     Logical Maximum (127)
        0x75, 0x08, //     Report Size (8)
        0x95, 0x01, //     Report Count (1)
        0x81, 0x06, //     Input (Data, Var, Rel)
        0x05, 0x0C, //     Usage Page (Consumer)
        0x0A, 0x38, 0x02, // Usage (AC Pan)
        0x81, 0x06, //     Input (Data, Var, Rel)
        0xC0,       //   End Collection
        0xC0,       // End Collection
    ]
}

/// A user-space virtual HID pointing device.
///
/// This is the device-level injection path: reports posted here reach the
/// window server as genuine device events, so cursor movement picks up macOS's
/// own pointer acceleration, clicks and drags are real device input, and the
/// app does not need the Accessibility grant that posting CGEvents requires.
///
/// Deliberately a mouse, not a Magic Trackpad: Apple's multitouch digitizer
/// protocol (the thing the system gesture engine consumes) is undocumented,
/// and a half-formed multitouch device would be worse than no device at all.
/// Scrolling stays on the continuous-event path in `ScrollInjector`, which is
/// smoother than a stepped wheel.
final class VirtualHIDDevice {
    /// `nil` performs real IOKit creation; a forced value lets tests exercise
    /// either outcome without touching the IO registry.
    private let creationOverride: Bool?
    private var device: Unmanaged<AnyObject>?

    /// False when creation was attempted and failed; the coordinator then
    /// falls back to CGEvent injection for the process lifetime.
    private(set) var isAvailable = false
    private(set) var creationAttempted = false
    /// The most recent report, kept for test observation.
    private(set) var lastReport: [UInt8]?
    /// Test hook: pretend every report post fails, as if the device was torn
    /// down underneath the session.
    var failReports = false

    init(creationOverride: Bool? = nil) {
        self.creationOverride = creationOverride
    }

    func activate() -> Bool {
        if creationAttempted { return isAvailable }
        creationAttempted = true
        if let creationOverride {
            isAvailable = creationOverride
            return creationOverride
        }
        let properties: [CFString: Any] = [
            "ReportDescriptor" as CFString: Data(VirtualHIDReportBuilder.reportDescriptor),
            "Product" as CFString: "MacPilot Virtual Trackpad",
            "Transport" as CFString: "USB",
            "VendorID" as CFString: 0x1209,
            "ProductID" as CFString: 0x4242,
        ]
        guard let created = IOHIDUserDeviceCreate(kCFAllocatorDefault, properties as CFDictionary) else {
            return false
        }
        device = created
        isAvailable = true
        return true
    }

    deinit {
        device?.release()
    }

    /// Posts one pointer report. Button bits are the caller's current state
    /// (bit 0 left, bit 1 right): a click is a report with the bit set, then
    /// one without, exactly like a physical mouse.
    func handle(dx: Int16, dy: Int16, buttons: UInt8) {
        var bytes = VirtualHIDReportBuilder.report(dx: dx, dy: dy, buttons: buttons)
        lastReport = bytes
        if failReports {
            isAvailable = false
            return
        }
        guard let device else { return }
        let result = bytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            IOHIDUserDeviceHandleReport(device.takeUnretainedValue(), buffer.baseAddress!, CFIndex(buffer.count))
        }
        if result != 0 {
            // A failed report means the device was torn down underneath us;
            // stop using it and let the coordinator fall back.
            isAvailable = false
        }
    }
}
