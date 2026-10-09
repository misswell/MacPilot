import Foundation
import Testing
@testable import MacPilot

@Suite("BLE identity integration")
@MainActor
struct BLEIdentityIntegrationTests {
    @Test("authenticated aliases never imply proximity or unlock")
    func learningDoesNotSetPresence() {
        let model = BLEUnlockModel()
        // No monitoring activation, real radio, screen control or credentials.
        model.settings.isEnabled = false
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        let primary = UUID()
        let alias = UUID()
        model.monitoredUUID = primary
        model.settings.monitoredDeviceUUID = primary.uuidString
        model.bindRemoteIdentity(primaryUUID: primary, clientID: "phone", keyFingerprint: "generation")
        model.learnAuthenticatedBLEIdentity(clientID: "phone", keyFingerprint: "wrong", peripheralUUID: alias)
        #expect(model.settings.identityRegistry.uuids(for: primary) == [primary])
        model.learnAuthenticatedBLEIdentity(clientID: "phone", keyFingerprint: "generation", peripheralUUID: alias)
        #expect(model.settings.identityRegistry.uuids(for: primary).contains(alias))
        #expect(!model.presence)
        #expect(model.lastRSSI == nil)
        #expect(!model.connected)
        #expect(!model.isScanning)
        model.reconcileRemoteIdentities([:])
        #expect(model.settings.identityRegistry.uuids(for: primary) == [primary])
    }

    @Test("one paired phone cannot satisfy both logical devices through aliases")
    func reassignmentUsesExplicitBindingOnly() {
        let model = BLEUnlockModel()
        model.settings.isEnabled = false
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        let primary = UUID()
        let secondary = UUID()
        model.monitoredUUID = primary
        model.secondaryMonitoredUUID = secondary
        model.bindRemoteIdentity(primaryUUID: primary, clientID: "phone", keyFingerprint: "generation")
        model.bindRemoteIdentity(primaryUUID: secondary, clientID: "phone", keyFingerprint: "generation")
        #expect(model.settings.identityRegistry.bindings.count == 1)
        #expect(model.settings.identityRegistry.bindings.first?.primaryUUID == secondary.uuidString)
        model.bindRemoteIdentity(primaryUUID: secondary, clientID: nil, keyFingerprint: nil)
        #expect(model.settings.identityRegistry.bindings.isEmpty)
    }

    @Test("pairing key generations are stable and revocation notifies listeners")
    func pairingGenerationRevocation() {
        let store = RemoteDeviceStore(secretStore: InMemorySecretStore(), log: { _ in })
        let firstKey = Data(repeating: 1, count: 32)
        let nextKey = Data(repeating: 2, count: 32)
        #expect(RemoteDeviceStore.fingerprint(of: firstKey) == RemoteDeviceStore.fingerprint(of: firstKey))
        #expect(RemoteDeviceStore.fingerprint(of: firstKey) != RemoteDeviceStore.fingerprint(of: nextKey))
        #expect(store.storePairingKey(firstKey, for: "phone"))
        store.registerPairedDevice(clientID: "phone", name: "same name", address: nil)
        var changes = 0
        store.onPairedIdentitiesChanged = { changes += 1 }
        #expect(store.storePairingKey(nextKey, for: "phone"))
        #expect(store.pairedIdentityFingerprints["phone"] == RemoteDeviceStore.fingerprint(of: nextKey))
        store.removeDevice(clientID: "phone")
        #expect(changes == 2)
        #expect(store.pairedIdentityFingerprints.isEmpty)
    }
}
