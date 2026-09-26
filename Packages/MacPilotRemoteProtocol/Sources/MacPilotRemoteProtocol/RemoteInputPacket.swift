import Foundation

/// One pointer action synthesized on the iPhone's trackpad surface.
///
/// These never travel as JSON `RemoteCommand`s: cursor motion runs at up to
/// 120 Hz, and JSON encoding per event costs more than the event itself. They
/// ride the binary realtime channel instead (frame tag `0x03`).
public enum RemoteInputEvent: Equatable, Sendable {
    /// Relative cursor motion. `dx`/`dy` are finger pixels — never screen
    /// coordinates, which would break on Retina, scaled or multi-display Macs.
    /// `buttons` carries the buttons held while moving (left = drag).
    case move(dx: Double, dy: Double, buttons: RemoteInputButtons)
    case click(button: RemoteInputButton, action: RemoteInputAction)
    /// Two-finger scrolling in finger pixels, natural direction: the values
    /// follow the fingers, so content follows the fingers the way macOS does.
    case scroll(dx: Double, dy: Double)
}

/// Mouse buttons held during a move.
public struct RemoteInputButtons: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left = RemoteInputButtons(rawValue: 1 << 0)
    public static let right = RemoteInputButtons(rawValue: 1 << 1)
}

public enum RemoteInputButton: UInt8, Sendable, Equatable {
    case left = 0
    case right = 1
}

public enum RemoteInputAction: UInt8, Sendable, Equatable {
    case down = 0
    case up = 1
}

/// One frame of realtime input: a timestamped batch of events.
public struct RemoteInputBatch: Sendable, Equatable {
    /// Milliseconds since the Unix epoch on the sending device. The receiver
    /// feeds it to the same freshness check command frames use.
    public var timestampMilliseconds: Int64
    public var events: [RemoteInputEvent]

    public init(timestampMilliseconds: Int64, events: [RemoteInputEvent]) {
        self.timestampMilliseconds = timestampMilliseconds
        self.events = events
    }
}

/// Binary codec for `RemoteInputBatch`.
///
/// Layout (all integers big endian, fixed point scale 0.1 pixels):
///
/// ```
/// header:  u8  version (1)
///          u8  reserved (0)
///          u16 event count
///          u64 timestamp milliseconds
/// events:  move:   u8 kind=1 | i16 dx | i16 dy | u8 buttons
///          click:  u8 kind=2 | u8 button | u8 action
///          scroll: u8 kind=3 | i16 dx | i16 dy
/// ```
///
/// A six byte move event is the whole reason this is not JSON: at 120 Hz the
/// JSON envelope would outweigh the payload by roughly ten to one.
public enum RemoteInputBatchCodec {
    public static let batchVersion: UInt8 = 1
    /// Bounds a single batch; a well behaved sender coalesces far below this.
    public static let maximumEventsPerBatch = 256
    /// Deltas travel in tenths of a pixel, so ±3276.7 px per event.
    static let fixedPointScale = 10.0

    public static func encode(_ batch: RemoteInputBatch) throws -> Data {
        guard batch.events.count <= maximumEventsPerBatch else {
            throw RemoteProtocolError.invalidMessage
        }
        var data = Data(capacity: 12 + batch.events.count * 7)
        data.append(batchVersion)
        data.append(0)
        data.append(contentsOf: bigEndian(UInt16(batch.events.count)))
        data.append(contentsOf: bigEndian(UInt64(bitPattern: Int64(batch.timestampMilliseconds))))
        for event in batch.events {
            switch event {
            case let .move(dx, dy, buttons):
                data.append(1)
                data.append(contentsOf: bigEndian(fixedPoint(dx)))
                data.append(contentsOf: bigEndian(fixedPoint(dy)))
                data.append(buttons.rawValue)
            case let .click(button, action):
                data.append(2)
                data.append(button.rawValue)
                data.append(action.rawValue)
            case let .scroll(dx, dy):
                data.append(3)
                data.append(contentsOf: bigEndian(fixedPoint(dx)))
                data.append(contentsOf: bigEndian(fixedPoint(dy)))
            }
        }
        return data
    }

    /// Throws rather than traps on any malformed input: the bytes come off the
    /// network, so every read is bounds checked.
    public static func decode(_ data: Data) throws -> RemoteInputBatch {
        var reader = ByteReader(data)
        guard try reader.readByte() == batchVersion else {
            throw RemoteProtocolError.invalidMessage
        }
        _ = try reader.readByte() // reserved
        let count = Int(try reader.readUInt16())
        guard count <= maximumEventsPerBatch else {
            throw RemoteProtocolError.invalidMessage
        }
        let timestamp = Int64(bitPattern: try reader.readUInt64())
        var events: [RemoteInputEvent] = []
        events.reserveCapacity(count)
        for _ in 0..<count {
            let kind = try reader.readByte()
            switch kind {
            case 1:
                let dx = try reader.readFixedPoint()
                let dy = try reader.readFixedPoint()
                let buttons = RemoteInputButtons(rawValue: try reader.readByte())
                events.append(.move(dx: dx, dy: dy, buttons: buttons))
            case 2:
                guard let button = RemoteInputButton(rawValue: try reader.readByte()),
                      let action = RemoteInputAction(rawValue: try reader.readByte()) else {
                    throw RemoteProtocolError.invalidMessage
                }
                events.append(.click(button: button, action: action))
            case 3:
                let dx = try reader.readFixedPoint()
                let dy = try reader.readFixedPoint()
                events.append(.scroll(dx: dx, dy: dy))
            default:
                throw RemoteProtocolError.invalidMessage
            }
        }
        return RemoteInputBatch(timestampMilliseconds: timestamp, events: events)
    }

    static func fixedPoint(_ value: Double) -> Int16 {
        Int16(clamping: Int((value * fixedPointScale).rounded()))
    }

    static func fromFixedPoint(_ value: Int16) -> Double {
        Double(value) / fixedPointScale
    }

    private static func bigEndian(_ value: some FixedWidthInteger) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}

/// Bounds checked forward reader for untrusted binary payloads.
private struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.endIndex else { throw RemoteProtocolError.invalidMessage }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = UInt16(try readByte())
        let low = UInt16(try readByte())
        return (high << 8) | low
    }

    mutating func readUInt64() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = (value << 8) | UInt64(try readByte())
        }
        return value
    }

    mutating func readFixedPoint() throws -> Double {
        let high = UInt16(try readByte())
        let low = UInt16(try readByte())
        return RemoteInputBatchCodec.fromFixedPoint(Int16(bitPattern: (high << 8) | low))
    }
}
