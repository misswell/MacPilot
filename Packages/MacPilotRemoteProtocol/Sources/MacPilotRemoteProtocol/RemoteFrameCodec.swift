import Foundation

/// Errors surfaced while framing, decoding or authenticating remote messages.
public enum RemoteProtocolError: Error, Equatable, Sendable {
    case malformedFrame
    case oversizedFrame
    case unsupportedProtocol(Int)
    case unsupportedCommand(String)
    case invalidMessage
    case decryptionFailed
    case replayDetected
    case authenticationFailed
    case invalidPairCode
    case notPaired
    case internalError

    /// Wire level error code the peer is allowed to see.
    public var code: RemoteErrorCode {
        switch self {
        case .malformedFrame, .invalidMessage:
            return .invalidMessage
        case .oversizedFrame:
            return .invalidMessage
        case .unsupportedProtocol:
            return .unsupportedProtocol
        case .unsupportedCommand:
            return .unsupportedCommand
        case .decryptionFailed:
            return .unauthenticated
        case .replayDetected:
            return .replayDetected
        case .authenticationFailed:
            return .unauthenticated
        case .invalidPairCode:
            return .pairingRequired
        case .notPaired:
            return .pairingRequired
        case .internalError:
            return .internalError
        }
    }
}

/// 4-byte big-endian length prefix framing, optionally carrying a ChaChaPoly
/// sealed payload.
///
/// Frame payload layout:
/// - plaintext frame: `0x01 || JSON`
/// - secure frame:    `0x02 || UInt64 sequence (big endian) || sealed box`
public enum RemoteFrameCodec {
    public static let plaintextTag: UInt8 = 0x01
    public static let secureTag: UInt8 = 0x02

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    // MARK: - Framing

    /// Wraps a payload with its 4-byte length prefix.
    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(payload)
        return data
    }

    /// Pulls every complete frame out of `buffer`, leaving any partial frame in
    /// place so the caller can wait for more bytes.
    ///
    /// - Throws: `.oversizedFrame` when the declared length exceeds
    ///   `RemoteProtocolVersion.maximumFrameSize`.
    public static func extractFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        while buffer.count >= RemoteProtocolVersion.frameHeaderLength {
            // Read the header through a relative view: `Data` produced by
            // `dropFirst` keeps its original indices, so absolute index
            // arithmetic on it would trap.
            let length = buffer.withUnsafeBytes { raw -> UInt32 in
                var value: UInt32 = 0
                for byte in raw.prefix(RemoteProtocolVersion.frameHeaderLength) {
                    value = (value << 8) | UInt32(byte)
                }
                return value
            }
            guard length <= UInt32(RemoteProtocolVersion.maximumFrameSize) else {
                throw RemoteProtocolError.oversizedFrame
            }
            let total = RemoteProtocolVersion.frameHeaderLength + Int(length)
            guard buffer.count >= total else { break }
            // `Data(...)` rebases the slice back to index 0.
            frames.append(Data(buffer.dropFirst(RemoteProtocolVersion.frameHeaderLength).prefix(Int(length))))
            buffer = Data(buffer.dropFirst(total))
        }
        return frames
    }

    // MARK: - Plaintext

    public static func encodePlain<T: Encodable>(_ value: T) throws -> Data {
        let json: Data
        do {
            json = try encoder.encode(value)
        } catch {
            throw RemoteProtocolError.invalidMessage
        }
        var payload = Data([plaintextTag])
        payload.append(json)
        return frame(payload)
    }

    public static func decodePlain<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        guard payload.first == plaintextTag else { throw RemoteProtocolError.malformedFrame }
        let json = payload.dropFirst()
        do {
            return try decoder.decode(type, from: Data(json))
        } catch {
            throw RemoteProtocolError.invalidMessage
        }
    }

    // MARK: - Secure

    public static func encodeSecure<T: Encodable>(
        _ value: T,
        key: RemoteSessionKey,
        sequence: UInt64
    ) throws -> Data {
        let json: Data
        do {
            json = try encoder.encode(value)
        } catch {
            throw RemoteProtocolError.invalidMessage
        }
        let sealed = try RemoteCrypto.seal(json, key: key, sequence: sequence)
        var payload = Data([secureTag])
        payload.append(RemoteCrypto.bigEndianBytes(sequence))
        payload.append(sealed)
        return frame(payload)
    }

    /// Returns the decoded JSON body. The caller is responsible for replay
    /// validation: the sequence is reported back rather than consumed here.
    public static func decodeSecure(
        _ payload: Data,
        key: RemoteSessionKey
    ) throws -> (sequence: UInt64, plaintext: Data) {
        guard payload.first == secureTag else { throw RemoteProtocolError.malformedFrame }
        let body = payload.dropFirst()
        guard body.count > 8 else { throw RemoteProtocolError.malformedFrame }
        let sequence = RemoteCrypto.sequence(fromBigEndian: Data(body.prefix(8)))
        let box = Data(body.dropFirst(8))
        let plaintext = try RemoteCrypto.open(box, key: key, sequence: sequence)
        return (sequence, plaintext)
    }

    public static func decodeSecure<T: Decodable>(
        _ type: T.Type,
        from payload: Data,
        key: RemoteSessionKey
    ) throws -> (sequence: UInt64, value: T) {
        let (sequence, plaintext) = try decodeSecure(payload, key: key)
        do {
            return (sequence, try decoder.decode(type, from: plaintext))
        } catch {
            throw RemoteProtocolError.invalidMessage
        }
    }
}
