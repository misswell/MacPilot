import AppKit
import ApplicationServices
import CoreBluetooth
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import Security
import SQLite3

// MARK: - Apple device name lookup

let appleDeviceNames: [String: String] = [
    "iPhone1,1": "iPhone", "iPhone1,2": "iPhone 3G", "iPhone2,1": "iPhone 3GS",
    "iPhone3,1": "iPhone 4 (GSM)", "iPhone3,2": "iPhone 4 (GSM Rev A)", "iPhone3,3": "iPhone 4 (CDMA)",
    "iPhone4,1": "iPhone 4S", "iPhone5,1": "iPhone 5", "iPhone5,2": "iPhone 5",
    "iPhone5,3": "iPhone 5c", "iPhone5,4": "iPhone 5c", "iPhone6,1": "iPhone 5s", "iPhone6,2": "iPhone 5s",
    "iPhone7,1": "iPhone 6 Plus", "iPhone7,2": "iPhone 6", "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus",
    "iPhone8,4": "iPhone SE", "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
    "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
    "iPhone12,8": "iPhone SE", "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
    "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
    "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,1": "iPhone 11",
    "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
    "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
    "iPod1,1": "iPod touch (1st generation)", "iPod2,1": "iPod touch (2nd generation)",
    "iPod3,1": "iPod touch (3rd generation)", "iPod4,1": "iPod touch (4th generation)",
    "iPod5,1": "iPod touch (5th generation)", "iPod7,1": "iPod touch (6th generation)", "iPod9,1": "iPod touch (7th generation)",
    "iPad1,1": "iPad", "iPad2,1": "iPad 2", "iPad2,2": "iPad 2 Wi-Fi + 3G (GSM)", "iPad2,3": "iPad 2 Wi-Fi + 3G (CDMA)", "iPad2,4": "iPad 2 (Rev A)",
    "iPad3,1": "iPad (3rd generation)", "iPad3,2": "iPad Wi-Fi + 4G (LTE/CDMA)", "iPad3,3": "iPad Wi-Fi + 4G (LTE/GSM)",
    "iPad3,4": "iPad (4th generation)", "iPad3,5": "iPad (4th generation)", "iPad3,6": "iPad (4th generation)",
    "iPad4,1": "iPad Air", "iPad4,2": "iPad Air", "iPad4,3": "iPad Air",
    "iPad5,3": "iPad Air 2", "iPad5,4": "iPad Air 2",
    "iPad6,11": "iPad (5th generation)", "iPad6,12": "iPad (5th generation)",
    "iPad11,3": "iPad Air (3rd generation)", "iPad11,4": "iPad Air (3rd generation)",
    "iPad13,1": "iPad Air (4th generation)", "iPad13,2": "iPad Air (4th generation)",
    "iPad7,5": "iPad (6th generation)", "iPad7,6": "iPad (6th generation)",
    "iPad2,5": "iPad mini", "iPad2,6": "iPad mini", "iPad2,7": "iPad mini",
    "iPad4,4": "iPad mini 2", "iPad4,5": "iPad mini 2", "iPad4,6": "iPad mini 2",
    "iPad4,7": "iPad mini 3", "iPad4,8": "iPad mini 3", "iPad4,9": "iPad mini 3",
    "iPad5,1": "iPad mini 4", "iPad5,2": "iPad mini 4",
    "iPad11,1": "iPad mini (5th generation)", "iPad11,2": "iPad mini (5th generation)",
    "iPad6,7": "iPad Pro (12.9-inch)", "iPad6,8": "iPad Pro (12.9-inch)",
    "iPad6,3": "iPad Pro (9.7-inch)", "iPad6,4": "iPad Pro (9.7-inch)",
    "iPad7,1": "iPad Pro (12.9-inch, 2nd generation)", "iPad7,2": "iPad Pro (12.9-inch, 2nd generation)",
    "iPad7,3": "iPad Pro (10.5-inch)", "iPad7,4": "iPad Pro (10.5-inch)",
    "iPad8,1": "iPad Pro (11-inch)", "iPad8,2": "iPad Pro (11-inch)", "iPad8,3": "iPad Pro (11-inch)", "iPad8,4": "iPad Pro (11-inch)",
    "iPad8,5": "iPad Pro (12.9-inch) (3rd generation)", "iPad8,6": "iPad Pro (12.9-inch) (3rd generation)",
    "iPad8,7": "iPad Pro (12.9-inch) (3rd generation)", "iPad8,8": "iPad Pro (12.9-inch) (3rd generation)",
    "iPad8,9": "iPad Pro (11-inch) (2nd generation)", "iPad8,10": "iPad Pro (11-inch) (2nd generation)",
    "iPad8,11": "iPad Pro (12.9-inch) (4th generation)", "iPad8,12": "iPad Pro (12.9-inch) (4th generation)",
    "iPad13,4": "iPad Pro (11-inch) (3rd generation)", "iPad13,5": "iPad Pro (11-inch) (3rd generation)",
    "iPad13,6": "iPad Pro (11-inch) (3rd generation)", "iPad13,7": "iPad Pro (11-inch) (3rd generation)",
    "iPad13,8": "iPad Pro (12.9-inch) (5th generation)", "iPad13,9": "iPad Pro (12.9-inch) (5th generation)",
    "iPad13,10": "iPad Pro (12.9-inch) (5th generation)", "iPad13,11": "iPad Pro (12.9-inch) (5th generation)",
    "iPad7,11": "iPad (7th generation)", "iPad7,12": "iPad (7th generation)",
    "iPad11,6": "iPad (8th generation)", "iPad11,7": "iPad (8th generation)",
    "iPad12,1": "iPad (9th generation)", "iPad12,2": "iPad (9th generation)",
    "iPad14,1": "iPad mini (6th generation)", "iPad14,2": "iPad mini (6th generation)",
    "Watch1,1": "Apple Watch 38mm", "Watch1,2": "Apple Watch 42mm",
    "Watch2,6": "Apple Watch Series 1", "Watch2,7": "Apple Watch Series 1",
    "Watch2,3": "Apple Watch Series 2", "Watch2,4": "Apple Watch Series 2",
    "Watch3,1": "Apple Watch Series 3 (GPS + Cellular)", "Watch3,2": "Apple Watch Series 3 (GPS + Cellular)",
    "Watch3,3": "Apple Watch Series 3 (GPS)", "Watch3,4": "Apple Watch Series 3 (GPS)",
    "Watch4,1": "Apple Watch Series 4", "Watch4,2": "Apple Watch Series 4",
    "Watch4,3": "Apple Watch Series 4", "Watch4,4": "Apple Watch Series 4",
    "Watch5,1": "Apple Watch Series 5", "Watch5,2": "Apple Watch Series 5",
    "Watch5,3": "Apple Watch Series 5", "Watch5,4": "Apple Watch Series 5",
    "Watch6,1": "Apple Watch Series 6", "Watch6,2": "Apple Watch Series 6",
    "Watch6,3": "Apple Watch Series 6", "Watch6,4": "Apple Watch Series 6",
    "Watch5,9": "Apple Watch SE", "Watch5,10": "Apple Watch SE",
    "Watch5,11": "Apple Watch SE", "Watch5,12": "Apple Watch SE",
    "Watch6,6": "Apple Watch Series 7", "Watch6,7": "Apple Watch Series 7",
    "Watch6,8": "Apple Watch Series 7", "Watch6,9": "Apple Watch Series 7",
    "AppleTV2,1": "Apple TV (2nd generation)", "AppleTV3,1": "Apple TV (3rd generation)",
    "AppleTV3,2": "Apple TV (3rd generation Rev A)", "AppleTV5,3": "Apple TV (4th generation)",
    "AppleTV6,2": "Apple TV 4K", "AppleTV11,1": "Apple TV 4K (2nd generation)",
    "AudioAccessory1,1": "HomePod", "AudioAccessory1,2": "HomePod", "AudioAccessory5,1": "HomePod mini"
]

