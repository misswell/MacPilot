import Foundation

/// Bonjour TXT record fields plus the decoded service description.
///
/// The shared package deliberately avoids `Network.framework`, so the record is
/// modelled as a plain `[String: String]` that each platform converts to and
/// from `NWTXTRecord`.
public struct RemoteServiceInfo: Sendable, Equatable {
    public static let idKey = "id"
    public static let nameKey = "name"
    public static let protocolKey = "proto"
    public static let versionKey = "version"
    public static let capabilitiesKey = "caps"

    public let deviceID: UUID
    public let name: String
    public let protocolVersion: Int
    public let version: String
    public let capabilities: Set<RemoteCapability>

    public init(
        deviceID: UUID,
        name: String,
        protocolVersion: Int = RemoteProtocolVersion.current,
        version: String,
        capabilities: Set<RemoteCapability>
    ) {
        self.deviceID = deviceID
        self.name = name
        self.protocolVersion = protocolVersion
        self.version = version
        self.capabilities = capabilities
    }

    /// TXT record for the current protocol version. Secrets never go here.
    public func txtRecord() -> [String: String] {
        [
            Self.idKey: deviceID.uuidString,
            Self.nameKey: name,
            Self.protocolKey: String(protocolVersion),
            Self.versionKey: version,
            Self.capabilitiesKey: capabilities.map(\.rawValue).sorted().joined(separator: ",")
        ]
    }

    public init?(txtRecord: [String: String]) {
        guard let idString = txtRecord[Self.idKey],
              let deviceID = UUID(uuidString: idString),
              let name = txtRecord[Self.nameKey], !name.isEmpty else {
            return nil
        }
        self.deviceID = deviceID
        self.name = name
        self.protocolVersion = Int(txtRecord[Self.protocolKey] ?? "") ?? RemoteProtocolVersion.current
        self.version = txtRecord[Self.versionKey] ?? ""
        let rawCapabilities = (txtRecord[Self.capabilitiesKey] ?? "")
            .split(separator: ",")
            .map(String.init)
            .compactMap(RemoteCapability.init(rawValue:))
        self.capabilities = Set(rawCapabilities)
    }
}
