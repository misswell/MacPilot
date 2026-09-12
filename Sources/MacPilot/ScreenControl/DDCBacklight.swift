//
//  DDCBacklight.swift
//  MacPilot
//
//  An external display's own backlight, over DDC/CI.
//

import CoreGraphics
import Foundation
import IOKit

/// The DDC/CI messages MacPilot sends to a monitor's backlight control.
///
/// DDC/CI is the MCCS command set carried over I2C: slave address `0x37`, the
/// sub-address `0x51` in both directions, and a checksum that covers the
/// sub-address *plus* the data bytes. That last detail is what decides whether a
/// monitor answers at all, and the reply direction uses a different seed than the
/// host direction — so these stay pure functions, with packets captured from a
/// live `HP 24w` as their fixtures.
enum DDCPacket {
    /// I2C slave address and sub-address of the DDC/CI channel.
    static let address: UInt32 = 0x37
    static let subAddress: UInt32 = 0x51
    /// MCCS "image adjustment: luminance" — the panel backlight.
    static let brightness: UInt8 = 0x10
    /// EDID lives on the I2C bus DDC/CI shares, at this address and offset.
    static let edidAddress: UInt32 = 0x50
    static let edidLength = 128

    /// Host-to-display checksum: XOR of the wire bytes with the `0x6E` seed.
    static func checksum(_ wire: [UInt8]) -> UInt8 {
        wire.reduce(0x6E) { $0 ^ $1 }
    }

    /// A `Get VCP Feature` request for `vcp`.
    static func readRequest(vcp: UInt8) -> [UInt8] {
        var data: [UInt8] = [0x82, 0x01, vcp]
        data.append(checksum([UInt8(subAddress)] + data))
        return data
    }

    /// A `Set VCP Feature` request for `vcp`.
    static func writeRequest(vcp: UInt8, value: UInt16) -> [UInt8] {
        var data: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        data.append(checksum([UInt8(subAddress)] + data))
        return data
    }

    /// A parsed `Get VCP Feature` reply.
    struct Reply: Equatable {
        let vcp: UInt8
        let current: UInt16
        let maximum: UInt16

        /// The reply as 0...1, or nil when the display reports no range.
        var level: Double? {
            guard maximum > 0 else { return nil }
            return min(max(Double(current) / Double(maximum), 0), 1)
        }
    }

    static let replyLength = 11
    /// Display address, length, then the "get VCP feature reply" opcode.
    private static let replyPrefix: [UInt8] = [0x6E, 0x88, 0x02]

    /// Validates a reply: length, direction header, result code and the VCP that
    /// was asked about. A monitor answering about something else is not an answer.
    static func parse(reply: [UInt8], expecting vcp: UInt8) -> Reply? {
        guard reply.count == replyLength,
              Array(reply.prefix(3)) == replyPrefix,
              reply[3] == 0x00,
              reply[4] == vcp
        else { return nil }
        return Reply(
            vcp: vcp,
            current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
            maximum: UInt16(reply[6]) << 8 | UInt16(reply[7])
        )
    }

    /// The raw value a 0...1 level means on a display reporting `maximum`.
    static func rawValue(for level: Double, maximum: UInt16) -> UInt16 {
        UInt16((min(max(level, 0), 1) * Double(maximum)).rounded())
    }

    /// Whether a monitor's read-back confirms what was written. One step of
    /// tolerance, because a monitor is allowed to land on its own grid; a larger
    /// gap means the write was ignored and the caller must not claim a dark
    /// screen that is still lit.
    static func confirms(wrote raw: UInt16, readback: UInt16) -> Bool {
        abs(Int(readback) - Int(raw)) <= 1
    }
}

/// Reads and writes an external display's backlight over DDC/CI.
///
/// This is the path that makes "turn off screen" real on a display whose
/// backlight `DisplayServices` cannot drive: an external monitor renders a black
/// cover as a lit-but-black panel with the pointer floating on top, while its own
/// backlight at zero is genuinely dark, needs no display sleep, and so cannot
/// trip the Lock Screen policy that would lock the session.
///
/// `IOAVService` is private IOKit API with no public replacement, resolved at
/// runtime like the `DisplayServices` driver so the app takes no link-time
/// dependency on it. Every call is optional: a display that does not answer is
/// covered by the black overlay as before.
struct DDCBacklight: Sendable {
    /// The backlight level in `0...1`, or nil when this display does not answer.
    let level: @Sendable (CGDirectDisplayID) -> Double?
    /// Writes a level and reads it back; false when the display did not confirm.
    let setLevel: @Sendable (Double, CGDirectDisplayID) -> Bool

    static let shared: DDCBacklight? = DDCBacklightIO.driver()
}

/// The IOKit half, kept apart so the packet rules above stay testable without a
/// monitor attached.
private enum DDCBacklightIO {
    typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    typealias Transfer = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    /// A monitor's I2C channel is a single shared resource and MacPilot can be
    /// asked for display state from more than one thread, so transfers are
    /// serialised: two overlapping claims on the same bus would show up as
    /// monitors that randomly stop answering.
    private static let busLock = NSLock()

    /// A display's identity as its EDID reports it, which is what ties one
    /// `DCPAVServiceProxy` to one `CGDirectDisplayID`.
    private struct Identity: Equatable {        let model: Int
        let serial: Int