// MARK: - BLE device name / MAC resolution


func bleGetMACFromUUID(_ uuid: String) -> String? {
    guard let cache = bluetoothPreferences?["CoreBluetoothCache"] as? NSDictionary,
          let device = cache[uuid] as? NSDictionary else { return nil }
    return device["DeviceAddress"] as? String
}

func bleGetNameFromMAC(_ mac: String) -> String? {
    guard let cache = bluetoothPreferences?["DeviceCache"] as? NSDictionary,
          let device = cache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
    return nil
}

nonisolated(unsafe) private let bluetoothPreferences = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist")

struct BLELEDeviceInfo {
    let name: String?
    let macAddr: String?
}

func bleGetLEDeviceInfoFromUUID(_ uuid: String) -> BLELEDeviceInfo? {
    connectBluetoothDatabases()
    if let paired = getPairedDevice(uuid) { return paired }
    return getOtherDevice(uuid)
}

nonisolated(unsafe) private var bluetoothDBInited = false
nonisolated(unsafe) private var dbPaired: OpaquePointer?
nonisolated(unsafe) private var dbOther: OpaquePointer?

private func connectBluetoothDatabases() {
    guard !bluetoothDBInited else { return }
    bluetoothDBInited = true
    if sqlite3_open("/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.paired.db", &dbPaired) != SQLITE_OK { dbPaired = nil }
    if sqlite3_open("/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.other.db", &dbOther) != SQLITE_OK { dbOther = nil }
}

