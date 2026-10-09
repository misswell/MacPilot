import Foundation

enum BLEIdentityAliasSource: String, Codable, Equatable {
    case authenticatedBLE
}

struct BLEIdentityAlias: Codable, Equatable {
    static let authenticatedSource = BLEIdentityAliasSource.authenticatedBLE.rawValue

    var uuid: String
    var learnedAt: Date
    var lastSeenAt: Date
    var source: String
    fileprivate var hasValidRequiredFields: Bool

    private enum CodingKeys: String, CodingKey {
        case uuid
        case learnedAt
        case lastSeenAt
        case source
    }

    init(
        uuid: String,
        learnedAt: Date,
        lastSeenAt: Date,
        source: String = authenticatedSource
    ) {
        self.uuid = uuid
        self.learnedAt = learnedAt
        self.lastSeenAt = lastSeenAt
        self.source = source
        hasValidRequiredFields = true
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedUUID = try? container.decodeIfPresent(String.self, forKey: .uuid)
        let decodedLearnedAt = try? container.decodeIfPresent(Date.self, forKey: .learnedAt)
        let decodedLastSeenAt = try? container.decodeIfPresent(Date.self, forKey: .lastSeenAt)

        uuid = decodedUUID ?? ""
        learnedAt = decodedLearnedAt ?? .distantPast
        lastSeenAt = decodedLastSeenAt ?? .distantPast
        source = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? ""
        hasValidRequiredFields = decodedUUID != nil && decodedLearnedAt != nil && decodedLastSeenAt != nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(learnedAt, forKey: .learnedAt)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(source, forKey: .source)
    }
}

struct BLEIdentityBinding: Codable, Equatable {
    var primaryUUID: String
    var clientID: String
    var keyFingerprint: String
    var aliases: [BLEIdentityAlias]

    private enum CodingKeys: String, CodingKey {
        case primaryUUID
        case clientID
        case keyFingerprint
        case aliases
    }

    init(
        primaryUUID: String,
        clientID: String,
        keyFingerprint: String,
        aliases: [BLEIdentityAlias] = []
    ) {
        self.primaryUUID = primaryUUID
        self.clientID = clientID
        self.keyFingerprint = keyFingerprint
        self.aliases = aliases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryUUID = (try? container.decodeIfPresent(String.self, forKey: .primaryUUID)) ?? ""
        clientID = (try? container.decodeIfPresent(String.self, forKey: .clientID)) ?? ""
        keyFingerprint = (try? container.decodeIfPresent(String.self, forKey: .keyFingerprint)) ?? ""
        aliases = (try? container.decodeIfPresent([BLEIdentityAlias].self, forKey: .aliases)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(primaryUUID, forKey: .primaryUUID)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(keyFingerprint, forKey: .keyFingerprint)
        try container.encode(aliases, forKey: .aliases)
    }
}

/// Maps a user-selected BLE device to one authenticated remote-control identity.
/// UUID aliases only identify alternate advertisements for that same logical
/// device; they do not imply presence or proximity.
struct BLEIdentityRegistry: Codable, Equatable {
    static let maximumAliasesPerBinding = 8
    static let repeatedObservationPersistenceInterval: TimeInterval = 60

    var bindings: [BLEIdentityBinding]

    private enum CodingKeys: String, CodingKey {
        case bindings
    }

    init(bindings: [BLEIdentityBinding] = []) {
        self.bindings = bindings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bindings = (try? container.decodeIfPresent([BLEIdentityBinding].self, forKey: .bindings)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bindings, forKey: .bindings)
    }

    /// Keeps only unambiguous identities for the currently configured BLE
    /// primaries. Input order resolves conflicts: the first valid binding owns
    /// each primary/client, and the first binding owns any duplicate alias.
    mutating func normalize(primaryUUIDs: [UUID]) {
        let configuredPrimaries = Set(primaryUUIDs)
        var claimedPrimaries = Set<UUID>()
        var claimedClients = Set<String>()
        var claimedAliases = Set<UUID>()
        var normalizedBindings: [BLEIdentityBinding] = []

        for var binding in bindings {
            guard let primaryUUID = Self.uuid(binding.primaryUUID),
                  configuredPrimaries.contains(primaryUUID),
                  !claimedPrimaries.contains(primaryUUID),
                  !binding.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !binding.keyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !claimedClients.contains(binding.clientID)
            else {
                continue
            }

            var aliasesByUUID: [UUID: BLEIdentityAlias] = [:]
            for alias in binding.aliases {
                guard alias.hasValidRequiredFields,
                      alias.source == BLEIdentityAlias.authenticatedSource,
                      let aliasUUID = Self.uuid(alias.uuid),
                      aliasUUID != primaryUUID,
                      !configuredPrimaries.contains(aliasUUID),
                      alias.learnedAt.timeIntervalSince1970.isFinite,
                      alias.lastSeenAt.timeIntervalSince1970.isFinite,
                      alias.lastSeenAt >= alias.learnedAt
                else {
                    continue
                }

                if let previous = aliasesByUUID[aliasUUID] {
                    if alias.lastSeenAt > previous.lastSeenAt
                        || (alias.lastSeenAt == previous.lastSeenAt && alias.learnedAt > previous.learnedAt) {
                        aliasesByUUID[aliasUUID] = alias
                    }
                } else {
                    aliasesByUUID[aliasUUID] = alias
                }
            }

            let orderedAliases = aliasesByUUID.values.sorted { lhs, rhs in
                if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
                if lhs.learnedAt != rhs.learnedAt { return lhs.learnedAt > rhs.learnedAt }
                return lhs.uuid < rhs.uuid
            }
            var retainedAliases: [BLEIdentityAlias] = []
            for alias in orderedAliases where retainedAliases.count < Self.maximumAliasesPerBinding {
                guard let aliasUUID = Self.uuid(alias.uuid), !claimedAliases.contains(aliasUUID) else { continue }
                retainedAliases.append(alias)
                claimedAliases.insert(aliasUUID)
            }

            binding.primaryUUID = primaryUUID.uuidString
            binding.aliases = retainedAliases
            normalizedBindings.append(binding)
            claimedPrimaries.insert(primaryUUID)
            claimedClients.insert(binding.clientID)
        }

        bindings = normalizedBindings
    }

