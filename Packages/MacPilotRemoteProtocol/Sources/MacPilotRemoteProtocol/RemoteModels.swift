import Foundation

/// A three-valued boolean. The Mac never fabricates `false` when it cannot
/// determine the real state; it reports `unknown` instead.
public enum RemoteBooleanState: String, Codable, Sendable, Equatable {
    case yes
    case no
    case unknown

    public init(_ value: Bool?) {
        switch value {
        case .some(true): self = .yes
        case .some(false): self = .no
        case .none: self = .unknown
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .yes: return true
        case .no: return false
        case .unknown: return nil
        }
    }
}

/// The Mac state returned with every command response.
public struct MacRemoteState: Codable, Sendable, Equatable {
    public var screenLocked: RemoteBooleanState
    public var canUnlock: RemoteBooleanState
    public var hasCredential: RemoteBooleanState
    public var accessibilityGranted: RemoteBooleanState
    public var displaySleeping: RemoteBooleanState?
    /// Output level in `0...1`, or `nil` when this Mac has no display whose
    /// backlight can be driven.
    ///
    /// `nil` is also what an older Mac build decodes to, because it sends no
    /// such field at all. That is deliberate: the client offers a slider only
    /// when a real value arrives, instead of inferring support from a version
    /// number and then failing on the first drag.
    public var brightness: Double?
    /// Output volume in `0...1`, or `nil` when there is no output device with a
    /// volume control.
    public var volume: Double?
    /// `nil` when the output device has no mute control.
    public var volumeMuted: RemoteBooleanState?

    public init(
        screenLocked: RemoteBooleanState = .unknown,
        canUnlock: RemoteBooleanState = .unknown,
        hasCredential: RemoteBooleanState = .unknown,
        accessibilityGranted: RemoteBooleanState = .unknown,
        displaySleeping: RemoteBooleanState? = nil,
        brightness: Double? = nil,
        volume: Double? = nil,
        volumeMuted: RemoteBooleanState? = nil
    ) {
        self.screenLocked = screenLocked
        self.canUnlock = canUnlock
        self.hasCredential = hasCredential
        self.accessibilityGranted = accessibilityGranted
        self.displaySleeping = displaySleeping
        self.brightness = brightness
        self.volume = volume
        self.volumeMuted = volumeMuted
    }
}

/// Payload for `setBrightness` and `setVolume`.
///
/// The level is normalized to `0...1` so the phone owns the scale it presents;
/// the Mac clamps anything outside that range rather than trusting the peer.
public struct RemoteLevelRequest: Codable, Sendable, Equatable {
    public let value: Double
    /// Volume only. `nil` leaves the mute state exactly as it was, so dragging
    /// the slider never silently un-mutes a deliberately muted Mac.
    public let muted: Bool?

    public init(value: Double, muted: Bool? = nil) {
        self.value = value
        self.muted = muted
    }

    /// `value` restricted to the only range the wire format promises.
    public var clampedValue: Double { min(max(value, 0), 1) }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` for a missing or undecodable payload, which the server reports as
    /// `invalidMessage` instead of guessing a level.
    public static func decoded(from payload: Data?) -> RemoteLevelRequest? {
        guard let payload, !payload.isEmpty else { return nil }
        return try? JSONDecoder().decode(RemoteLevelRequest.self, from: payload)
    }
}

/// Stable, localized-on-the-client error vocabulary. Raw macOS errors never
/// cross the network; the iPhone maps these codes to human readable text.
public enum RemoteErrorCode: String, Codable, Sendable, Equatable, CaseIterable {
    case unauthenticated
    case pairingRequired
    case unsupportedProtocol
    case unsupportedCommand

    case accessibilityPermissionRequired
    case credentialNotConfigured

    case alreadyLocked
    case alreadyUnlocked

    case unlockFailed
    case wakeFailed
    case lockFailed
    case displaySleepFailed
    case commandTimeout
    /// No display on this Mac has a backlight that can be driven.
    case brightnessUnavailable
    /// No output device on this Mac exposes a volume control.
    case volumeUnavailable

    case replayDetected
    case invalidMessage
    case internalError
}

public struct RemoteError: Codable, Sendable, Equatable {
    public let code: RemoteErrorCode
    /// Optional diagnostic detail. Never contains credentials, keys or payloads.
    public let message: String?

    public init(code: RemoteErrorCode, message: String? = nil) {
        self.code = code
        self.message = message
    }
}

public struct RemoteRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let requestID: UUID
    public let command: RemoteCommand
    /// Milliseconds since the Unix epoch, used for freshness checks.
    public let timestamp: Int64
    /// Monotonic per-session counter, used for replay protection.
    public let sequence: UInt64
    public let payload: Data?

    public init(
        version: Int = RemoteProtocolVersion.current,
        requestID: UUID = UUID(),
        command: RemoteCommand,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        sequence: UInt64,
        payload: Data? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.command = command
        self.timestamp = timestamp
        self.sequence = sequence
        self.payload = payload
    }
}

public struct RemoteResponse: Codable, Sendable, Equatable {
    public let version: Int
    public let requestID: UUID
    public let success: Bool
    public let error: RemoteError?
    public let state: MacRemoteState?

    public init(
        version: Int = RemoteProtocolVersion.current,
        requestID: UUID,
        success: Bool,
        error: RemoteError? = nil,
        state: MacRemoteState? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.success = success
        self.error = error
        self.state = state
    }
}

/// Flat handshake envelope. A single optional-heavy struct keeps Codable
/// straightforward and makes the wire format easy to inspect in tests.
public struct RemoteHandshakeMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case clientHello
        case serverHello
        case pairRequest
        case pairResult
        case pairConfirm
        case authRequest
        case authResult
        case failure
    }

    public var kind: Kind
    public var protocolVersion: Int
    public var clientID: UUID?
    public var clientName: String?
    public var deviceID: UUID?
    public var deviceName: String?
    public var paired: Bool?
    public var clientNonce: Data?
    public var serverNonce: Data?
    public var publicKey: Data?
    public var proof: Data?
    public var pairCode: String?
    public var capabilities: [RemoteCapability]?
    public var errorCode: RemoteErrorCode?
    public var errorMessage: String?

    public init(
        kind: Kind,
        protocolVersion: Int = RemoteProtocolVersion.current,
        clientID: UUID? = nil,
        clientName: String? = nil,
        deviceID: UUID? = nil,
        deviceName: String? = nil,
        paired: Bool? = nil,
        clientNonce: Data? = nil,
        serverNonce: Data? = nil,
        publicKey: Data? = nil,
        proof: Data? = nil,
        pairCode: String? = nil,
        capabilities: [RemoteCapability]? = nil,
        errorCode: RemoteErrorCode? = nil,
        errorMessage: String? = nil
    ) {
        self.kind = kind
        self.protocolVersion = protocolVersion
        self.clientID = clientID
        self.clientName = clientName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.paired = paired
        self.clientNonce = clientNonce
        self.serverNonce = serverNonce
        self.publicKey = publicKey
        self.proof = proof
        self.pairCode = pairCode
        self.capabilities = capabilities
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}
