import Foundation
import Testing

@testable import MacPilot

struct BLEIdentityRegistryTests {
    @Test func learningRequiresTheBoundClientAndCurrentKeyFingerprint() {
        let primary = uuid("00000000-0000-0000-0000-000000000001")
        let candidate = uuid("00000000-0000-0000-0000-000000000002")
        var registry = BLEIdentityRegistry()
        registry.bind(primaryUUID: primary, clientID: "phone", keyFingerprint: "current-key")

        let unboundClientLearned = registry.learn(
            clientID: "another-phone",
            keyFingerprint: "current-key",
            peripheralUUID: candidate,
            now: instant(100)
        )
        #expect(!unboundClientLearned)
        let staleKeyLearned = registry.learn(
            clientID: "phone",
            keyFingerprint: "old-key",
            peripheralUUID: candidate,
            now: instant(100)
        )
        #expect(!staleKeyLearned)
        #expect(registry.bindings[0].aliases.isEmpty)
    }

    @Test func learningRejectsPrimaryAndAliasUUIDCollisions() {
        let primaryA = uuid("00000000-0000-0000-0000-000000000011")
        let primaryB = uuid("00000000-0000-0000-0000-000000000012")
        let sharedAlias = uuid("00000000-0000-0000-0000-000000000013")
        let reserved = uuid("00000000-0000-0000-0000-000000000014")
        var registry = BLEIdentityRegistry()
        registry.bind(primaryUUID: primaryA, clientID: "phone-a", keyFingerprint: "key-a")
        registry.bind(primaryUUID: primaryB, clientID: "phone-b", keyFingerprint: "key-b")

        let primaryCollisionLearned = registry.learn(
            clientID: "phone-a", keyFingerprint: "key-a", peripheralUUID: primaryB,
            now: instant(100)
        )
        #expect(!primaryCollisionLearned)
        let firstAliasLearned = registry.learn(
            clientID: "phone-b", keyFingerprint: "key-b", peripheralUUID: sharedAlias,
            now: instant(100)
        )
        #expect(firstAliasLearned)
        let crossBindingAliasLearned = registry.learn(
            clientID: "phone-a", keyFingerprint: "key-a", peripheralUUID: sharedAlias,
            now: instant(101)
        )
        #expect(!crossBindingAliasLearned)
        let reservedPrimaryLearned = registry.learn(
            clientID: "phone-a", keyFingerprint: "key-a", peripheralUUID: reserved,
            now: instant(102), reservedPrimaryUUIDs: [reserved]
        )
        #expect(!reservedPrimaryLearned)
        #expect(registry.bindings.first { $0.clientID == "phone-a" }?.aliases.isEmpty == true)
    }

    @Test func repeatedObservationsPersistAtMostOncePerMinute() throws {
        let primary = uuid("00000000-0000-0000-0000-000000000021")
        let aliasUUID = uuid("00000000-0000-0000-0000-000000000022")
        var registry = BLEIdentityRegistry()
        registry.bind(primaryUUID: primary, clientID: "phone", keyFingerprint: "key")
        let learnedAt = instant(1_000)

        let firstObservationChangedState = registry.learn(
            clientID: "phone", keyFingerprint: "key", peripheralUUID: aliasUUID, now: learnedAt
        )
        #expect(firstObservationChangedState)
        let repeatedObservationChangedState = registry.learn(
            clientID: "phone", keyFingerprint: "key", peripheralUUID: aliasUUID,
            now: learnedAt.addingTimeInterval(59)
        )
        #expect(!repeatedObservationChangedState)
        var alias = try #require(registry.bindings.first?.aliases.first)
        #expect(alias.learnedAt == learnedAt)
        #expect(alias.lastSeenAt == learnedAt)

        let minuteObservationChangedState = registry.learn(
            clientID: "phone", keyFingerprint: "key", peripheralUUID: aliasUUID,
            now: learnedAt.addingTimeInterval(60)
        )
        #expect(minuteObservationChangedState)
        alias = try #require(registry.bindings.first?.aliases.first)
        #expect(alias.learnedAt == learnedAt)
        #expect(alias.lastSeenAt == learnedAt.addingTimeInterval(60))
        #expect(alias.source == BLEIdentityAlias.authenticatedSource)
    }