private func bluetoothStringFromRow(_ stmt: OpaquePointer?, index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    let s = String(cString: cString).trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? nil : s
}

private func bluetoothExtractMAC(_ address: String?) -> String? {
    guard let addr = address else { return nil }
    // Stored as "Public XX:XX:..." or "Random XX:XX:..."
    let parts = addr.split(separator: " ")
    return parts.count > 1 ? String(parts[1]) : nil
}

private func getPairedDevice(_ uuid: String) -> BLELEDeviceInfo? {
    guard let db = dbPaired else { return nil }
    var stmt: OpaquePointer?
    let query = "SELECT Name, Address, ResolvedAddress FROM PairedDevices where Uuid='\(uuid)'"
    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
        sqlite3_finalize(stmt)
        return nil
    }
    let name = bluetoothStringFromRow(stmt, index: 0)
    let address = bluetoothStringFromRow(stmt, index: 1)
    let resolved = bluetoothStringFromRow(stmt, index: 2)
    sqlite3_finalize(stmt)
    return BLELEDeviceInfo(name: name, macAddr: bluetoothExtractMAC(resolved ?? address))
}

private func getOtherDevice(_ uuid: String) -> BLELEDeviceInfo? {
    guard let db = dbOther else { return nil }
    var stmt: OpaquePointer?
    let query = "SELECT Name, Address FROM OtherDevices where Uuid='\(uuid)'"
    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
        sqlite3_finalize(stmt)
        return nil
    }
    let name = bluetoothStringFromRow(stmt, index: 0)
    let address = bluetoothStringFromRow(stmt, index: 1)
    sqlite3_finalize(stmt)
    return BLELEDeviceInfo(name: name, macAddr: bluetoothExtractMAC(address))
}

// MARK: - Discovered device

final class BLEUnlockDevice: Identifiable, Hashable {
    let id: UUID
    let uuid: UUID
    var peripheral: CBPeripheral?
    var manufacturer: String?
    var model: String?
    var advertisementData: Data?
    var rssi: Int = 0
    var macAddress: String?
    var bluetoothName: String?
    var lastSeenAt = Date()
    var firstSeenAt = Date()
    private var didResolveIdentity = false

    init(uuid: UUID) { self.uuid = uuid; self.id = uuid }

