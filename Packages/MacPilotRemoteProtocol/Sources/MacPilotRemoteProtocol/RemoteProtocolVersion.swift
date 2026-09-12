import Foundation

/// Version and discovery constants shared by the Mac server and the iPhone app.
public enum RemoteProtocolVersion {
    /// Bumped whenever the wire format changes incompatibly. Peers that send a
    /// different value are rejected with `unsupportedProtocol`.
    public static let current = 1

    /// Bonjour service type used for local-network discovery.
    public static let bonjourServiceType = "_macpilot._tcp"

    /// Preferred TCP port. The server falls back to a dynamic port and keeps
    /// advertising the real value through Bonjour when this one is taken.
    public static let preferredPort: UInt16 = 43847

    /// Upper bound for a single framed message. Both peers refuse larger frames
    /// instead of buffering unbounded data.
    public static let maximumFrameSize = 256 * 1024

    /// Length of the length prefix preceding every frame payload.
    public static let frameHeaderLength = 4
}