    @Test func addingTheNinthAliasEvictsTheLeastRecentlySeenAlias() throws {
        let primary = uuid("00000000-0000-0000-0000-000000000031")
        var registry = BLEIdentityRegistry()
        registry.bind(primaryUUID: primary, clientID: "phone", keyFingerprint: "key")
        let observedUUIDs = (1...9).map { value in
            uuid(String(format: "00000000-0000-0000-0000-%012d", value + 100))
        }

        for (offset, aliasUUID) in observedUUIDs.enumerated() {
            let aliasLearned = registry.learn(
                clientID: "phone", keyFingerprint: "key", peripheralUUID: aliasUUID,
                now: instant(Double(offset * 10))
            )
            #expect(aliasLearned)
        }

        let aliases = try #require(registry.bindings.first?.aliases)
        #expect(aliases.count == BLEIdentityRegistry.maximumAliasesPerBinding)
        #expect(!aliases.contains { $0.uuid == observedUUIDs[0].uuidString })
        #expect(aliases.contains { $0.uuid == observedUUIDs[1].uuidString })
        #expect(registry.uuids(for: primary).count == BLEIdentityRegistry.maximumAliasesPerBinding + 1)
    }

    @Test func rebindingAndPairingRevocationDiscardLearnedAliases() throws {
        let primaryA = uuid("00000000-0000-0000-0000-000000000041")
        let primaryB = uuid("00000000-0000-0000-0000-000000000042")
        let aliasUUID = uuid("00000000-0000-0000-0000-000000000043")
        var registry = BLEIdentityRegistry()
        registry.bind(primaryUUID: primaryA, clientID: "old-client", keyFingerprint: "old-key")
        let oldClientLearned = registry.learn(
            clientID: "old-client", keyFingerprint: "old-key", peripheralUUID: aliasUUID,
            now: instant(100)
        )
        #expect(oldClientLearned)

        registry.bind(primaryUUID: primaryA, clientID: "new-client", keyFingerprint: "new-key")
        #expect(registry.bindings.count == 1)
        #expect(registry.bindings[0].aliases.isEmpty)
        let revokedClientLearned = registry.learn(
            clientID: "old-client", keyFingerprint: "old-key", peripheralUUID: aliasUUID,
            now: instant(101)
        )
        #expect(!revokedClientLearned)

        // A client can be bound to only one primary, so moving it clears the
        // previous association and starts with no learned UUID aliases.
        let newClientLearned = registry.learn(
            clientID: "new-client", keyFingerprint: "new-key", peripheralUUID: aliasUUID,
            now: instant(102)
        )
        #expect(newClientLearned)
        registry.bind(primaryUUID: primaryB, clientID: "new-client", keyFingerprint: "new-key")
        #expect(registry.bindings.count == 1)
        #expect(registry.bindings[0].primaryUUID == primaryB.uuidString)
        #expect(registry.bindings[0].aliases.isEmpty)

        registry.reconcile(identities: ["new-client": "rotated-key"])
        #expect(registry.bindings.isEmpty)

        registry.bind(primaryUUID: primaryA, clientID: "client-to-unpair", keyFingerprint: "key")
        registry.reconcile(identities: [:])
        #expect(registry.bindings.isEmpty)

        registry.bind(primaryUUID: primaryA, clientID: "client-to-unbind", keyFingerprint: "key")
        registry.unbind(primaryUUID: primaryA)
        #expect(registry.bindings.first(where: { $0.clientID == "client-to-unbind" }) == nil)
    }

    @Test func aliasesStayGroupedWithTheirPrimaryDevice() {
        let primaryA = uuid("00000000-0000-0000-0000-000000000051")
        let primaryB = uuid("00000000-0000-0000-0000-000000000052")
        let aliasA = uuid("00000000-0000-0000-0000-000000000053")
        let aliasB = uuid("00000000-0000-0000-0000-000000000054")
        var registry = BLEIdentityRegistry()
        registry.bind(primaryUUID: primaryA, clientID: "phone-a", keyFingerprint: "key-a")
        registry.bind(primaryUUID: primaryB, clientID: "phone-b", keyFingerprint: "key-b")
        let aliasALearned = registry.learn(
            clientID: "phone-a", keyFingerprint: "key-a", peripheralUUID: aliasA, now: instant(100)
        )
        #expect(aliasALearned)
        let aliasBLearned = registry.learn(
            clientID: "phone-b", keyFingerprint: "key-b", peripheralUUID: aliasB, now: instant(100)
        )
        #expect(aliasBLearned)

        let states = registry.logicalStates(primaryUUIDs: [primaryA, primaryB]) { $0 == aliasA }
        #expect(states == [true, false])
        let secondStates = registry.logicalStates(primaryUUIDs: [primaryA, primaryB], matching: { $0 == aliasB })
        #expect(secondStates == [false, true])
    }

