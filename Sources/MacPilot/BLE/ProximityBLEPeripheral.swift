import CoreBluetooth
import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport

/// Identity the Mac is willing to accept on the reverse link. Each entry is a
/// configured unlock binding; the pairing key is fetched separately by
/// `clientID`, never carried here.
struct ProximityReversePresenceIdentity: Sendable, Equatable {
    let clientID: String
    let keyFingerprint: String
    let primaryUUID: UUID
}

/// A sample that already passed the GATT-layer checks: the HMAC matched one of
/// the configured pairing keys, the nonce was the pending one and the reading
/// was taken just now. The unlock model still revalidates its binding before
/// this may influence presence.
struct ProximityReversePresenceReport: Sendable, Equatable {
    let centralID: UUID
    let clientID: String
    let keyFingerprint: String
    let primaryUUID: UUID
    let rssi: Int
    let sampledAt: Date
}

/// Mac-as-peripheral GATT service. Two independent roles share one manager:
///
/// - `.diagnostic` is the manually started connectivity test (16-byte echo).
/// - `.automaticUnlock` is driven by the BLE unlock feature and only serves the
///   authenticated reverse presence samples that feed RSSI-based presence.
///
/// Starting or stopping one role never stops the other. The advertisement
/// carries the service UUID only.
@MainActor
class ProximityBLEPeripheral: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    static let shared = ProximityBLEPeripheral()

    enum Status: Equatable {
        case idle
        case starting
        case advertising
        case connected
        case failed(String)
    }

    private struct PendingPresenceChallenge {
        let macID: UUID
        let nonce: Data
        let issuedAt: Date
        var delivered: Bool
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastEchoAt: Date?
    @Published private(set) var lastReceivedAt: Date?
    @Published private(set) var receivedBytes = 0
    @Published private(set) var sentBytes = 0
    @Published private(set) var isAdvertising = false
    @Published private(set) var subscriberCount = 0
    /// Diagnostic intent, not the shared manager state: the settings page's
    /// Start/Stop button must never silently control production.
    @Published private(set) var isRunning = false
    @Published private(set) var isProductionRunning = false
    @Published private(set) var presenceSubscriberCount = 0
    @Published private(set) var presenceSampleCount = 0
    @Published private(set) var lastPresenceSampleAt: Date?

    private var manager: CBPeripheralManager?
    private var macInfo = Data()
    private var publishedService: CBMutableService?
    private var echoCharacteristic: CBMutableCharacteristic?
    private var responseCharacteristic: CBMutableCharacteristic?
    private var presenceCharacteristic: CBMutableCharacteristic?

    private var diagnosticWantsRun = false
    private var productionWantsRun = false
    private var productionMacID: UUID?

    /// Supplies this Mac's own identity for the legacy read/write fallback.
    var presenceMacIDProvider: (@MainActor () -> UUID?)?
    /// Verifies the legacy 32-byte identity proof against configured keys.
    var presenceVerifier: (@MainActor (RemoteBLEPresenceChallenge, Data) -> (clientID: String, keyFingerprint: String)?)?
    /// Fires after a central proved it holds the long-term pairing key.
    var onPresenceAuthenticated: (@MainActor (_ centralID: UUID, _ clientID: String, _ keyFingerprint: String) -> Void)?

    /// Current bindings to try for an incoming reverse sample. Fetched per
    /// sample so unbinding takes effect immediately.
    var productionIdentityProvider: (@MainActor () -> [ProximityReversePresenceIdentity])?
    var productionPairingKeyProvider: (@MainActor (String) -> Data?)?
    var onReversePresenceSample: (@MainActor (ProximityReversePresenceReport) -> Void)?

    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var presenceSubscribedCentrals: [UUID: CBCentral] = [:]
    private var pendingPresence: [UUID: PendingPresenceChallenge] = [:]
    /// Only used by the legacy read/write fallback; production challenges are
    /// tracked per central in `pendingPresence`.
    private var outstandingLegacyChallenge: RemoteBLEPresenceChallenge?
    private var isPublishing = false
    private var isStartingAdvertising = false
    private var echoQueue = ProximityGATTEchoQueue()
    private var retry = ProximityGATTRetry()
    private var retryTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var presenceChallengeTask: Task<Void, Never>?
    private var sessionID = UUID()
    private let logLimit = 200
    private let challengeInterval: TimeInterval = 2.5
    private let challengeTTL: TimeInterval = 15

    private var wantsToRun: Bool { diagnosticWantsRun || productionWantsRun }

    /// Whether the periodic challenge cadence is armed. A production restart
    /// must leave this true even when a diagnostic session kept the radio and
    /// the subscriptions alive, otherwise the phone receives one challenge and
    /// then no further samples.
    var isChallengeCadenceRunning: Bool { presenceChallengeTask != nil }

    // MARK: - Lifecycle

    /// Starts or keeps the diagnostic session. Never tears down a production
    /// session that is already running.
    func start(macDeviceID: UUID?) {
        diagnosticWantsRun = true
        isRunning = true
        guard let manager else {
            beginSession(macDeviceID: macDeviceID)
            return
        }
        if !productionWantsRun, let macDeviceID,
           macInfo != ProximityGATTMacInfo(deviceID: macDeviceID).encoded {
            updateMacInfo(macDeviceID, on: manager)
        }
        if publishedService == nil { publishService(on: manager) }
        else { startAdvertising(manager) }
    }

    /// Stops only the diagnostic session.
    func stop() {
        diagnosticWantsRun = false
        isRunning = false
        echoQueue.reset()
        expiryTask?.cancel()
        expiryTask = nil
        subscribedCentrals.removeAll()
        lastEchoAt = nil
        guard !productionWantsRun else {
            refreshPublishedState()
            return
        }
        teardown()
    }

    /// Called by the unlock feature when its production conditions hold.
    func startProduction(macDeviceID: UUID) {
        productionMacID = macDeviceID
        productionWantsRun = true
        isProductionRunning = true
        guard let manager else {
            beginSession(macDeviceID: macDeviceID)
            return
        }
        if macInfo != ProximityGATTMacInfo(deviceID: macDeviceID).encoded {
            updateMacInfo(macDeviceID, on: manager)
        }
        if publishedService == nil { publishService(on: manager) }
        else { startAdvertising(manager) }
        issuePresenceChallengesIfNeeded()
        // `stopProduction` cancels the cadence task but keeps the manager and
        // the existing subscriptions when a diagnostic session still owns the
        // radio. A central that subscribed while production was off was
        // therefore never seen by `didSubscribeTo`'s production branch, so
        // restarting here has to re-arm the cadence explicitly — otherwise the
        // phone gets one challenge and no further samples.
        ensurePresenceChallengeTask()
    }

    /// Stops only the production session: advertising ends unless the
    /// diagnostic session still owns it, and every pending challenge is gone.
    /// Existing presence subscriptions are remembered: an iPhone that stayed
    /// connected while production was off must be challenged again as soon as
    /// the feature comes back, without waiting for a resubscribe that iOS will
    /// never perform on its own.
    func stopProduction() {
        productionWantsRun = false
        isProductionRunning = false
        productionMacID = nil
        clearPresenceChallenges()
        guard diagnosticWantsRun else {
            teardown()
            return
        }
        refreshPublishedState()
    }

    private func beginSession(macDeviceID: UUID?) {
        sessionID = UUID()
        retry.reset()
        receivedBytes = 0
        sentBytes = 0
        lastReceivedAt = nil
        lastEchoAt = nil
        presenceSampleCount = 0
        lastPresenceSampleAt = nil
        status = .starting
        macInfo = ProximityGATTMacInfo(deviceID: macDeviceID).encoded
        log("peripheral starting; MacID=\(macDeviceID?.uuidString ?? "not configured")")
        manager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
        )
    }

    private func updateMacInfo(_ deviceID: UUID, on manager: CBPeripheralManager) {
        macInfo = ProximityGATTMacInfo(deviceID: deviceID).encoded
        // A CBMutableCharacteristic's value is fixed once published, so the
        // service has to be rebuilt for the new Mac info to be readable.
        manager.removeAllServices()
        resetPublishedService()
        publishService(on: manager)
    }

    private func teardown() {
        retryTask?.cancel()
        retryTask = nil
        clearPresenceRuntime()
        echoQueue.reset()
        isAdvertising = false
        subscriberCount = 0
        subscribedCentrals.removeAll()
        publishedService = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        presenceCharacteristic = nil
        isPublishing = false
        isStartingAdvertising = false
        if let manager {
            manager.stopAdvertising()
            manager.removeAllServices()
            manager.delegate = nil
        }
        manager = nil
        status = .idle
        log("peripheral stopped")
    }

    private func clearPresenceChallenges() {
        presenceChallengeTask?.cancel()
        presenceChallengeTask = nil
        pendingPresence.removeAll()
    }

    /// Called only when the manager or its GATT registrations are gone: those
    /// subscriptions no longer exist, so they must not be challenged later.
    private func clearPresenceRuntime() {
        clearPresenceChallenges()
        presenceSubscribedCentrals.removeAll()
        presenceSubscriberCount = 0
    }

    private func refreshPublishedState() {
        subscriberCount = subscribedCentrals.count
        presenceSubscriberCount = presenceSubscribedCentrals.count
        isAdvertising = manager?.isAdvertising ?? false
        if wantsToRun {
            status = presenceSubscriberCount + subscriberCount > 0 ? .connected
                : (isAdvertising ? .advertising : .starting)
        } else {
            status = .idle
        }
    }

    func clearLog() { logLines.removeAll() }

    // MARK: - GATT

    private func publishService(on manager: CBPeripheralManager) {
        guard wantsToRun, !isPublishing, publishedService == nil, manager.state == .poweredOn else { return }
        isPublishing = true

        let macInfoCharacteristic = CBMutableCharacteristic(
            type: ProximityGATTService.macInfoCharacteristicUUID,
            properties: [.read],
            value: macInfo,
            permissions: [.readable]
        )
        let echo = CBMutableCharacteristic(
            type: ProximityGATTService.echoCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        let response = CBMutableCharacteristic(
            type: ProximityGATTService.responseCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        // Notify carries the 16-byte production nonce so it fits the default
        // ATT MTU. Read/write stays for the older identity-proof fallback.
        let presence = CBMutableCharacteristic(
            type: ProximityGATTService.presenceChallengeCharacteristicUUID,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        let service = CBMutableService(type: ProximityGATTService.serviceUUID, primary: true)
        service.characteristics = [macInfoCharacteristic, echo, response, presence]
        publishedService = service
        echoCharacteristic = echo
        responseCharacteristic = response
        presenceCharacteristic = presence
        log("publishing GATT service \(ProximityGATTService.serviceUUID.uuidString)")
        manager.add(service)
    }

    private func startAdvertising(_ manager: CBPeripheralManager) {
        guard wantsToRun, manager.state == .poweredOn,
              !manager.isAdvertising, !isStartingAdvertising else { return }
        isStartingAdvertising = true
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [ProximityGATTService.serviceUUID]
        ])
    }

    private func log(_ message: @autoclosure () -> String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [\(sessionID.uuidString)] \(message())"
        logLines.append(line)
        if logLines.count > logLimit {
            logLines.removeFirst(logLines.count - logLimit)
        }
    }

    private func fail(_ reason: String) {
        status = .failed(reason)
        log("peripheral failed: \(reason)")
    }

    private func scheduleRetry(on peripheral: CBPeripheralManager) {
        guard wantsToRun, peripheral.state == .poweredOn else { return }
        retryTask?.cancel()
        let delay = retry.nextDelay()
        log("retry in \(delay)s")
        retryTask = Task { @MainActor [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let peripheral,
                  peripheral === self.manager, self.wantsToRun,
                  peripheral.state == .poweredOn else { return }
            self.status = .starting
            if self.publishedService == nil { self.publishService(on: peripheral) }
            else { self.startAdvertising(peripheral) }
        }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        if peripheral.state != .poweredOn {
            retryTask?.cancel()
            resetPublishedService()
        }
        switch peripheral.state {
        case .poweredOn:
            log("radio on")
            if wantsToRun { status = .starting }
            publishService(on: peripheral)
        case .unauthorized:
            fail("Bluetooth unauthorized")
        case .unsupported:
            fail("Bluetooth unsupported")
        case .poweredOff:
            fail("Bluetooth is off; waiting for radio recovery")
        default:
            status = .starting
            log("waiting for Bluetooth state=\(peripheral.state.rawValue)")
        }
    }

    /// A radio that leaves the powered-on state drops its GATT registrations
    /// and every subscription. Clearing the references lets the next
    /// powered-on callback publish them again.
    private func resetPublishedService() {
        publishedService = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        presenceCharacteristic = nil
        isPublishing = false
        isStartingAdvertising = false
        echoQueue.reset()
        expiryTask?.cancel()
        isAdvertising = false
        subscriberCount = 0
        subscribedCentrals.removeAll()
        clearPresenceRuntime()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager, service === publishedService else { return }
        isPublishing = false
        if let error {
            publishedService = nil
            echoCharacteristic = nil
            responseCharacteristic = nil
            presenceCharacteristic = nil
            peripheral.removeAllServices()
            fail("service add failed: \(error.localizedDescription)")
            scheduleRetry(on: peripheral)
            return
        }
        log("GATT service added; starting advertisement")
        startAdvertising(peripheral)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager, wantsToRun, peripheral.state == .poweredOn,
              publishedService != nil else { return }
        isStartingAdvertising = false
        if let error {
            isAdvertising = false
            fail("advertising failed: \(error.localizedDescription)")
            scheduleRetry(on: peripheral)
            return
        }
        guard wantsToRun else {
            peripheral.stopAdvertising()
            return
        }
        isAdvertising = peripheral.isAdvertising
        retry.reset()
        status = subscriberCount + presenceSubscriberCount == 0 ? .advertising : .connected
        log("advertising started")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager, wantsToRun,
              request.characteristic.service === publishedService else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        guard request.offset == 0 else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        if request.characteristic.uuid == ProximityGATTService.presenceChallengeCharacteristicUUID {
            // Legacy identity-only fallback: a fresh challenge per read.
            guard let macID = presenceMacIDProvider?() else {
                peripheral.respond(to: request, withResult: .insufficientAuthentication)
                return
            }
            let challenge = RemoteBLEPresenceChallenge(macID: macID)
            outstandingLegacyChallenge = challenge
            request.value = challenge.encoded
            log("issued legacy identity challenge")
            peripheral.respond(to: request, withResult: .success)
            return
        }
        guard request.characteristic.uuid == ProximityGATTService.macInfoCharacteristicUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        request.value = macInfo
        log("central read Mac info (\(macInfo.count) bytes)")
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        if requests.count == 1, let request = requests.first,
           request.characteristic === presenceCharacteristic {
            handlePresenceWrite(peripheral: peripheral, request: request)
            return
        }
        // CoreBluetooth requires one ATT response for the entire batch. Validate
        // into a copy first so a rejected batch cannot partially echo data.
        var staged = echoQueue
        for request in requests {
            guard peripheral === manager, wantsToRun,
                  request.characteristic === responseCharacteristic else {
                peripheral.respond(to: first, withResult: .requestNotSupported)
                return
            }
            guard request.offset == 0 else {
                peripheral.respond(to: first, withResult: .invalidOffset)
                return
            }
            guard let value = request.value, value.count == ProximityGATTEcho.length else {
                log("rejected write: invalid length \(request.value?.count ?? 0)")
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                return
            }
            guard subscribedCentrals[request.central.identifier] != nil else {
                log("rejected write: no subscriber for central=\(request.central.identifier)")
                peripheral.respond(to: first, withResult: .unlikelyError)
                return
            }
            guard staged.enqueue(value, for: request.central.identifier) else {
                log("rejected write: notification queue busy")
                peripheral.respond(to: first, withResult: .insufficientResources)
                return
            }
        }
        echoQueue = staged
        lastReceivedAt = .now
        receivedBytes += requests.count * ProximityGATTEcho.length
        log("received 16 bytes; writes=\(requests.count)")
        peripheral.respond(to: first, withResult: .success)
        deliverEchoes(on: peripheral)
    }

    private func handlePresenceWrite(peripheral: CBPeripheralManager, request: CBATTRequest) {
        guard peripheral === manager, wantsToRun else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        guard request.offset == 0 else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        guard let response = request.value else {
            peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
            return
        }
        if response.count == RemoteBLEReversePresenceSample.encodedLength {
            handleReversePresenceSample(peripheral: peripheral, request: request, response: response)
            return
        }
        handleLegacyPresenceProof(peripheral: peripheral, request: request, response: response)
    }

    /// Production path: one authenticated RSSI sample for the nonce this
    /// central was last sent. Verification happens here; the sample only
    /// becomes presence evidence after the unlock model revalidates it.
    private func handleReversePresenceSample(
        peripheral: CBPeripheralManager,
        request: CBATTRequest,
        response: Data
    ) {
        let centralID = request.central.identifier
        guard productionWantsRun else {
            log("rejected reverse sample: production disabled")
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        guard presenceSubscribedCentrals[centralID] != nil else {
            log("rejected reverse sample: no presence subscription central=\(centralID)")
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        guard let pending = pendingPresence[centralID] else {
            log("rejected reverse sample: no pending challenge central=\(centralID)")
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        guard let sample = RemoteBLEReversePresenceSample(encoded: response) else {
            log("rejected reverse sample: malformed payload")
            peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
            return
        }
        let now = Date.now
        guard sample.macID == pending.macID,
              RemoteCrypto.constantTimeEquals(sample.nonce, pending.nonce) else {
            log("rejected reverse sample: challenge mismatch")
            peripheral.respond(to: request, withResult: .insufficientAuthentication)
            return
        }
        guard sample.isFresh(now: now) else {
            log("rejected reverse sample: stale timestamp")
            peripheral.respond(to: request, withResult: .insufficientAuthentication)
            return
        }
        guard let matched = matchIdentity(for: sample, expectedMacID: pending.macID, expectedNonce: pending.nonce, now: now) else {
            log("rejected reverse sample: no matching pairing key")
            peripheral.respond(to: request, withResult: .insufficientAuthentication)
            return
        }
        // Single use: only a verified sample consumes the challenge.
        pendingPresence.removeValue(forKey: centralID)
        presenceSampleCount += 1
        lastPresenceSampleAt = now
        lastReceivedAt = now
        let age = max(0, now.timeIntervalSince(sample.sampledAt))
        log("reverse presence verified client=\(matched.clientID) rssi=\(sample.rssi) age=\(Int(age * 1000))ms")
        peripheral.respond(to: request, withResult: .success)
        onReversePresenceSample?(ProximityReversePresenceReport(
            centralID: centralID,
            clientID: matched.clientID,
            keyFingerprint: matched.keyFingerprint,
            primaryUUID: matched.primaryUUID,
            rssi: sample.rssi,
            sampledAt: sample.sampledAt
        ))
    }

    private func matchIdentity(
        for sample: RemoteBLEReversePresenceSample,
        expectedMacID: UUID,
        expectedNonce: Data,
        now: Date
    ) -> ProximityReversePresenceIdentity? {
        guard let identities = productionIdentityProvider?(),
              let keyProvider = productionPairingKeyProvider else { return nil }
        for identity in identities {
            guard let key = keyProvider(identity.clientID) else { continue }
            if sample.isValid(
                pairingKey: key,
                expectedMacID: expectedMacID,
                expectedNonce: expectedNonce,
                now: now
            ) {
                return identity
            }
        }
        return nil
    }

    /// Legacy identity-only proof, kept for older phones that read the 33-byte
    /// challenge. It proves identity, never proximity.
    private func handleLegacyPresenceProof(
        peripheral: CBPeripheralManager,
        request: CBATTRequest,
        response: Data
    ) {
        guard response.count == RemoteBLEPresenceChallenge.responseLength else {
            log("rejected presence answer: invalid length \(response.count)")
            peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
            return
        }
        guard let challenge = outstandingLegacyChallenge else {
            log("rejected presence answer: no outstanding challenge")
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        guard let verifier = presenceVerifier,
              let binding = verifier(challenge, response) else {
            log("rejected presence answer: no matching pairing key central=\(request.central.identifier)")
            outstandingLegacyChallenge = nil
            peripheral.respond(to: request, withResult: .insufficientAuthentication)
            return
        }
        outstandingLegacyChallenge = nil
        log("presence authenticated central=\(request.central.identifier) client=\(binding.clientID)")
        peripheral.respond(to: request, withResult: .success)
        onPresenceAuthenticated?(request.central.identifier, binding.clientID, binding.keyFingerprint)
    }

    // MARK: - Production challenges

    private func issuePresenceChallengesIfNeeded() {
        guard productionWantsRun, let peripheral = manager,
              peripheral.state == .poweredOn,
              productionMacID != nil,
              !presenceSubscribedCentrals.isEmpty,
              publishedService != nil else {
            presenceChallengeTask?.cancel()
            presenceChallengeTask = nil
            return
        }
        let now = Date.now
        for (centralID, central) in presenceSubscribedCentrals {
            if let pending = pendingPresence[centralID] {
                let age = now.timeIntervalSince(pending.issuedAt)
                if age > challengeTTL {
                    pendingPresence.removeValue(forKey: centralID)
                } else if pending.delivered, age >= challengeInterval {
                    // Replace the previous nonce on the regular cadence.
                } else {
                    // Undelivered or still fresh: retry the same nonce.
                    if !pending.delivered {
                        sendPresenceChallenge(pending.nonce, macID: pending.macID, to: central, on: peripheral)
                    }
                    continue
                }
            }
            _ = issuePresenceChallenge(to: central, on: peripheral, at: now)
        }
    }

    @discardableResult
    private func issuePresenceChallenge(
        to central: CBCentral,
        on peripheral: CBPeripheralManager,
        at now: Date = .now
    ) -> Bool {
        guard productionWantsRun, let macID = productionMacID else { return false }
        let nonce = RemoteCrypto.randomData(count: RemoteBLEReversePresenceSample.nonceLength)
        pendingPresence[central.identifier] = PendingPresenceChallenge(
            macID: macID,
            nonce: nonce,
            issuedAt: now,
            delivered: false
        )
        return sendPresenceChallenge(nonce, macID: macID, to: central, on: peripheral)
    }

    @discardableResult
    private func sendPresenceChallenge(
        _ nonce: Data,
        macID: UUID,
        to central: CBCentral,
        on peripheral: CBPeripheralManager
    ) -> Bool {
        guard let presenceCharacteristic else { return false }
        guard peripheral.updateValue(nonce, for: presenceCharacteristic, onSubscribedCentrals: [central]) else {
            // A full notification buffer is not authentication. The next ready
            // callback or cadence tick retries the same nonce.
            log("challenge not queued; waiting for buffer central=\(central.identifier)")
            return false
        }
        if var pending = pendingPresence[central.identifier], pending.nonce == nonce {
            pending.delivered = true
            pendingPresence[central.identifier] = pending
        }
        log("reverse challenge queued central=\(central.identifier) mac=\(macID)")
        return true
    }

    private func ensurePresenceChallengeTask() {
        guard productionWantsRun, presenceChallengeTask == nil else { return }
        presenceChallengeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, let self else { return }
                self.issuePresenceChallengesIfNeeded()
            }
        }
    }

    // MARK: - Echo delivery

    private func deliverEchoes(on peripheral: CBPeripheralManager) {
        guard let echoCharacteristic else { return }
        echoQueue.discardExpired()
        while let entry = echoQueue.entries.first {
            guard let central = subscribedCentrals[entry.centralID] else {
                echoQueue.removeFirst()
                continue
            }
            guard peripheral.updateValue(entry.payload, for: echoCharacteristic, onSubscribedCentrals: [central]) else {
                log("echo not queued; waiting for notification buffer central=\(entry.centralID)")
                scheduleQueueExpiry()
                return
            }
            echoQueue.removeFirst()
            lastEchoAt = .now
            sentBytes += entry.payload.count
            log("echoed 16 bytes central=\(entry.centralID); queued, verification belongs to iPhone")
        }
        expiryTask?.cancel()
        expiryTask = nil
    }

    private func scheduleQueueExpiry() {
        expiryTask?.cancel()
        guard let expiry = echoQueue.entries.first?.expiresAt else { return }
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.log("notification queue deadline reached")
            self.echoQueue.discardExpired()
            if let manager = self.manager { self.deliverEchoes(on: manager) }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        log("notification buffer ready")
        deliverEchoes(on: peripheral)
        issuePresenceChallengesIfNeeded()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, wantsToRun else { return }
        if characteristic === presenceCharacteristic {
            // Record the subscription even while production is off. It grants
            // nothing by itself, and keeping it lets a later production start
            // challenge this central without a resubscribe iOS will not send.
            presenceSubscribedCentrals[central.identifier] = central
            presenceSubscriberCount = presenceSubscribedCentrals.count
            guard productionWantsRun else {
                log("presence subscription recorded; production disabled central=\(central.identifier)")
                return
            }
            status = .connected
            log("central subscribed to reverse presence uuid=\(central.identifier)")
            issuePresenceChallenge(to: central, on: peripheral)
            ensurePresenceChallengeTask()
            return
        }
        guard characteristic === echoCharacteristic else { return }
        subscribedCentrals[central.identifier] = central
        subscriberCount = subscribedCentrals.count
        isAdvertising = peripheral.isAdvertising
        status = .connected
        log("central subscribed uuid=\(central.identifier.uuidString)")
        // Subscription proves notification availability, not round-trip success.
        if peripheral.isAdvertising == false {
            log("advertisement paused while connected")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, wantsToRun else { return }
        if characteristic === presenceCharacteristic {
            presenceSubscribedCentrals.removeValue(forKey: central.identifier)
            pendingPresence.removeValue(forKey: central.identifier)
            presenceSubscriberCount = presenceSubscribedCentrals.count
            log("central unsubscribed from reverse presence uuid=\(central.identifier)")
            if presenceSubscribedCentrals.isEmpty {
                presenceChallengeTask?.cancel()
                presenceChallengeTask = nil
            }
            refreshPublishedState()
            if wantsToRun, peripheral.state == .poweredOn, peripheral.isAdvertising == false {
                startAdvertising(peripheral)
            }
            return
        }
        guard characteristic === echoCharacteristic else { return }
        subscribedCentrals.removeValue(forKey: central.identifier)
        subscriberCount = subscribedCentrals.count
        echoQueue.remove(centralID: central.identifier)
        isAdvertising = peripheral.isAdvertising
        log("central unsubscribed uuid=\(central.identifier.uuidString)")
        if subscribedCentrals.isEmpty && presenceSubscribedCentrals.isEmpty {
            if !wantsToRun {
                status = .idle
            } else {
                status = peripheral.isAdvertising ? .advertising : .starting
            }
        }
        if wantsToRun, peripheral.state == .poweredOn, peripheral.isAdvertising == false {
            startAdvertising(peripheral)
        }
    }
}