    /// A remote-control identity can own only one logical BLE device at a time.
    /// Rebinding either the selected BLE device or the client clears its old
    /// aliases so identities cannot silently migrate across devices.
    mutating func bind(primaryUUID: UUID, clientID: String, keyFingerprint: String) {
        bindings.removeAll {
            $0.clientID == clientID || Self.uuid($0.primaryUUID) == primaryUUID
        }
        bindings.append(BLEIdentityBinding(
            primaryUUID: primaryUUID.uuidString,
            clientID: clientID,
            keyFingerprint: keyFingerprint
        ))
    }

    mutating func unbind(primaryUUID: UUID) {
        bindings.removeAll { Self.uuid($0.primaryUUID) == primaryUUID }
    }

    /// Drops bindings for clients that were unpaired or whose pairing key
    /// changed. A client ID alone is not sufficient to keep learned UUIDs.
    mutating func reconcile(identities: [String: String]) {
        bindings.removeAll { identities[$0.clientID] != $0.keyFingerprint }
    }

    /// Records a UUID only when the authenticated client and current pairing
    /// key match the explicit binding. Returns true only when persisted state
    /// changes, allowing frequent observations to avoid config write churn.
    @discardableResult
    mutating func learn(
        clientID: String,
        keyFingerprint: String,
        peripheralUUID: UUID,
        now: Date,
        reservedPrimaryUUIDs: [UUID] = []
    ) -> Bool {
        let matchingIndices = bindings.indices.filter { bindings[$0].clientID == clientID }
        guard matchingIndices.count == 1,
              let index = matchingIndices.first,
              bindings[index].keyFingerprint == keyFingerprint,
              let boundPrimary = Self.uuid(bindings[index].primaryUUID),
              boundPrimary != peripheralUUID
        else {
            return false
        }

        let allPrimaryUUIDs = Set(bindings.compactMap { Self.uuid($0.primaryUUID) })
            .union(reservedPrimaryUUIDs)
        guard !allPrimaryUUIDs.contains(peripheralUUID) else { return false }

        for otherIndex in bindings.indices where otherIndex != index {
            guard !bindings[otherIndex].aliases.contains(where: {
                Self.uuid($0.uuid) == peripheralUUID
            }) else {
                return false
            }
        }

        if let aliasIndex = bindings[index].aliases.firstIndex(where: {
            Self.uuid($0.uuid) == peripheralUUID
        }) {
            let previousLastSeen = bindings[index].aliases[aliasIndex].lastSeenAt
            guard now.timeIntervalSince(previousLastSeen) >= Self.repeatedObservationPersistenceInterval else {
                return false
            }
            bindings[index].aliases[aliasIndex].uuid = peripheralUUID.uuidString
            bindings[index].aliases[aliasIndex].lastSeenAt = now
            return true
        }

        bindings[index].aliases.append(BLEIdentityAlias(
            uuid: peripheralUUID.uuidString,
            learnedAt: now,
            lastSeenAt: now
        ))
        if bindings[index].aliases.count > Self.maximumAliasesPerBinding {
            let aliases = bindings[index].aliases
            let oldestIndex = aliases.indices.min { lhs, rhs in
                let left = aliases[lhs]
                let right = aliases[rhs]
                if left.lastSeenAt != right.lastSeenAt { return left.lastSeenAt < right.lastSeenAt }
                if left.learnedAt != right.learnedAt { return left.learnedAt < right.learnedAt }
                return left.uuid < right.uuid
            }
            if let oldestIndex { bindings[index].aliases.remove(at: oldestIndex) }
        }
        return true
    }

    /// Returns the selected primary UUID followed by valid, unique aliases.
    func uuids(for primaryUUID: UUID) -> [UUID] {
        var result = [primaryUUID]
        guard let binding = bindings.first(where: { Self.uuid($0.primaryUUID) == primaryUUID }) else {
            return result
        }
        for alias in binding.aliases {
            guard let uuid = Self.uuid(alias.uuid), !result.contains(uuid) else { continue }
            result.append(uuid)
        }
        return result
    }

    /// Evaluates each primary device as one logical device: its selected UUID
    /// and all learned aliases are alternatives, while different primaries
    /// remain separate entries for the existing any/all relation policy.
    func logicalStates(
        primaryUUIDs: [UUID],
        matching: (UUID) -> Bool
    ) -> [Bool] {
        primaryUUIDs.map { primaryUUID in
            uuids(for: primaryUUID).contains(where: matching)
        }
    }

    private static func uuid(_ value: String) -> UUID? {
        UUID(uuidString: value)
    }
}