    @Test func normalizeKeepsOnlyConfiguredUnambiguousBindingsAndAliases() {
        let primaryA = uuid("00000000-0000-0000-0000-000000000071")
        let primaryB = uuid("00000000-0000-0000-0000-000000000072")
        let aliasA = uuid("00000000-0000-0000-0000-000000000073")
        let invalidSourceAlias = uuid("00000000-0000-0000-0000-000000000074")
        let reversedDateAlias = uuid("00000000-0000-0000-0000-000000000075")
        let outsidePrimary = uuid("00000000-0000-0000-0000-000000000076")
        let additionalAliases = (1...8).map { value in
            uuid(String(format: "00000000-0000-0000-0000-%012d", value + 200))
        }
        let baseDate = instant(100)
        let firstBinding = BLEIdentityBinding(
            primaryUUID: primaryA.uuidString,
            clientID: "client-a",
            keyFingerprint: "key-a",
            aliases: [
                BLEIdentityAlias(uuid: aliasA.uuidString, learnedAt: baseDate, lastSeenAt: instant(200)),
                BLEIdentityAlias(uuid: aliasA.uuidString.lowercased(), learnedAt: baseDate, lastSeenAt: instant(150)),
                BLEIdentityAlias(uuid: invalidSourceAlias.uuidString, learnedAt: baseDate,
                                 lastSeenAt: instant(190), source: "unverified"),
                BLEIdentityAlias(uuid: reversedDateAlias.uuidString, learnedAt: instant(200), lastSeenAt: baseDate),
                BLEIdentityAlias(uuid: "not-a-uuid", learnedAt: baseDate, lastSeenAt: instant(190)),
                BLEIdentityAlias(uuid: primaryB.uuidString, learnedAt: baseDate, lastSeenAt: instant(190))
            ] + additionalAliases.enumerated().map { offset, value in
                BLEIdentityAlias(uuid: value.uuidString, learnedAt: baseDate,
                                 lastSeenAt: instant(Double(101 + offset)))
            }
        )
        var registry = BLEIdentityRegistry(bindings: [
            firstBinding,
            BLEIdentityBinding(primaryUUID: primaryA.uuidString, clientID: "other-client", keyFingerprint: "key"),
            BLEIdentityBinding(primaryUUID: primaryB.uuidString, clientID: "client-a", keyFingerprint: "duplicate-client"),
            BLEIdentityBinding(
                primaryUUID: primaryB.uuidString,
                clientID: "client-b",
                keyFingerprint: "key-b",
                aliases: [BLEIdentityAlias(uuid: aliasA.uuidString, learnedAt: baseDate, lastSeenAt: instant(200))]
            ),
            BLEIdentityBinding(primaryUUID: outsidePrimary.uuidString, clientID: "outside", keyFingerprint: "key")
        ])

        registry.normalize(primaryUUIDs: [primaryA, primaryB, primaryA])

        #expect(registry.bindings.map(\.primaryUUID) == [primaryA.uuidString, primaryB.uuidString])
        #expect(registry.bindings.map(\.clientID) == ["client-a", "client-b"])
        let aliasesA = registry.bindings[0].aliases
        #expect(aliasesA.count == BLEIdentityRegistry.maximumAliasesPerBinding)
        #expect(aliasesA.contains { $0.uuid == aliasA.uuidString })
        #expect(!aliasesA.contains { $0.uuid == additionalAliases[0].uuidString })
        #expect(aliasesA.contains { $0.uuid == additionalAliases[1].uuidString })
        #expect(aliasesA.contains { $0.uuid == additionalAliases[7].uuidString })
        #expect(!aliasesA.contains { $0.uuid == invalidSourceAlias.uuidString })
        #expect(!aliasesA.contains { $0.uuid == reversedDateAlias.uuidString })
        #expect(!aliasesA.contains { $0.uuid == primaryB.uuidString })
        #expect(!aliasesA.contains { $0.uuid == "not-a-uuid" })
        #expect(registry.bindings[1].aliases.isEmpty)
    }