    static func == (lhs: BLEUnlockDevice, rhs: BLEUnlockDevice) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var displayName: String {
        if macAddress != nil {
            if let name = bluetoothName, name != "iPhone", name != "iPad" { return name }
        }
        if let manu = manufacturer, let mod = model {
            if manu == "Apple Inc.", let friendly = appleDeviceNames[mod] { return friendly }
            return "\(manu)/\(mod)"
        }
        if let manu = manufacturer { return manu }
        if let name = peripheral?.name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if let mod = model { return mod }
        if let adv = advertisementData, adv.count >= 25 {
            let prefix = Data([0x4C, 0x00, 0x02, 0x15])
            if adv[0..<4] == prefix {
                let major = UInt16(adv[20]) << 8 | UInt16(adv[21])
                let minor = UInt16(adv[22]) << 8 | UInt16(adv[23])
                let tx = Int8(bitPattern: adv[24])
                let distance = pow(10, Double(Int(tx) - rssi) / 20.0)
                return "iBeacon [\(major), \(minor)] \(String(format: "%.1f", distance))m"
            }
        }
        if let name = bluetoothName { return name }
        if let mac = macAddress { return mac }
        return uuid.uuidString
    }

    func resolveIdentity() {
        guard !didResolveIdentity else { return }
        didResolveIdentity = true
        if let info = bleGetLEDeviceInfoFromUUID(uuid.uuidString) {
            bluetoothName = info.name
            macAddress = info.macAddr
        }
        if macAddress == nil { macAddress = bleGetMACFromUUID(uuid.uuidString) }
        if bluetoothName == nil, let mac = macAddress { bluetoothName = bleGetNameFromMAC(mac) }
    }

    var prettifiedMAC: String? {
        guard let mac = macAddress else { return nil }
        return mac.replacingOccurrences(of: "-", with: ":").uppercased()
    }

    var menuTitle: String {
        if let mac = prettifiedMAC {
            return String(format: "%@ (%@) (%ddBm)", displayName, mac, rssi)
        }
        return String(format: "%@ (%ddBm)", displayName, rssi)
    }
}

struct BLEDeviceListRefreshBatcher {
    private var hasPendingRefresh = false

    mutating func requestRefresh() {
        hasPendingRefresh = true
    }

    mutating func takePendingRefresh() -> Bool {
        defer { hasPendingRefresh = false }
        return hasPendingRefresh
    }
}

// MARK: - Persisted settings

enum BLEDevicePresenceRelation: String, Codable, CaseIterable, Hashable {
    case any
    case all
}

enum BLEDevicePresencePolicy {
    static func isSatisfied(
        presences: [Bool],
        relation: BLEDevicePresenceRelation
    ) -> Bool {
        guard !presences.isEmpty else { return false }
        switch relation {
        case .any:
            return presences.contains(true)
        case .all:
            return presences.allSatisfy { $0 }
        }
    }
}