        func matches(_ other: Identity) -> Bool {
            guard model != 0, model == other.model else { return false }
            // Plenty of monitors leave the serial at zero, which is "same model,
            // cannot tell them apart" rather than "different display".
            guard serial != 0, other.serial != 0 else { return true }
            return serial == other.serial
        }
    }

    static func driver() -> DDCBacklight? {
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        guard let handle = dlopen(path, RTLD_NOW),
              let createSymbol = dlsym(handle, "IOAVServiceCreateWithService"),
              let readSymbol = dlsym(handle, "IOAVServiceReadI2C"),
              let writeSymbol = dlsym(handle, "IOAVServiceWriteI2C")
        else { return nil }
        let create = unsafeBitCast(createSymbol, to: CreateWithService.self)
        let read = unsafeBitCast(readSymbol, to: Transfer.self)
        let write = unsafeBitCast(writeSymbol, to: Transfer.self)
        return DDCBacklight(
            level: { displayID in
                busLock.lock()
                defer { busLock.unlock() }
                guard let service = service(for: displayID, create: create, read: read) else { return nil }
                defer { release(service) }
                return reply(from: service, vcp: DDCPacket.brightness, read: read, write: write)?.level
            },
            setLevel: { level, displayID in
                busLock.lock()
                defer { busLock.unlock() }
                guard let service = service(for: displayID, create: create, read: read) else { return false }
                defer { release(service) }
                guard let before = reply(from: service, vcp: DDCPacket.brightness, read: read, write: write) else { return false }
                let raw = DDCPacket.rawValue(for: level, maximum: before.maximum)
                guard send(DDCPacket.writeRequest(vcp: DDCPacket.brightness, value: raw), to: service, write: write) else { return false }
                // An I2C write the monitor ignored is not a change: read it back
                // and let the caller fall back to covering the display instead of
                // claiming a dark screen that is still lit.
                usleep(60_000)
                guard let after = reply(from: service, vcp: DDCPacket.brightness, read: read, write: write) else { return false }
                return DDCPacket.confirms(wrote: raw, readback: after.current)
            }
        )
    }

    /// The I2C channel for one display, or nil when DDC cannot address it.
    ///
    /// A `DCPAVServiceProxy`'s own ancestry does not reach the display node, so
    /// the match is made by reading the EDID over the very channel being chosen
    /// and comparing it with what CoreGraphics reports for the display: guessing
    /// here would dim somebody else's monitor.
    private static func service(
        for displayID: CGDirectDisplayID,
        create: CreateWithService,
        read: Transfer
    ) -> UnsafeMutableRawPointer? {
        // A built-in panel is driven by DisplayServices and does not speak DDC/CI.
        guard CGDisplayIsBuiltin(displayID) == 0 else { return nil }
        let wanted = Identity(model: Int(CGDisplayModelNumber(displayID)), serial: Int(CGDisplaySerialNumber(displayID)))

        var candidates: [UnsafeMutableRawPointer] = []
        var identities: [Identity?] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let avService = create(kCFAllocatorDefault, entry) else { continue }
            candidates.append(avService)
            identities.append(identity(of: avService, read: read))
        }

        // An exact EDID match first; with a single external display attached, no
        // match still leaves only one thing it could be.
        var chosen: Int? = identities.firstIndex { $0?.matches(wanted) == true }
        if chosen == nil, candidates.count == 1 { chosen = 0 }
        for (index, service) in candidates.enumerated() where index != chosen {
            release(service)
        }
        return chosen.map { candidates[$0] }
    }

    private static func identity(of service: UnsafeMutableRawPointer, read: Transfer) -> Identity? {
        var edid = [UInt8](repeating: 0, count: DDCPacket.edidLength)
        let result = edid.withUnsafeMutableBufferPointer { buffer in
            read(service, DDCPacket.edidAddress, 0x00, buffer.baseAddress!, UInt32(buffer.count))
        }
        guard result == 0, edid.count >= 16, edid[0] == 0x00, edid[1] == 0xFF, edid[7] == 0x00 else { return nil }
        let model = Int(edid[10]) | Int(edid[11]) << 8
        let serial = Int(edid[12]) | Int(edid[13]) << 8 | Int(edid[14]) << 16 | Int(edid[15]) << 24
        return Identity(model: model, serial: serial)
    }

    private static func reply(
        from service: UnsafeMutableRawPointer,
        vcp: UInt8,
        read: Transfer,
        write: Transfer
    ) -> DDCPacket.Reply? {
        guard send(DDCPacket.readRequest(vcp: vcp), to: service, write: write) else { return nil }
        // DDC/CI allows the monitor this long to have an answer ready.
        usleep(50_000)
        var bytes = [UInt8](repeating: 0, count: DDCPacket.replyLength)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            read(service, DDCPacket.address, DDCPacket.subAddress, buffer.baseAddress!, UInt32(buffer.count))
        }
        guard result == 0 else { return nil }
        return DDCPacket.parse(reply: bytes, expecting: vcp)
    }

    @discardableResult
    private static func send(_ payload: [UInt8], to service: UnsafeMutableRawPointer, write: Transfer) -> Bool {
        var bytes = payload
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            write(service, DDCPacket.address, DDCPacket.subAddress, buffer.baseAddress!, UInt32(buffer.count))
        }
        return result == 0
    }

    /// `IOAVServiceCreateWithService` returns a +1 reference; every candidate the
    /// match rejected is released, so a lookup leaks nothing.
    private static func release(_ service: UnsafeMutableRawPointer) {
        Unmanaged<CFTypeRef>.fromOpaque(service).release()
    }
}
