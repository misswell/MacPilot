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
    /// MCCS "display power mode": the monitor's own power switch. On plenty of
    /// monitors brightness zero is a *dim but visible* level rather than a dark
    /// panel, so this is the only control that makes an external display truly
    /// black.
    static let powerMode: UInt8 = 0xD6
    /// `powerMode` value for "on".
    static let powerOn: UInt16 = 0x01
    /// `powerMode` values for the dark DPMS states: standby, suspend, soft off
    /// and hard off.
    static let powerStandby: UInt16 = 0x02
    static let powerSuspend: UInt16 = 0x03
    /// `powerMode` value for DPMS "off (soft)": panel and backlight go dark while
    /// the monitor keeps answering DDC, which is what makes it reversible in
    /// software. Verified on an `HP 24w`, which also ignores the standby value
    /// `0x02` outright, so the soft-off state is the one to use.
    static let powerOff: UInt16 = 0x04
    static let powerHardOff: UInt16 = 0x05

    /// Whether a reported power mode means the panel is not lit.
    ///
    /// A monitor is not obliged to echo the value it was written: the `SSN-24`
    /// here answers the soft-off (`0x04`) with standby (`0x02`), and other
    /// panels go silent instead. So "is it off?" has to accept any of the dark
    /// DPMS states rather than compare against the byte that went out — doing
    /// the latter is what left a switched-off external panel with no record
    /// that anything had been written to it.
    static func isPoweredDown(_ mode: UInt16) -> Bool {
        (powerStandby...powerHardOff).contains(mode)
    }

    /// Whether a monitor's reported power mode confirms a write of `mode`.
    /// Turning on is confirmed only by "on"; turning off is confirmed by any
    /// dark state.
    static func confirms(powerMode mode: UInt16, reported: UInt16) -> Bool {
        mode == powerOn ? reported == powerOn : isPoweredDown(reported)
    }
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
    /// The power mode the monitor reports, or nil when it does not answer.
    let powerMode: @Sendable (CGDirectDisplayID) -> UInt16?
    /// Writes a power mode and waits for the monitor to report a matching state.
    ///
    /// Waking is the slow direction: right after "on" the monitor stops
    /// answering DDC for about a second, so this retries rather than treating
    /// the first silent read as a failure.
    let setPowerMode: @Sendable (UInt16, CGDirectDisplayID) -> PowerModeWrite

    static let shared: DDCBacklight? = DDCBacklightIO.driver()
}

/// The outcome of a `Set VCP Feature` write to a monitor's power control.
///
/// The two halves are kept apart because they mean different things to a caller
/// holding a screen dark. `sent` is the point of no return — the command is on
/// the I2C bus and the panel may already be out — while `confirmed` only says
/// the monitor admitted it. A blank that recorded its state from `confirmed`
/// alone left a dark panel with nothing recorded to undo it, which is the
/// "external monitor never wakes" bug this shape exists to prevent.
struct PowerModeWrite: Equatable, Sendable {
    /// The write reached the I2C bus (false also when it was deliberately skipped).
    let sent: Bool
    /// The monitor reported back a mode that matches the write.
    let confirmed: Bool

    static let notSent = PowerModeWrite(sent: false, confirmed: false)

    /// Whether the display may be dark now and has to be remembered as switched
    /// off. True past a successful write even without confirmation: a monitor
    /// that answers a soft-off with "standby", or with silence, is dark all the
    /// same.
    var mayHavePoweredDown: Bool { sent }