struct BLEUnlockSettings: Codable {
    var isEnabled: Bool = false
    var monitoredDeviceUUID: String?
    var monitoredDeviceName: String?
    var secondaryMonitoredDeviceUUID: String?
    var secondaryMonitoredDeviceName: String?
    var deviceRelation: BLEDevicePresenceRelation = .any
    var lockRSSI: Int = -80
    var unlockRSSI: Int = -60
    var proximityTimeout: Int = 5
    var signalTimeout: Int = 60
    var passiveMode: Bool = false
    var thresholdRSSI: Int = -70
    var wakeOnProximity: Bool = false
    var wakeWithoutUnlocking: Bool = false
    var pauseNowPlaying: Bool = false
    var useScreensaver: Bool = false
    var turnOffScreen: Bool = false
    var screenLockHistory = ScreenLockHistory()

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case monitoredDeviceUUID
        case monitoredDeviceName
        case secondaryMonitoredDeviceUUID
        case secondaryMonitoredDeviceName
        case deviceRelation
        case lockRSSI
        case unlockRSSI
        case proximityTimeout
        case signalTimeout
        case passiveMode
        case thresholdRSSI
        case wakeOnProximity
        case wakeWithoutUnlocking
        case pauseNowPlaying
        case useScreensaver
        case turnOffScreen
        case screenLockHistory
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        monitoredDeviceUUID = try container.decodeIfPresent(String.self, forKey: .monitoredDeviceUUID)
        monitoredDeviceName = try container.decodeIfPresent(String.self, forKey: .monitoredDeviceName)
        secondaryMonitoredDeviceUUID = try container.decodeIfPresent(String.self, forKey: .secondaryMonitoredDeviceUUID)
        secondaryMonitoredDeviceName = try container.decodeIfPresent(String.self, forKey: .secondaryMonitoredDeviceName)
        deviceRelation = (try? container.decode(BLEDevicePresenceRelation.self, forKey: .deviceRelation)) ?? .any
        lockRSSI = try container.decodeIfPresent(Int.self, forKey: .lockRSSI) ?? -80
        unlockRSSI = try container.decodeIfPresent(Int.self, forKey: .unlockRSSI) ?? -60
        proximityTimeout = try container.decodeIfPresent(Int.self, forKey: .proximityTimeout) ?? 5
        signalTimeout = try container.decodeIfPresent(Int.self, forKey: .signalTimeout) ?? 60
        passiveMode = try container.decodeIfPresent(Bool.self, forKey: .passiveMode) ?? false
        thresholdRSSI = try container.decodeIfPresent(Int.self, forKey: .thresholdRSSI) ?? -70
        wakeOnProximity = try container.decodeIfPresent(Bool.self, forKey: .wakeOnProximity) ?? false
        wakeWithoutUnlocking = try container.decodeIfPresent(Bool.self, forKey: .wakeWithoutUnlocking) ?? false
        pauseNowPlaying = try container.decodeIfPresent(Bool.self, forKey: .pauseNowPlaying) ?? false
        useScreensaver = try container.decodeIfPresent(Bool.self, forKey: .useScreensaver) ?? false
        turnOffScreen = try container.decodeIfPresent(Bool.self, forKey: .turnOffScreen) ?? false
        screenLockHistory = try container.decodeIfPresent(ScreenLockHistory.self, forKey: .screenLockHistory) ?? ScreenLockHistory()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(monitoredDeviceUUID, forKey: .monitoredDeviceUUID)
        try container.encodeIfPresent(monitoredDeviceName, forKey: .monitoredDeviceName)
        try container.encodeIfPresent(secondaryMonitoredDeviceUUID, forKey: .secondaryMonitoredDeviceUUID)
        try container.encodeIfPresent(secondaryMonitoredDeviceName, forKey: .secondaryMonitoredDeviceName)
        try container.encode(deviceRelation, forKey: .deviceRelation)
        try container.encode(lockRSSI, forKey: .lockRSSI)
        try container.encode(unlockRSSI, forKey: .unlockRSSI)
        try container.encode(proximityTimeout, forKey: .proximityTimeout)
        try container.encode(signalTimeout, forKey: .signalTimeout)
        try container.encode(passiveMode, forKey: .passiveMode)
        try container.encode(thresholdRSSI, forKey: .thresholdRSSI)
        try container.encode(wakeOnProximity, forKey: .wakeOnProximity)
        try container.encode(wakeWithoutUnlocking, forKey: .wakeWithoutUnlocking)
        try container.encode(pauseNowPlaying, forKey: .pauseNowPlaying)
        try container.encode(useScreensaver, forKey: .useScreensaver)
        try container.encode(turnOffScreen, forKey: .turnOffScreen)
        try container.encode(screenLockHistory, forKey: .screenLockHistory)
    }
}

