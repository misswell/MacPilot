import Foundation
import MacPilotRemoteProtocol
import Network

/// A MacPilot instance seen on the local network.
struct DiscoveredMac: Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoint: NWEndpoint
    var serviceName: String?
    var version: String
    var protocolVersion: Int
    var capabilities: Set<RemoteCapability>

    var canUnlock: Bool { capabilities.contains(.unlock) }
}

/// One Mac this iPhone has paired with. The pairing key itself lives in the
/// Keychain and is never part of this model.
struct PairedMac: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var lastServiceName: String?
    var lastHost: String?
    var lastPort: UInt16?
    var lastConnectedAt: Date?

    var deviceID: UUID? { UUID(uuidString: id) }

    /// Endpoint remembered from the previous successful connection, used for the
    /// fast path when the app opens.
    var rememberedEndpoint: NWEndpoint? {
        guard let lastHost, let lastPort, let port = NWEndpoint.Port(rawValue: lastPort) else { return nil }
        return .hostPort(host: NWEndpoint.Host(lastHost), port: port)
    }
}

/// Phase 7 instrumentation. Every value is measured on device; nothing is sent
/// anywhere.
struct RemoteMetrics: Equatable {
    var discoveryLatencyMs: Int?
    var connectLatencyMs: Int?
    var handshakeLatencyMs: Int?
    var commandRTTMs: Int?
    var executionLatencyMs: Int?
}

/// Unified connection state. The UI only ever switches on this value.
enum RemoteConnectionState: Equatable {
    case idle
    case discovering
    case connecting
    case pairing
    case authenticating
    case connected
    case reconnecting
    case failed(String)

    var isConnected: Bool { self == .connected }

    var isBusy: Bool {
        switch self {
        case .connecting, .pairing, .authenticating, .reconnecting, .discovering: return true
        case .idle, .connected, .failed: return false
        }
    }

    var titleKey: String {
        switch self {
        case .idle: return "stateIdle"
        case .discovering: return "stateDiscovering"
        case .connecting: return "stateConnecting"
        case .pairing: return "statePairing"
        case .authenticating: return "stateAuthenticating"
        case .connected: return "stateConnected"
        case .reconnecting: return "stateReconnecting"
        case .failed: return "stateFailed"
        }
    }
}

enum RemoteConnectionError: Error, Equatable {
    case unsupportedProtocol
    case pairingWindowClosed
    case invalidPairCode
    case authenticationFailed
    case notPaired
    case network(String)
    case server(RemoteErrorCode)

    var messageKey: String {
        switch self {
        case .unsupportedProtocol: return "errorUnsupportedProtocol"
        case .pairingWindowClosed: return "errorPairingWindowClosed"
        case .invalidPairCode: return "errorInvalidPairCode"
        case .authenticationFailed: return "errorAuthenticationFailed"
        case .notPaired: return "errorNotPaired"
        case .network: return "errorNetwork"
        case .server(let code): return code.messageKey
        }
    }
}

extension RemoteErrorCode {
    /// Human readable text key. The Mac never sends raw system errors, so the
    /// client owns the wording.
    var messageKey: String {
        switch self {
        case .unauthenticated: return "errorUnauthenticated"
        case .pairingRequired: return "errorPairingRequired"
        case .unsupportedProtocol: return "errorUnsupportedProtocol"
        case .unsupportedCommand: return "errorUnsupportedCommand"
        case .accessibilityPermissionRequired: return "errorAccessibility"
        case .credentialNotConfigured: return "errorCredential"
        case .alreadyLocked: return "errorAlreadyLocked"
        case .alreadyUnlocked: return "errorAlreadyUnlocked"
        case .unlockFailed: return "errorUnlockFailed"
        case .wakeFailed: return "errorWakeFailed"
        case .lockFailed: return "errorLockFailed"
        case .displaySleepFailed: return "errorDisplaySleepFailed"
        case .commandTimeout: return "errorTimeout"
        case .replayDetected: return "errorNetwork"
        case .invalidMessage: return "errorNetwork"
        case .internalError: return "errorInternal"
        }
    }
}
