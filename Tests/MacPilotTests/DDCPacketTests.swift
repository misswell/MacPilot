import Foundation
import Testing

@testable import MacPilot

/// The DDC/CI wire format, pinned to packets captured from a live `HP 24w`.
///
/// A wrong byte here does not fail loudly: the monitor simply ignores the
/// message, which would look exactly like a monitor that does not support DDC at
/// all — the failure that took the longest to find on real hardware. So the
/// fixtures below are the ones that actually worked, including the checksum,
/// which covers the sub-address byte as well as the data.
struct DDCPacketTests {
    private let brightnessRead: [UInt8] = [0x82, 0x01, 0x10, 0xAC]
    private let brightnessWriteZero: [UInt8] = [0x84, 0x03, 0x10, 0x00, 0x00, 0xA8]
    private let brightnessWriteFull: [UInt8] = [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC]
    /// `6E 88 02 00 10 00 00 64 00 64 A4` — 100 out of a maximum of 100, which is
    /// what the HP reports at its out-of-the-box setting.
    private let fullBrightnessReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4]

    @Test func theReadRequestMatchesWhatTheMonitorAnswers() {
        #expect(DDCPacket.readRequest(vcp: DDCPacket.brightness) == brightnessRead)
        #expect(DDCPacket.subAddress == 0x51)
        #expect(DDCPacket.address == 0x37)
    }

    @Test func theWriteRequestMatchesWhatTheMonitorAccepts() {
        #expect(DDCPacket.writeRequest(vcp: DDCPacket.brightness, value: 0) == brightnessWriteZero)
        #expect(DDCPacket.writeRequest(vcp: DDCPacket.brightness, value: 100) == brightnessWriteFull)
    }

    @Test func aReplyCarriesTheCurrentLevelOutOfItsRange() throws {
        let reply = try #require(DDCPacket.parse(reply: fullBrightnessReply, expecting: DDCPacket.brightness))
        #expect(reply.current == 100)
        #expect(reply.maximum == 100)
        #expect(reply.level == 1)
    }

    @Test func aDarkReplyIsReadAsZeroRatherThanMissing() throws {
        let dark: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x00, 0x44]
        let reply = try #require(DDCPacket.parse(reply: dark, expecting: DDCPacket.brightness))
        #expect(reply.current == 0)
        #expect(reply.level == 0)
    }

    @Test func aReplyAboutSomethingElseIsNotAnAnswer() {
        // Wrong VCP: the monitor answered, but about another control.
        #expect(DDCPacket.parse(reply: fullBrightnessReply, expecting: 0x12) == nil)
        // Failure result code.
        var failed = fullBrightnessReply
        failed[3] = 0x01
        #expect(DDCPacket.parse(reply: failed, expecting: DDCPacket.brightness) == nil)
        // A short read is the shape a partial I2C transfer leaves behind.
        #expect(DDCPacket.parse(reply: Array(fullBrightnessReply.prefix(4)), expecting: DDCPacket.brightness) == nil)
        // Garbage, as read from a channel that answered nothing.
        #expect(DDCPacket.parse(reply: [UInt8](repeating: 0xFF, count: DDCPacket.replyLength), expecting: DDCPacket.brightness) == nil)
    }

    @Test func aReplyWithoutARangeHasNoLevel() {
        let pointless: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        #expect(DDCPacket.parse(reply: pointless, expecting: DDCPacket.brightness)?.maximum == 0)
        #expect(DDCPacket.parse(reply: pointless, expecting: DDCPacket.brightness)?.level == nil)
    }

    @Test func aLevelBecomesTheRawValueTheMonitorUnderstands() {
        #expect(DDCPacket.rawValue(for: 0, maximum: 100) == 0)
        #expect(DDCPacket.rawValue(for: 0.5, maximum: 100) == 50)
        #expect(DDCPacket.rawValue(for: 1, maximum: 100) == 100)
        // Out-of-range input is clamped rather than wrapped into a bright screen.
        #expect(DDCPacket.rawValue(for: 4, maximum: 100) == 100)
        #expect(DDCPacket.rawValue(for: -1, maximum: 100) == 0)
        // A display with a 255 range, which DDC/CI also allows.
        #expect(DDCPacket.rawValue(for: 0.5, maximum: 255) == 128)
    }

    @Test func anIgnoredWriteIsNotMistakenForABlankedDisplay() {
        #expect(DDCPacket.confirms(wrote: 0, readback: 0))
        #expect(DDCPacket.confirms(wrote: 0, readback: 1))
        #expect(!DDCPacket.confirms(wrote: 0, readback: 100))
        #expect(DDCPacket.confirms(wrote: 50, readback: 50))
        #expect(DDCPacket.confirms(wrote: 50, readback: 51))
        #expect(!DDCPacket.confirms(wrote: 50, readback: 52))
    }
}