/// Controls when CoreBluetooth is allowed to create its central manager.
///
/// Constructing `CBCentralManager` is itself a privacy-sensitive operation on
/// macOS: when Bluetooth access is still undecided it can immediately show a
/// system authorization prompt.  A persisted "enabled" toggle is not an
/// explicit user action during startup, so startup must wait until the user
/// opens BLE settings or starts a scan.  Once access has already been decided,
/// automatic monitoring may safely restore itself in the background.
enum BLEUnlockAuthorizationGate {
    static func shouldInitializeCentralManager(
        authorization: CBManagerAuthorization,
        settingsEnabled: Bool,
        hasMonitoredDevice: Bool,
        explicitUserAction: Bool
    ) -> Bool {
        guard settingsEnabled || explicitUserAction else { return false }

        switch authorization {
        case .allowedAlways:
            return true
        case .notDetermined:
            return explicitUserAction
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

struct BLEWakeRecoveryPlan: Equatable {
    let monitoringRestartDelays: [TimeInterval]
    let unlockRetryDelays: [TimeInterval]

    static func make(isEnabled: Bool, hasMonitoredDevice: Bool) -> BLEWakeRecoveryPlan? {
        guard isEnabled, hasMonitoredDevice else { return nil }
        return BLEWakeRecoveryPlan(
            monitoringRestartDelays: [0, 1, 3, 6, 10],
            unlockRetryDelays: [1, 3, 6, 10]
        )
    }
}

/// Repairs monitoring after a display-only wake or a lost CoreBluetooth
/// callback. A fresh RSSI sample is still required before proximity unlock.
struct BLEMonitoringRecoveryPlan: Equatable {
    let restartDelays: [TimeInterval]

    static func make(isEnabled: Bool, hasMonitoredDevice: Bool) -> BLEMonitoringRecoveryPlan? {
        guard isEnabled, hasMonitoredDevice else { return nil }
        return BLEMonitoringRecoveryPlan(restartDelays: [0, 3, 10])
    }
}

/// Detects the failure mode where CoreBluetooth keeps reporting a powered-on
/// radio and an "active" scan, but stops delivering advertisements to the
/// process entirely.
///
/// The September 2026 proximity-unlock wedge looked exactly like a healthy
/// scan from inside the app — state poweredOn, `scanForPeripherals` accepted,
/// recovery restarts running — while an unfiltered scan from another process
/// received hundreds of advertisements per second, including the monitored
/// device a metre away. That state survives central manager recreation and
/// app relaunch, so detection cannot live inside the callback machinery: the
/// only observable signature is that an unfiltered scan hears *nothing at
/// all* — not even unrelated neighbours — for far longer than any real radio
/// environment stays quiet.
struct BLEAdvertisementLiveness: Equatable {
    let silenceThreshold: TimeInterval
    private(set) var lastActivityAt: Date

    init(silenceThreshold: TimeInterval = 600, now: Date = Date()) {
        self.silenceThreshold = silenceThreshold
        self.lastActivityAt = now
    }

    mutating func noteActivity(now: Date = Date()) {
        lastActivityAt = now
    }

    static func monitoringActive(
        featureEnabled: Bool,
        hasMonitoredDevice: Bool,
        bluetoothPoweredOn: Bool,
        displayAsleep: Bool,
        systemAsleep: Bool,
        centralScanning: Bool
    ) -> Bool {
        featureEnabled && hasMonitoredDevice && bluetoothPoweredOn
            && !displayAsleep && !systemAsleep && centralScanning
    }

    /// Returns true when the process should be receiving advertisement
    /// callbacks but has received none for `silenceThreshold`. While
    /// monitoring is not expected to produce callbacks — feature off, display
    /// or system asleep, no scan and no connected device — the baseline is
    /// kept fresh so re-arming cannot trip on stale history.
    mutating func evaluate(now: Date, monitoringActive: Bool) -> Bool {
        guard monitoringActive else {
            lastActivityAt = now
            return false
        }
        return now.timeIntervalSince(lastActivityAt) >= silenceThreshold
    }
}

/// Gives the lock screen time to become interactive after the display wakes.
/// The first attempt is intentionally delayed; later attempts cover both a
/// slow wake and a missed `screensDidWake` notification without running
/// indefinitely while the Mac is idle.
struct BLEUnlockAttemptPlan: Equatable {
    let deadlines: [TimeInterval]

    static let standard = BLEUnlockAttemptPlan(
        deadlines: [2, 5, 9, 14, 20]
    )
}

enum BLEUnlockConfirmation {
    static func isConfirmed(screenState: BLEScreenLockState) -> Bool {
        screenState == .unlocked
    }
}

/// Decides whether a pending unlock attempt may type at its next deadline.
///
/// Losing presence for real is handled by `updatePresence(false)`, which
/// cancels the attempt (and its generation) outright. A false `presence` that
/// reaches the attempt therefore means the display-wake recovery reset the BLE
/// state while the link is being rebuilt — a transient condition that must not
/// end the retry.
enum BLEUnlockAttemptGate {
    enum Decision: Equatable {
        /// Keep the attempt and type at this deadline.
        case proceed
        /// Skip this deadline; the device may still come back within the plan.
        case waitForPresence
        /// The attempt is no longer wanted: end it and release its slot.
        case stop
    }

    static func decide(
        presence: Bool,
        manualLock: Bool,
        unlockDisabled: Bool,
        wakeWithoutUnlocking: Bool,
        systemSleep: Bool
    ) -> Decision {
        if manualLock || unlockDisabled || wakeWithoutUnlocking || systemSleep {
            return .stop
        }
        return presence ? .proceed : .waitForPresence
    }
}

/// Owns the single in-flight unlock attempt.
///
/// An attempt that ends without releasing its slot makes every later
/// `scheduleUnlockAttempt` log "already scheduled" and return, so the proximity
/// unlock silently stops working for the rest of that lock session. Claiming and
/// releasing through this type keeps that from happening, and the generation
/// check keeps a finished old attempt from freeing the slot its successor took.
struct BLEUnlockAttemptSlot {
    private(set) var generation = 0
    private(set) var isOccupied = false

    /// Claims the slot, returning the generation to hand to the attempt, or
    /// `nil` while another attempt is still in flight.
    mutating func claim() -> Int? {
        guard !isOccupied else { return nil }
        isOccupied = true
        return generation
    }

    /// Releases the slot from a finishing attempt. A stale generation is
    /// ignored so an old attempt cannot free its successor's slot.
    mutating func release(generation: Int) {
        guard generation == self.generation else { return }
        isOccupied = false
    }

    /// Cancels whatever is in flight by invalidating its generation.
    mutating func invalidate() {
        generation &+= 1
        isOccupied = false
    }
}

struct BLEUnlockAttemptProgress {
    enum Action: Equatable {
        case postPassword(deadline: TimeInterval)
        case confirmed
        case stateUnavailable
        case exhausted
    }

    let deadlines: [TimeInterval]
    private(set) var nextIndex = 0

    init(plan: BLEUnlockAttemptPlan) {
        deadlines = plan.deadlines
    }

    var nextDeadline: TimeInterval? {
        guard nextIndex < deadlines.count else { return nil }
        return deadlines[nextIndex]
    }

    mutating func skipCurrentDeadline() {
        guard nextIndex < deadlines.count else { return }
        nextIndex += 1
    }

    mutating func nextAction(screenState: BLEScreenLockState) -> Action {
        switch screenState {
        case .unlocked:
            return .confirmed
        case .unknown:
            skipCurrentDeadline()
            return .stateUnavailable
        case .locked:
            guard let deadline = nextDeadline else { return .exhausted }
            nextIndex += 1
            return .postPassword(deadline: deadline)
        }
    }
}


/// CoreBluetooth can retain the backing storage for an outstanding request in
/// an XPC/Mach message region. Never submit a second RSSI read until the first
/// one has produced its delegate callback (or the connection is torn down).
struct BLERequestGate {
    static let requestTimeout: TimeInterval = 12

    private(set) var isInFlight = false
    private var startedAt: Date?

    @discardableResult
    mutating func begin(at now: Date = Date()) -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        startedAt = now
        return true
    }

    mutating func finish() {
        isInFlight = false
        startedAt = nil
    }

    func hasTimedOut(at now: Date) -> Bool {
        guard let startedAt,
              now.timeIntervalSince(startedAt) >= Self.requestTimeout else { return false }
        return true
    }

    mutating func reset() {
        isInFlight = false
        startedAt = nil
    }
}

/// Avoid sending a new connect request on every active-mode timer tick while
/// CoreBluetooth is still completing the previous connection attempt.
struct BLEConnectionRetryGate {
    static let minimumRetryInterval: TimeInterval = 10

    private(set) var lastAttemptAt: Date?

    @discardableResult
    mutating func begin(at now: Date) -> Bool {
        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < Self.minimumRetryInterval {
            return false
        }
        lastAttemptAt = now
        return true
    }

    mutating func reset() {
        lastAttemptAt = nil
    }
}

/// Scanning must not ask CoreBluetooth to deliver every advertisement packet.