    @Test func partiallyWrittenRegistryDecodesWithDefaultsAndCanBeNormalized() throws {
        let primary = uuid("00000000-0000-0000-0000-000000000081")
        let badSourceAlias = uuid("00000000-0000-0000-0000-000000000082")
        let missingDateAlias = uuid("00000000-0000-0000-0000-000000000083")
        let json = """
        {
          "bindings": [
            {
              "primaryUUID": "\(primary.uuidString)",
              "clientID": "client",
              "keyFingerprint": "fingerprint",
              "aliases": [
                {"uuid": "\(badSourceAlias.uuidString)", "learnedAt": 0, "lastSeenAt": 1, "source": "unknown"},
                {"uuid": "\(missingDateAlias.uuidString)", "source": "authenticatedBLE"}
              ]
            },
            {"clientID": "incomplete"}
          ]
        }
        """
        var registry = try JSONDecoder().decode(BLEIdentityRegistry.self, from: Data(json.utf8))
        #expect(registry.bindings.count == 2)

        registry.normalize(primaryUUIDs: [primary])

        #expect(registry.bindings.count == 1)
        #expect(registry.bindings[0].aliases.isEmpty)
    }

    @Test func identityRegistryRoundTripsInsideBLESettings() throws {
        let primary = uuid("00000000-0000-0000-0000-000000000091")
        let aliasUUID = uuid("00000000-0000-0000-0000-000000000092")
        var settings = BLEUnlockSettings()
        settings.identityRegistry.bind(primaryUUID: primary, clientID: "phone", keyFingerprint: "fingerprint")
        let learned = settings.identityRegistry.learn(
            clientID: "phone", keyFingerprint: "fingerprint", peripheralUUID: aliasUUID, now: instant(100)
        )
        #expect(learned)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BLEUnlockSettings.self, from: data)
        #expect(decoded.identityRegistry == settings.identityRegistry)
        #expect(decoded.identityRegistry.uuids(for: primary) == [primary, aliasUUID])
    }

    @Test func oldBLESettingsDecodeWithAnEmptyRegistryAndKeepHistoricalKeys() throws {
        let oldJSON = """
        {
          "isEnabled": true,
          "monitoredDeviceUUID": "00000000-0000-0000-0000-000000000061",
          "monitoredDeviceName": "Old phone",
          "deviceRelation": "all",
          "lockRSSI": -82,
          "unlockRSSI": -59
        }
        """
        let settings = try JSONDecoder().decode(BLEUnlockSettings.self, from: Data(oldJSON.utf8))
        #expect(settings.isEnabled)
        #expect(settings.monitoredDeviceName == "Old phone")
        #expect(settings.deviceRelation == .all)
        #expect(settings.identityRegistry.bindings.isEmpty)

        var settingsWithEveryStoredField = settings
        settingsWithEveryStoredField.secondaryMonitoredDeviceUUID = "00000000-0000-0000-0000-000000000062"
        settingsWithEveryStoredField.secondaryMonitoredDeviceName = "Second phone"
        let encoded = try JSONEncoder().encode(settingsWithEveryStoredField)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["identityRegistry"] != nil)
        #expect(object["isEnabled"] as? Bool == true)
        #expect(object["monitoredDeviceUUID"] as? String == "00000000-0000-0000-0000-000000000061")
        #expect(object["monitoredDeviceName"] as? String == "Old phone")
        #expect(object["deviceRelation"] as? String == "all")
        #expect(object["lockRSSI"] as? Int == -82)
        #expect(object["unlockRSSI"] as? Int == -59)
        let historicalKeys: Set<String> = [
            "isEnabled", "monitoredDeviceUUID", "monitoredDeviceName",
            "secondaryMonitoredDeviceUUID", "secondaryMonitoredDeviceName",
            "identityRegistry", "deviceRelation", "lockRSSI", "unlockRSSI",
            "proximityTimeout", "signalTimeout", "passiveMode", "thresholdRSSI",
            "wakeOnProximity", "wakeWithoutUnlocking", "pauseNowPlaying",
            "useScreensaver", "turnOffScreen", "screenLockHistory"
        ]
        #expect(historicalKeys.isSubset(of: Set(object.keys)))
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func instant(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