    /// Whether the monitor ended up in the requested state.
    var didConfirm: Bool { confirmed }
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
    private struct Identity: Equatable {
        let model: Int
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
                return cachedReply(for: displayID, vcp: DDCPacket.brightness, create: create, read: read, write: write)?.level
            },
            setLevel: { level, displayID in
                busLock.lock()
                defer { busLock.unlock() }
                guard let service = service(for: displayID, create: create, read: read) else { return false }
                defer { release(service) }
                guard let before = cachedReply(for: displayID, vcp: DDCPacket.brightness, create: create, read: read, write: write) else {
                    return false
                }
                let raw = DDCPacket.rawValue(for: level, maximum: before.maximum)
                guard send(DDCPacket.writeRequest(vcp: DDCPacket.brightness, value: raw), to: service, write: write) else { return false }
                // An I2C write the monitor ignored is not a change: read it back
                // and let the caller fall back to covering the display instead of
                // claiming a dark screen that is still lit.
                usleep(60_000)
                guard let after = reply(from: service, vcp: DDCPacket.brightness, read: read, write: write) else { return false }
                // The read-back is also the freshest thing known about this
                // display, so it replaces whatever the probe had cached.
                cache(after, for: displayID, vcp: DDCPacket.brightness)
                return DDCPacket.confirms(wrote: raw, readback: after.current)
            },
            powerMode: { displayID in
                busLock.lock()
                defer { busLock.unlock() }
                return cachedReply(for: displayID, vcp: DDCPacket.powerMode, create: create, read: read, write: write)?.current
            },
            setPowerMode: { mode, displayID in
                busLock.lock()
                defer { busLock.unlock() }
                // A monitor that ignored this a moment ago will ignore it again;
                // without remembering that, every blank would spend the whole
                // confirm window waiting for a state that is never coming. The
                // memory is short, so a display that was only slow gets another
                // chance instead of losing real black for the whole session.
                if mode == DDCPacket.powerOff,
                   let verdict = powerModeUnsupported[displayID],
                   Date().timeIntervalSince(verdict) < unsupportedLifetime {
                    return .notSent
                }
                guard let service = service(for: displayID, create: create, read: read) else { return .notSent }
                defer { release(service) }
                guard send(DDCPacket.writeRequest(vcp: DDCPacket.powerMode, value: mode), to: service, write: write) else {
                    return .notSent
                }
                // Going dark is quick; coming back the monitor stops answering DDC
                // for about a second, so that direction waits longer.
                let attempts = mode == DDCPacket.powerOn ? 8 : 5
                let pause: UInt32 = mode == DDCPacket.powerOn ? 300_000 : 200_000
                for _ in 0..<attempts {
                    usleep(pause)
                    guard let reply = reply(from: service, vcp: DDCPacket.powerMode, read: read, write: write) else { continue }
                    // Matched by state, not by equality: a monitor is free to
                    // answer a soft-off with standby instead of echoing the byte.
                    guard DDCPacket.confirms(powerMode: mode, reported: reply.current) else { continue }
                    cache(reply, for: displayID, vcp: DDCPacket.powerMode)
                    powerModeUnsupported[displayID] = nil
                    return PowerModeWrite(sent: true, confirmed: true)
                }
                if mode == DDCPacket.powerOff { powerModeUnsupported[displayID] = Date() }
                // Sent but not acknowledged. The caller is told both facts, so a
                // panel that is probably dark is still recorded as such.
                return PowerModeWrite(sent: true, confirmed: false)
            }
        )
    }

    /// A monitor's I2C bus is slow — resolving the channel plus a brightness read
    /// is around 70 ms — and one state request asks for the same control twice:
    /// the blank probe and the brightness read that follows it. Remembering the
    /// last answer per control for a moment turns the second into nothing, while
    /// the short lifetime keeps a display that was unplugged, woken or changed
    /// from being described by a stale answer.
    private static let replyCacheLifetime: TimeInterval = 1
    /// `busLock`-guarded, which the compiler cannot see through.
    nonisolated(unsafe) private static var replyCache: (displayID: CGDirectDisplayID, replies: [UInt8: CachedAnswer], at: Date)?
    /// Displays seen to ignore `powerOff`, so the next blank skips straight to the
    /// next mechanism. `busLock`-guarded.
    nonisolated(unsafe) private static var powerModeUnsupported: [CGDirectDisplayID: Date] = [:]
    /// How long a display stays marked as ignoring `powerOff`.
    private static let unsupportedLifetime: TimeInterval = 60

    /// One control's answer, remembered per control: asking a second control of
    /// the same monitor must not make that one look like a monitor which never
    /// answered.
    private enum CachedAnswer {
        case reply(DDCPacket.Reply)
        /// Asked, and nothing came back. Also worth remembering, so a display that
        /// does not implement a control is not interrogated on every call.
        case noAnswer

        var reply: DDCPacket.Reply? {
            if case let .reply(reply) = self { return reply }
            return nil
        }
    }

    private static func cacheIsFresh(_ at: Date) -> Bool {
        Date().timeIntervalSince(at) < replyCacheLifetime
    }

    private static func cache(_ reply: DDCPacket.Reply, for displayID: CGDirectDisplayID, vcp: UInt8) {
        let cached = replyCache.flatMap { $0.displayID == displayID && cacheIsFresh($0.at) ? $0 : nil }
        var replies = cached?.replies ?? [:]
        replies[vcp] = .reply(reply)
        replyCache = (displayID, replies, Date())
    }

    /// Caller must hold `busLock`.
    private static func cachedReply(
        for displayID: CGDirectDisplayID,
        vcp: UInt8,
        create: CreateWithService,
        read: Transfer,
        write: Transfer
    ) -> DDCPacket.Reply? {
        let cached = replyCache.flatMap { $0.displayID == displayID && cacheIsFresh($0.at) ? $0 : nil }
        // Remembered for this control specifically: another control's answer says
        // nothing about this one.
        if let answer = cached?.replies[vcp] { return answer.reply }

        var replies = cached?.replies ?? [:]
        let reply: DDCPacket.Reply?
        if let service = service(for: displayID, create: create, read: read) {
            defer { release(service) }
            reply = self.reply(from: service, vcp: vcp, read: read, write: write)
        } else {
            reply = nil
        }
        replies[vcp] = reply.map(CachedAnswer.reply) ?? .noAnswer
        replyCache = (displayID, replies, Date())
        return reply
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
