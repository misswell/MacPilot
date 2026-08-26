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

nonisolated(unsafe) private let deviceInformationUUID = CBUUID(string: "180A")
nonisolated(unsafe) private let manufacturerNameUUID = CBUUID(string: "2A29")
nonisolated(unsafe) private let modelNameUUID = CBUUID(string: "2A24")
nonisolated(unsafe) private let exposureNotificationUUID = CBUUID(string: "FD6F")

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

/// Gives the lock screen time to become interactive after the display wakes.
/// The first attempt is intentionally delayed; later attempts cover both a
/// slow wake and a missed `screensDidWake` notification without running
/// indefinitely while the Mac is idle.
struct BLEUnlockAttemptPlan: Equatable {
    let deadlines: [TimeInterval]

    static let standard = BLEUnlockAttemptPlan(
        deadlines: [0.5, 1, 2, 4, 8, 12]
    )
}

enum BLEScreenLockState: String, Equatable {
    case locked
    case unlocked
    case unknown
}

enum BLEUnlockConfirmation {
    static func isConfirmed(screenState: BLEScreenLockState) -> Bool {
        screenState == .unlocked
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

private final class BLEMonitoredDeviceRuntime {
    let uuid: UUID
    var peripheral: CBPeripheral?
    var presence = false
    var lastRSSI: Int?
    var activeMode = false
    var latestRSSIs: [Double] = []
    var rssiReadGate = BLERequestGate()
    var connectionRetryGate = BLEConnectionRetryGate()
    var proximityTimer: Timer?
    var signalTimer: Timer?
    var activeModeTimer: Timer?
    var connectionTimer: Timer?

    init(uuid: UUID) {
        self.uuid = uuid
    }

    func invalidateTimers() {
        proximityTimer?.invalidate()
        proximityTimer = nil
        signalTimer?.invalidate()
        signalTimer = nil
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        connectionTimer?.invalidate()
        connectionTimer = nil
        rssiReadGate.reset()
        connectionRetryGate.reset()
        activeMode = false
    }
}

/// CoreBluetooth can retain the backing storage for an outstanding request in
/// an XPC/Mach message region. Never submit a second RSSI read until the first
/// one has produced its delegate callback (or the connection is torn down).
struct BLERequestGate {
    private(set) var isInFlight = false

    @discardableResult
    mutating func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    mutating func finish() {
        isInFlight = false
    }

    mutating func reset() {
        isInFlight = false
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
/// The monitored peripherals receive their periodic RSSI reads through the
/// connected-peripheral path below; duplicate advertisements only create an
/// unbounded XPC/Mach-message stream on macOS.
enum BLEScanPolicy {
    static let allowsDuplicateAdvertisements = false

    static var scanOptions: [String: Any]? {
        allowsDuplicateAdvertisements
            ? [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            : nil
    }
}

// MARK: - Model

@MainActor
final class BLEUnlockModel: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let unlockDisabled = 1
    static let lockDisabled = -100
    private static let maximumVisibleDevices = 100
    private static let deviceRefreshInterval: Duration = .milliseconds(200)
    static let rssiOptions: [Int] = Array(stride(from: -30, to: -100, by: -5))
    static let lockDelayOptions: [Int] = [2, 5, 15, 30, 60, 120, 300]
    static let timeoutOptions: [Int] = [30, 60, 120, 300, 600]

    var persist: (@MainActor () -> Void)?

    // Runtime state published for the UI.
    @Published private(set) var devices: [BLEUnlockDevice] = []
    @Published private(set) var presence = false
    @Published private(set) var lastRSSI: Int?
    @Published private(set) var connected = false
    @Published private(set) var activeMode = false
    @Published private(set) var bluetoothPoweredOn = false
    @Published private(set) var bluetoothPowerWarned = false
    @Published private(set) var isScanning = false

    var settings = BLEUnlockSettings()

    private var centralMgr: CBCentralManager?
    private var deviceMap: [UUID: BLEUnlockDevice] = [:]
    private var deviceRefreshBatcher = BLEDeviceListRefreshBatcher()
    private var deviceRefreshTask: Task<Void, Never>?
    private var scanCleanupTimer: Timer?
    var monitoredUUID: UUID?
    var secondaryMonitoredUUID: UUID?
    private var monitoredRuntimes: [UUID: BLEMonitoredDeviceRuntime] = [:]
    private var wakeRetryTask: Task<Void, Never>?
    private var systemWakeRecoveryTask: Task<Void, Never>?
    private var unlockAttemptTask: Task<Void, Never>?
    private var unlockAttemptGeneration = 0
    private var hasPasswordCache: Bool?
    private var lastLoggedRSSIAt = Date.distantPast
    private var lastLoggedRSSI: Int?
    private var lastLoggedRSSIErrorAt = Date.distantPast

    private var displaySleep = false
    private var systemSleep = false
    private var recoveringFromSystemSleep = false
    private var manualLock = false
    private var pendingLockSource: ScreenLockHistorySource?
    private var pendingLockSourceExpiresAt = Date.distantPast
    private var inScreensaver = false
    private var lastUnlockRequestAt: TimeInterval = 0
    private var lastAutomaticUnlockRequestAt: TimeInterval = 0
    private var lastAutomaticUnlockConfirmationAt: TimeInterval = 0
    private var nowPlayingWasPlaying = false

    var isRecoveringFromSystemSleep: Bool { recoveringFromSystemSleep }
    var screenLockHistory: [ScreenLockHistoryEntry] { settings.screenLockHistory.entries }

    // MediaRemote (private framework, loaded lazily).
    private var mediaRemoteHandle: UnsafeMutableRawPointer?
    private var mrSendCommand: (@convention(c) (Int32, AnyObject?) -> Bool)?
    private var mrGetPlaying: (@convention(c) (DispatchQueue, @convention(block) (Bool) -> Void) -> Void)?

    private func log(_ message: @autoclosure () -> String) {
        DiagnosticLog.write("BLEUnlock", message())
    }

    private func logMonitoredRSSI(raw: Int, estimated: Int) {
        let now = Date()
        let changedEnough = lastLoggedRSSI.map { abs($0 - estimated) >= 5 } ?? true
        guard changedEnough || now.timeIntervalSince(lastLoggedRSSIAt) >= 5 else { return }
        lastLoggedRSSIAt = now
        lastLoggedRSSI = estimated
        log("RSSI sample raw=\(raw) estimated=\(estimated) presence=\(presence) active=\(activeMode) connected=\(connected) displaySleep=\(displaySleep) systemSleep=\(systemSleep)")
    }

    private func logRSSIError(_ error: Error?) {
        let now = Date()
        guard now.timeIntervalSince(lastLoggedRSSIErrorAt) >= 5 else { return }
        lastLoggedRSSIErrorAt = now
        log("RSSI read failed error=\(error?.localizedDescription ?? "unknown") presence=\(presence) connected=\(connected)")
    }

    private func logSettings(_ event: String) {
        log("\(event) enabled=\(settings.isEnabled) device=\(settings.monitoredDeviceName ?? "?") uuid=\(monitoredUUID?.uuidString ?? settings.monitoredDeviceUUID ?? "none") secondary=\(secondaryMonitoredUUID?.uuidString ?? settings.secondaryMonitoredDeviceUUID ?? "none") relation=\(settings.deviceRelation.rawValue) lockRSSI=\(settings.lockRSSI) unlockRSSI=\(settings.unlockRSSI) signalTimeout=\(settings.signalTimeout) wakeOnProximity=\(settings.wakeOnProximity) wakeWithoutUnlocking=\(settings.wakeWithoutUnlocking) passive=\(settings.passiveMode)")
    }

    private var monitoredUUIDs: [UUID] {
        var result: [UUID] = []
        if let monitoredUUID { result.append(monitoredUUID) }
        if let secondaryMonitoredUUID, !result.contains(secondaryMonitoredUUID) {
            result.append(secondaryMonitoredUUID)
        }
        return result
    }

    private var hasMonitoredDevice: Bool { !monitoredUUIDs.isEmpty }

    private func runtime(for uuid: UUID) -> BLEMonitoredDeviceRuntime? {
        monitoredRuntimes[uuid]
    }

    private func ensureRuntime(for uuid: UUID) -> BLEMonitoredDeviceRuntime {
        if let runtime = monitoredRuntimes[uuid] { return runtime }
        let runtime = BLEMonitoredDeviceRuntime(uuid: uuid)
        monitoredRuntimes[uuid] = runtime
        return runtime
    }

    private func isMonitoredPeripheral(_ peripheral: CBPeripheral) -> Bool {
        monitoredUUIDs.contains(peripheral.identifier)
    }

    private func refreshPublishedMonitoringState() {
        let runtimes = monitoredUUIDs.compactMap { monitoredRuntimes[$0] }
        let latestRSSI = runtimes.compactMap(\.lastRSSI).max()
        let isConnected = runtimes.contains { $0.peripheral?.state == .connected }
        let isActive = runtimes.contains { $0.activeMode }
        if lastRSSI != latestRSSI { lastRSSI = latestRSSI }
        if connected != isConnected { connected = isConnected }
        if activeMode != isActive { activeMode = isActive }
    }

    private func recomputePresence(reason: String) {
        let oldPresence = presence
        let devicePresences = monitoredUUIDs.map { monitoredRuntimes[$0]?.presence ?? false }
        let newPresence = BLEDevicePresencePolicy.isSatisfied(
            presences: devicePresences,
            relation: settings.deviceRelation
        )
        refreshPublishedMonitoringState()
        guard oldPresence != newPresence else {
            log("combined presence unchanged value=\(newPresence) reason=\(reason) devices=\(devicePresences)")
            return
        }
        presence = newPresence
        updatePresence(presence: newPresence, reason: reason)
    }

    private func cancelRuntime(for uuid: UUID) {
        guard let runtime = monitoredRuntimes.removeValue(forKey: uuid) else { return }
        runtime.invalidateTimers()
        if let peripheral = runtime.peripheral {
            centralMgr?.cancelPeripheralConnection(peripheral)
            if !deviceMap.values.contains(where: { $0.peripheral === peripheral }) {
                peripheral.delegate = nil
            }
        }
    }

    private func startConfiguredMonitoring(preservingExistingState: Bool = false) {
        cancelUnlockAttempt(reason: "monitoring-restarted")
        let uuids = monitoredUUIDs
        let initialPresence = uuids.count == 1

        for uuid in Array(monitoredRuntimes.keys) where !uuids.contains(uuid) {
            cancelRuntime(for: uuid)
        }

        for uuid in uuids {
            let hadRuntime = monitoredRuntimes[uuid] != nil
            let runtime = ensureRuntime(for: uuid)
            if preservingExistingState, hadRuntime {
                if runtime.signalTimer == nil {
                    resetSignalTimer(for: uuid)
                }
                continue
            }
            if let peripheral = runtime.peripheral {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
            runtime.invalidateTimers()
            runtime.peripheral = nil
            runtime.lastRSSI = nil
            runtime.latestRSSIs.removeAll(keepingCapacity: true)
            runtime.presence = initialPresence
            resetSignalTimer(for: uuid)
        }

        presence = BLEDevicePresencePolicy.isSatisfied(
            presences: uuids.map { monitoredRuntimes[$0]?.presence ?? false },
            relation: settings.deviceRelation
        )
        refreshPublishedMonitoringState()
        scanForPeripherals()
        logSettings("monitoring started")
    }

    // MARK: Settings mutations

    private func notifyChange() {
        objectWillChange.send()
        persist?()
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        log("setEnabled from=\(settings.isEnabled) to=\(enabled)")
        settings.isEnabled = enabled
        if enabled {
            if hasMonitoredDevice {
                // Toggling the feature is an explicit user action, so this is
                // the one path allowed to start the first Bluetooth prompt.
                ensureCentralManager(explicitUserAction: true)
                if centralMgr?.state == .poweredOn { startConfiguredMonitoring() }
            }
        } else {
            stopMonitoring()
        }
        notifyChange()
    }

    func activateFromConfiguration() {
        guard settings.isEnabled else {
            logSettings("configuration activation skipped")
            return
        }
        logSettings("configuration activation")
        // Do not create CBCentralManager during launch while Bluetooth access
        // is still undecided.  Creating it here makes every newly installed
        // or identity-mismatched build prompt before the user asks to use BLE.
        ensureCentralManager()
        if hasMonitoredDevice { startConfiguredMonitoring() }
    }

    func setLockRSSI(_ value: Int) { log("setLockRSSI from=\(settings.lockRSSI) to=\(value)"); settings.lockRSSI = value; notifyChange() }
    func setUnlockRSSI(_ value: Int) { log("setUnlockRSSI from=\(settings.unlockRSSI) to=\(value)"); settings.unlockRSSI = value; notifyChange() }
    func setProximityTimeout(_ value: Int) { log("setProximityTimeout from=\(settings.proximityTimeout) to=\(value)"); settings.proximityTimeout = value; notifyChange() }
    func setSignalTimeout(_ value: Int) { log("setSignalTimeout from=\(settings.signalTimeout) to=\(value)"); settings.signalTimeout = value; notifyChange() }
    func setThresholdRSSI(_ value: Int) { log("setThresholdRSSI from=\(settings.thresholdRSSI) to=\(value)"); settings.thresholdRSSI = value; notifyChange() }
    func setWakeOnProximity(_ value: Bool) { log("setWakeOnProximity from=\(settings.wakeOnProximity) to=\(value)"); settings.wakeOnProximity = value; notifyChange() }
    func setWakeWithoutUnlocking(_ value: Bool) { log("setWakeWithoutUnlocking from=\(settings.wakeWithoutUnlocking) to=\(value)"); settings.wakeWithoutUnlocking = value; notifyChange() }
    func setPauseNowPlaying(_ value: Bool) { log("setPauseNowPlaying from=\(settings.pauseNowPlaying) to=\(value)"); settings.pauseNowPlaying = value; notifyChange() }
    func setUseScreensaver(_ value: Bool) { log("setUseScreensaver from=\(settings.useScreensaver) to=\(value)"); settings.useScreensaver = value; notifyChange() }
    func setTurnOffScreen(_ value: Bool) { log("setTurnOffScreen from=\(settings.turnOffScreen) to=\(value)"); settings.turnOffScreen = value; notifyChange() }

    func setDeviceRelation(_ value: BLEDevicePresenceRelation) {
        guard settings.deviceRelation != value else { return }
        log("setDeviceRelation from=\(settings.deviceRelation.rawValue) to=\(value.rawValue)")
        settings.deviceRelation = value
        recomputePresence(reason: "relationChanged")
        notifyChange()
    }

    func setPassiveMode(_ value: Bool) {
        log("setPassiveMode from=\(settings.passiveMode) to=\(value)")
        settings.passiveMode = value
        applyPassiveMode()
        notifyChange()
    }

    func selectDevice(_ uuid: UUID) {
        deviceMap[uuid]?.resolveIdentity()
        let selectedName = deviceMap[uuid]?.displayName
        log("selectDevice uuid=\(uuid.uuidString) name=\(selectedName ?? "?") rssi=\(deviceMap[uuid]?.rssi ?? 0)")
        stopScanning()
        if secondaryMonitoredUUID == uuid {
            clearSecondaryDevice(notify: false)
        }
        settings.monitoredDeviceUUID = uuid.uuidString
        settings.monitoredDeviceName = selectedName
        monitoredUUID = uuid
        ensureCentralManager(explicitUserAction: true)
        startConfiguredMonitoring(preservingExistingState: true)
        notifyChange()
    }

    func selectSecondaryDevice(_ uuid: UUID) {
        guard uuid != monitoredUUID else {
            log("selectSecondaryDevice ignored reason=duplicatePrimary uuid=\(uuid.uuidString)")
            return
        }
        deviceMap[uuid]?.resolveIdentity()
        let selectedName = deviceMap[uuid]?.displayName
        log("selectSecondaryDevice uuid=\(uuid.uuidString) name=\(selectedName ?? "?") rssi=\(deviceMap[uuid]?.rssi ?? 0)")
        stopScanning()
        if let oldUUID = secondaryMonitoredUUID, oldUUID != uuid {
            cancelRuntime(for: oldUUID)
        }
        secondaryMonitoredUUID = uuid
        settings.secondaryMonitoredDeviceUUID = uuid.uuidString
        settings.secondaryMonitoredDeviceName = selectedName
        ensureCentralManager(explicitUserAction: true)
        startConfiguredMonitoring(preservingExistingState: true)
        notifyChange()
    }

    func removeSecondaryDevice() {
        guard secondaryMonitoredUUID != nil || settings.secondaryMonitoredDeviceUUID != nil else { return }
        log("removeSecondaryDevice")
        clearSecondaryDevice(notify: true)
    }

    private func clearSecondaryDevice(notify: Bool) {
        if let uuid = secondaryMonitoredUUID {
            cancelRuntime(for: uuid)
        }
        secondaryMonitoredUUID = nil
        settings.secondaryMonitoredDeviceUUID = nil
        settings.secondaryMonitoredDeviceName = nil
        settings.deviceRelation = .any
        if hasMonitoredDevice {
            startConfiguredMonitoring(preservingExistingState: true)
        } else {
            presence = false
            refreshPublishedMonitoringState()
        }
        if notify { notifyChange() }
    }

    func applyLoadedSettings(_ loaded: BLEUnlockSettings) {
        settings = loaded
        monitoredUUID = nil
        secondaryMonitoredUUID = nil
        monitoredRuntimes.removeAll(keepingCapacity: false)
        if let uuidString = loaded.monitoredDeviceUUID, let uuid = UUID(uuidString: uuidString) {
            monitoredUUID = uuid
        }
        if let uuidString = loaded.secondaryMonitoredDeviceUUID,
           let uuid = UUID(uuidString: uuidString),
           uuid != monitoredUUID {
            secondaryMonitoredUUID = uuid
        } else {
            settings.secondaryMonitoredDeviceUUID = nil
            settings.secondaryMonitoredDeviceName = nil
        }
        objectWillChange.send()
        logSettings("settings loaded")
    }

    // MARK: Lifecycle

    func ensureCentralManager(explicitUserAction: Bool = false) {
        guard centralMgr == nil else {
            log("central manager already exists state=\(String(describing: centralMgr?.state))")
            return
        }
        let authorization = CBManager.authorization
        guard BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: authorization,
            settingsEnabled: settings.isEnabled,
            hasMonitoredDevice: hasMonitoredDevice,
            explicitUserAction: explicitUserAction
        ) else {
            log("central manager creation skipped authorization=\(String(describing: authorization)) enabled=\(settings.isEnabled) hasDevice=\(hasMonitoredDevice) explicitUserAction=\(explicitUserAction)")
            return
        }
        log("creating central manager authorization=\(String(describing: authorization)) explicitUserAction=\(explicitUserAction)")
        centralMgr = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func startScanning() {
        log("startScanning")
        ensureCentralManager(explicitUserAction: true)
        isScanning = true
        startScanCleanupTimer()
        scanForPeripherals()
    }

    func stopScanning() {
        log("stopScanning devices=\(deviceMap.count) monitored=\(monitoredUUIDs.count)")
        isScanning = false
        scanCleanupTimer?.invalidate()
        scanCleanupTimer = nil
        clearDiscoveredDevices()
        if !hasMonitoredDevice && !activeMode { centralMgr?.stopScan() }
    }

    private func stopMonitoring() {
        log("stopMonitoring")
        isScanning = false
        scanCleanupTimer?.invalidate(); scanCleanupTimer = nil
        deviceRefreshTask?.cancel(); deviceRefreshTask = nil
        wakeRetryTask?.cancel(); wakeRetryTask = nil
        systemWakeRecoveryTask?.cancel(); systemWakeRecoveryTask = nil
        cancelUnlockAttempt()
        centralMgr?.stopScan()
        clearDiscoveredDevices()
        for runtime in monitoredRuntimes.values {
            runtime.invalidateTimers()
            if let peripheral = runtime.peripheral {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
        }
        monitoredRuntimes.removeAll(keepingCapacity: false)
        presence = false
        lastRSSI = nil
        connected = false
        activeMode = false
        recoveringFromSystemSleep = false
    }

    private func clearDiscoveredDevices() {
        deviceRefreshTask?.cancel()
        deviceRefreshTask = nil
        deviceRefreshBatcher = BLEDeviceListRefreshBatcher()
        let discoveredPeripherals = deviceMap.values.compactMap(\.peripheral)
        deviceMap.removeAll(keepingCapacity: false)
        devices.removeAll(keepingCapacity: false)
        for peripheral in discoveredPeripherals where !isMonitoredPeripheral(peripheral) {
            centralMgr?.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
        }
    }

    private func scanForPeripherals() {
        guard let central = centralMgr else {
            log("scan skipped reason=noCentralManager")
            return
        }
        guard central.state == .poweredOn else {
            log("scan skipped reason=bluetoothState state=\(String(describing: central.state))")
            return
        }
        guard !central.isScanning else { return }
        log("scan started monitored=\(monitoredUUIDs.map(\.uuidString).joined(separator: ","))")
        central.scanForPeripherals(withServices: nil, options: BLEScanPolicy.scanOptions)
    }

    private func applyPassiveMode() {
        for runtime in monitoredRuntimes.values {
            if settings.passiveMode {
                runtime.activeModeTimer?.invalidate()
                runtime.activeModeTimer = nil
                runtime.activeMode = false
                if let peripheral = runtime.peripheral {
                    centralMgr?.cancelPeripheralConnection(peripheral)
                }
            } else if runtime.peripheral != nil {
                connectMonitoredPeripheral(for: runtime.uuid)
            }
        }
        refreshPublishedMonitoringState()
        scanForPeripherals()
    }

    func startMonitor(_ uuid: UUID) {
        log("startMonitor uuid=\(uuid.uuidString) previousPresence=\(presence)")
        monitoredUUID = uuid
        startConfiguredMonitoring()
    }

    private func resetSignalTimer(for uuid: UUID) {
        guard let runtime = runtime(for: uuid) else { return }
        runtime.signalTimer?.invalidate()
        runtime.signalTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.signalTimeout), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let runtime = self.runtime(for: uuid) else { return }
                self.log("signal timeout fired uuid=\(uuid.uuidString) timeout=\(self.settings.signalTimeout) devicePresence=\(runtime.presence)")
                runtime.signalTimer = nil
                runtime.lastRSSI = nil
                runtime.activeMode = false
                if runtime.presence {
                    runtime.presence = false
                    self.recomputePresence(reason: "lost")
                } else {
                    self.refreshPublishedMonitoringState()
                }
            }
        }
        if let timer = runtime.signalTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func estimatedRSSI(_ rssi: Int, for runtime: BLEMonitoredDeviceRuntime) -> Int {
        runtime.latestRSSIs.append(Double(rssi))
        if runtime.latestRSSIs.count > 5 { runtime.latestRSSIs.removeFirst() }
        let mean = runtime.latestRSSIs.reduce(0, +) / Double(runtime.latestRSSIs.count)
        return Int(mean)
    }

    private func updateMonitoredPeripheral(_ rssi: Int, for uuid: UUID) {
        guard let runtime = runtime(for: uuid) else { return }
        let unlockThreshold = settings.unlockRSSI == Self.unlockDisabled ? settings.lockRSSI : settings.unlockRSSI
        if rssi >= unlockThreshold && !runtime.presence {
            log("RSSI crossed unlock threshold raw=\(rssi) threshold=\(unlockThreshold) previousPresence=false")
            runtime.presence = true
            recomputePresence(reason: "close")
            runtime.latestRSSIs.removeAll()
        }

        let estimated = estimatedRSSI(rssi, for: runtime)
        runtime.lastRSSI = estimated
        runtime.activeMode = runtime.activeModeTimer != nil
        refreshPublishedMonitoringState()
        logMonitoredRSSI(raw: rssi, estimated: estimated)

        let lockThreshold = settings.lockRSSI == Self.lockDisabled ? settings.unlockRSSI : settings.lockRSSI
        if estimated >= lockThreshold {
            if runtime.proximityTimer != nil {
                log("RSSI recovered above lock threshold estimated=\(estimated) threshold=\(lockThreshold); cancelling away timer")
            }
            runtime.proximityTimer?.invalidate()
            runtime.proximityTimer = nil
        } else if runtime.presence && runtime.proximityTimer == nil {
            log("RSSI below lock threshold estimated=\(estimated) threshold=\(lockThreshold); scheduling away timer seconds=\(settings.proximityTimeout)")
            runtime.proximityTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.proximityTimeout), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let runtime = self.runtime(for: uuid) else { return }
                    self.log("away timer fired uuid=\(uuid.uuidString) estimatedRSSI=\(runtime.lastRSSI.map(String.init) ?? "none")")
                    runtime.presence = false
                    runtime.proximityTimer = nil
                    self.recomputePresence(reason: "away")
                }
            }
            if let timer = runtime.proximityTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        resetSignalTimer(for: uuid)
    }

    private func startScanCleanupTimer() {
        guard scanCleanupTimer == nil else { return }
        scanCleanupTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeStaleDevices() }
        }
        if let timer = scanCleanupTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func removeStaleDevices() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(settings.signalTimeout))
        let stale = deviceMap.values.filter { $0.lastSeenAt < cutoff }
        guard !stale.isEmpty else { return }
        log("removing stale devices count=\(stale.count) timeout=\(settings.signalTimeout)")
        for device in stale {
            deviceMap.removeValue(forKey: device.uuid)
            if let peripheral = device.peripheral, !isMonitoredPeripheral(peripheral) {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
        }
        requestDeviceRefresh(immediate: true)
    }

    private func requestDeviceRefresh(immediate: Bool = false) {
        deviceRefreshBatcher.requestRefresh()
        if immediate {
            deviceRefreshTask?.cancel()
            deviceRefreshTask = nil
            publishDeviceListIfNeeded()
            return
        }
        guard deviceRefreshTask == nil else { return }
        deviceRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.deviceRefreshInterval)
            guard !Task.isCancelled else { return }
            self?.deviceRefreshTask = nil
            self?.publishDeviceListIfNeeded()
        }
    }

    private func publishDeviceListIfNeeded() {
        guard deviceRefreshBatcher.takePendingRefresh() else { return }
        devices = deviceMap.values.sorted { $0.firstSeenAt < $1.firstSeenAt }
    }

    private func connectMonitoredPeripheral(for uuid: UUID) {
        guard let runtime = runtime(for: uuid), let peripheral = runtime.peripheral else {
            log("connect skipped reason=noMonitoredPeripheral")
            return
        }

        if peripheral.state == .connected {
            requestRSSIRead(for: runtime)
            return
        }
        guard peripheral.state == .disconnected else { return }
        guard runtime.connectionRetryGate.begin(at: Date()) else { return }

        log("connect monitored peripheral uuid=\(uuid.uuidString) state=\(String(describing: peripheral.state)) passive=\(settings.passiveMode)")
        centralMgr?.connect(peripheral, options: nil)
        runtime.connectionTimer?.invalidate()
        runtime.connectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let runtime = self.runtime(for: uuid),
                      let peripheral = runtime.peripheral, peripheral.state == .connecting else { return }
                self.centralMgr?.cancelPeripheralConnection(peripheral)
                runtime.connectionTimer = nil
            }
        }
        if let timer = runtime.connectionTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func requestRSSIRead(for runtime: BLEMonitoredDeviceRuntime) {
        guard let peripheral = runtime.peripheral,
              peripheral.state == .connected,
              runtime.rssiReadGate.begin() else { return }
        peripheral.readRSSI()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central state updated state=\(String(describing: central.state)) authorization=\(String(describing: CBManager.authorization))")
        switch central.state {
        case .poweredOn:
            bluetoothPoweredOn = true
            bluetoothPowerWarned = false
            if settings.isEnabled && hasMonitoredDevice {
                if monitoredUUIDs.contains(where: { monitoredRuntimes[$0] == nil }) {
                    startConfiguredMonitoring()
                } else {
                    scanForPeripherals()
                }
            } else if isScanning {
                scanForPeripherals()
            }
        case .poweredOff:
            log("bluetooth powered off; clearing presence")
            bluetoothPoweredOn = false
            presence = false
            for runtime in monitoredRuntimes.values {
                runtime.invalidateTimers()
                runtime.peripheral = nil
                runtime.lastRSSI = nil
                runtime.presence = false
            }
            refreshPublishedMonitoringState()
            if !bluetoothPowerWarned {
                bluetoothPowerWarned = true
            }
        default:
            log("bluetooth unavailable state=\(String(describing: central.state))")
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue

        if settings.isEnabled,
           let uuid = monitoredUUIDs.first(where: { $0 == peripheral.identifier }) {
            let runtime = ensureRuntime(for: uuid)
            let firstDiscovery = runtime.peripheral == nil
            runtime.peripheral = peripheral
            if firstDiscovery {
                log("monitored peripheral discovered uuid=\(uuid.uuidString) rssi=\(rssi) passive=\(settings.passiveMode)")
            }
            if runtime.activeModeTimer == nil {
                updateMonitoredPeripheral(rssi, for: uuid)
                if !settings.passiveMode { connectMonitoredPeripheral(for: uuid) }
            }
        }

        guard isScanning else { return }
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            if uuids.contains(exposureNotificationUUID) { return }
        }

        if let existing = deviceMap[peripheral.identifier] {
            existing.rssi = rssi
            existing.lastSeenAt = Date()
            requestDeviceRefresh()
            return
        }

        guard rssi >= settings.thresholdRSSI else { return }
        if deviceMap.count >= Self.maximumVisibleDevices {
            guard let weakest = deviceMap.values.min(by: { $0.rssi < $1.rssi }), rssi > weakest.rssi else { return }
            deviceMap.removeValue(forKey: weakest.uuid)
            if let oldPeripheral = weakest.peripheral { central.cancelPeripheralConnection(oldPeripheral) }
        }
        let device = BLEUnlockDevice(uuid: peripheral.identifier)
        device.peripheral = peripheral
        device.rssi = rssi
        device.advertisementData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        if peripheral.name == nil, rssi >= -60 { device.resolveIdentity() }
        deviceMap[peripheral.identifier] = device
        log("device discovered uuid=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? device.bluetoothName ?? "unknown") rssi=\(rssi) visibleCount=\(deviceMap.count)")
        if device.bluetoothName == nil, peripheral.name == nil, rssi >= -55 {
            central.connect(peripheral, options: nil)
        }
        requestDeviceRefresh()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let monitoredRuntime = runtime(for: peripheral.identifier)
        let isMonitored = monitoredRuntime != nil
        log("peripheral connected monitored=\(isMonitored) uuid=\(peripheral.identifier.uuidString) state=\(String(describing: peripheral.state))")
        guard isScanning || isMonitored else {
            log("connected peripheral cancelled because it is not monitored or scanning")
            central.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
            return
        }
        peripheral.delegate = self
        if isScanning { peripheral.discoverServices([deviceInformationUUID]) }
        if isMonitored, !settings.passiveMode, let monitoredRuntime {
            monitoredRuntime.connectionTimer?.invalidate()
            monitoredRuntime.connectionTimer = nil
            monitoredRuntime.connectionRetryGate.reset()
            requestRSSIRead(for: monitoredRuntime)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("peripheral connection failed monitored=\(runtime(for: peripheral.identifier) != nil) error=\(error?.localizedDescription ?? "unknown")")
        if let runtime = runtime(for: peripheral.identifier) {
            runtime.connectionTimer?.invalidate()
            runtime.connectionTimer = nil
            runtime.rssiReadGate.reset()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("peripheral disconnected monitored=\(runtime(for: peripheral.identifier) != nil) error=\(error?.localizedDescription ?? "none")")
        if let runtime = runtime(for: peripheral.identifier) {
            runtime.connectionTimer?.invalidate()
            runtime.connectionTimer = nil
            runtime.rssiReadGate.reset()
            runtime.activeMode = runtime.activeModeTimer != nil
            refreshPublishedMonitoringState()
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let runtime = runtime(for: peripheral.identifier) else { return }
        runtime.rssiReadGate.finish()
        if let error { logRSSIError(error) }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        updateMonitoredPeripheral(rssi, for: runtime.uuid)

        if runtime.activeModeTimer == nil && !settings.passiveMode {
            let anotherDeviceNeedsScan = monitoredUUIDs.contains {
                monitoredRuntimes[$0]?.peripheral == nil
            }
            if !isScanning && !anotherDeviceNeedsScan { centralMgr?.stopScan() }
            let runtimeUUID = runtime.uuid
            runtime.activeModeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let runtime = self.runtime(for: runtimeUUID),
                          let peripheral = runtime.peripheral else { return }
                    if peripheral.state == .connected {
                        self.requestRSSIRead(for: runtime)
                    } else {
                        self.connectMonitoredPeripheral(for: runtime.uuid)
                    }
                }
            }
            if let timer = runtime.activeModeTimer { RunLoop.main.add(timer, forMode: .common) }
            runtime.activeMode = true
            refreshPublishedMonitoringState()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("service discovery failed error=\(error.localizedDescription)")
        } else {
            log("service discovery completed serviceCount=\(peripheral.services?.count ?? 0)")
        }
        for service in peripheral.services ?? [] where service.uuid == deviceInformationUUID {
            peripheral.discoverCharacteristics([manufacturerNameUUID, modelNameUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("characteristic discovery failed service=\(service.uuid.uuidString) error=\(error.localizedDescription)")
        }
        for chara in service.characteristics ?? [] where chara.uuid == manufacturerNameUUID || chara.uuid == modelNameUUID {
            peripheral.readValue(for: chara)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("characteristic value update failed characteristic=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
        }
        guard let value = characteristic.value, let str = String(data: value, encoding: .utf8) else { return }
        guard let device = deviceMap[peripheral.identifier] else { return }
        if characteristic.uuid == manufacturerNameUUID { device.manufacturer = str }
        if characteristic.uuid == modelNameUUID { device.model = str }
        if device.model != nil, !isMonitoredPeripheral(peripheral) {
            centralMgr?.cancelPeripheralConnection(peripheral)
        }
        requestDeviceRefresh()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        log("peripheral services modified invalidated=\(invalidatedServices.map { $0.uuid.uuidString }.joined(separator: ","))")
        peripheral.discoverServices([deviceInformationUUID])
    }

    // MARK: Screen control

    func lockNow() {
        guard !isScreenLocked() else {
            log("manual lock skipped reason=alreadyLocked")
            return
        }
        log("manual lock requested")
        manualLock = true
        cancelUnlockAttempt()
        pauseNowPlaying()
        lockOrSaveScreen(source: .manual)
    }

    private func lockOrSaveScreen(source: ScreenLockHistorySource) {
        pendingLockSource = source
        pendingLockSourceExpiresAt = Date().addingTimeInterval(15)
        log("locking screen useScreensaver=\(settings.useScreensaver) turnOffScreen=\(settings.turnOffScreen)")
        if settings.useScreensaver {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
        } else {
            bleLockScreenViaShortcut()
            if settings.turnOffScreen { bleSleepDisplay() }
        }
    }

    private func recordScreenLock(at date: Date) {
        let source: ScreenLockHistorySource
        if let pendingLockSource, date <= pendingLockSourceExpiresAt {
            source = pendingLockSource
        } else {
            source = .manual
        }
        pendingLockSource = nil
        pendingLockSourceExpiresAt = .distantPast

        guard settings.screenLockHistory.recordLock(at: date, source: source) else {
            log("screen lock history ignored reason=duplicate source=\(source.rawValue)")
            return
        }
        log("screen lock history recorded source=\(source.rawValue) at=\(date.timeIntervalSince1970)")
        notifyChange()
    }

    private func recordScreenUnlock(at date: Date, source: ScreenLockHistorySource) {
        guard settings.screenLockHistory.recordUnlock(at: date, source: source) else {
            log("screen unlock history ignored reason=unpaired-or-duplicate source=\(source.rawValue)")
            return
        }
        log("screen unlock history recorded source=\(source.rawValue) at=\(date.timeIntervalSince1970)")
        notifyChange()
    }

    func clearScreenLockHistory() {
        guard !settings.screenLockHistory.entries.isEmpty else { return }
        settings.screenLockHistory.clear()
        log("screen lock history cleared")
        notifyChange()
    }

    private func screenLockState() -> BLEScreenLockState {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return .unknown
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? NSNumber {
            return locked.boolValue ? .locked : .unlocked
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
            return locked == 1 ? .locked : .unlocked
        }
        return .unknown
    }

    func isScreenLocked() -> Bool {
        screenLockState() == .locked
    }

    private func tryUnlockScreen(trigger: String = "unspecified") {
        guard settings.isEnabled else {
            log("unlock skipped trigger=\(trigger) reason=featureDisabled")
            return
        }
        if manualLock {
            log("unlock skipped trigger=\(trigger) reason=manualLock")
            return
        }
        guard presence else {
            log("unlock skipped trigger=\(trigger) reason=notPresent")
            return
        }
        guard settings.unlockRSSI != Self.unlockDisabled else {
            log("unlock skipped trigger=\(trigger) reason=unlockRSSIDisabled")
            return
        }
        guard !systemSleep else {
            log("unlock skipped trigger=\(trigger) reason=systemSleep")
            return
        }
        log("unlock requested trigger=\(trigger) displaySleep=\(displaySleep) inScreensaver=\(inScreensaver) lastRSSI=\(lastRSSI.map(String.init) ?? "none")")

        if inScreensaver {
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
        }

        guard !settings.wakeWithoutUnlocking else {
            log("unlock skipped trigger=\(trigger) reason=wakeWithoutUnlocking")
            return
        }

        // Do not make the unlock depend on a single display-wake notification.
        // A keyboard wake can make the display usable before AppKit delivers
        // `screensDidWake`, and the opposite ordering is also possible.
        scheduleUnlockAttempt(trigger: trigger)
    }

    private func displayIsReadyForUnlock() -> Bool {
        // `displaySleep` is maintained from notifications and is therefore a
        // useful hint, but it can remain stale when the user wakes the Mac by
        // pressing a key. Query the display as well so that wake recovery can
        // proceed even when that notification was missed.
        let isAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        log("display readiness checked asleep=\(isAsleep) notificationSleep=\(displaySleep) systemSleep=\(systemSleep)")
        if !isAsleep, displaySleep {
            // Repair the notification-derived state as soon as the display
            // proves that it has actually woken.
            displaySleep = false
            wakeRetryTask?.cancel()
            wakeRetryTask = nil
        }
        return !isAsleep
    }

    private func cancelUnlockAttempt(reason: String = "unspecified") {
        if unlockAttemptTask != nil {
            log("unlock attempt cancelled reason=\(reason)")
        }
        unlockAttemptGeneration &+= 1
        unlockAttemptTask?.cancel()
        unlockAttemptTask = nil
        lastUnlockRequestAt = 0
    }

    private func formattedUnlockAge(_ age: TimeInterval?) -> String {
        guard let age else { return "none" }
        return String(format: "%.3f", age)
    }

    private func recentAutomaticUnlockRequestAge(at date: Date) -> TimeInterval? {
        guard lastAutomaticUnlockRequestAt > 0 else { return nil }
        let age = date.timeIntervalSince1970 - lastAutomaticUnlockRequestAt
        guard age >= 0, age < 15 else { return nil }
        return age
    }

    private func confirmAutomaticUnlock(source: String, eventDate: Date = Date()) {
        let now = Date().timeIntervalSince1970
        let state = screenLockState()
        guard BLEUnlockConfirmation.isConfirmed(screenState: state) else {
            log("unlock confirmation rejected source=\(source) screenState=\(state.rawValue)")
            return
        }

        let requestAge = lastUnlockRequestAt > 0 ? now - lastUnlockRequestAt : nil
        if now - lastAutomaticUnlockConfirmationAt < 2 {
            log("unlock confirmation already handled source=\(source) requestAge=\(formattedUnlockAge(requestAge))")
            lastUnlockRequestAt = 0
            lastAutomaticUnlockRequestAt = 0
            manualLock = false
            return
        }

        lastAutomaticUnlockConfirmationAt = now
        log("screen unlock confirmed source=\(source) screenState=unlocked requestAge=\(formattedUnlockAge(requestAge))")
        if recentAutomaticUnlockRequestAge(at: eventDate) != nil {
            recordScreenUnlock(at: eventDate, source: .automatic)
        }
        lastUnlockRequestAt = 0
        lastAutomaticUnlockRequestAt = 0
        manualLock = false
        playNowPlaying()
        runScript("unlocked")
    }

    private func scheduleUnlockAttempt(trigger: String) {
        guard unlockAttemptTask == nil else {
            log("unlock attempt already scheduled trigger=\(trigger)")
            return
        }

        let generation = unlockAttemptGeneration
        log("unlock attempt scheduled trigger=\(trigger) deadlines=\(BLEUnlockAttemptPlan.standard.deadlines)")
        unlockAttemptTask = Task { [weak self] in
            var previousDeadline: TimeInterval = 0
            var progress = BLEUnlockAttemptProgress(plan: .standard)
            while let deadline = progress.nextDeadline {
                let wait = deadline - previousDeadline
                if wait > 0 {
                    try? await Task.sleep(for: .milliseconds(Int64(wait * 1_000)))
                }
                guard !Task.isCancelled, let self else { return }
                guard self.unlockAttemptGeneration == generation else {
                    self.log("unlock attempt stopped deadline=\(deadline) reason=generationChanged")
                    return
                }
                guard !self.manualLock, self.presence,
                      self.settings.unlockRSSI != Self.unlockDisabled,
                      !self.settings.wakeWithoutUnlocking,
                      !self.systemSleep else {
                    self.log("unlock attempt stopped deadline=\(deadline) reason=stateChanged manualLock=\(self.manualLock) presence=\(self.presence) systemSleep=\(self.systemSleep)")
                    return
                }
                self.log("unlock attempt checking deadline=\(deadline)")

                // Keep waiting while the display is genuinely asleep. This
                // handles both proximity-wake and a later keyboard wake.
                if !self.displayIsReadyForUnlock() {
                    self.log("unlock attempt deferred deadline=\(deadline) reason=displayAsleep")
                    progress.skipCurrentDeadline()
                    previousDeadline = deadline
                    continue
                }

                let screenState = self.screenLockState()
                self.log("unlock screen state sampled deadline=\(deadline) state=\(screenState.rawValue)")
                switch progress.nextAction(screenState: screenState) {
                case .confirmed:
                    self.unlockAttemptTask = nil
                    self.confirmAutomaticUnlock(source: "screenState deadline=\(deadline)")
                    return
                case .stateUnavailable:
                    self.log("unlock attempt deferred deadline=\(deadline) reason=screenStateUnavailable")
                case .exhausted:
                    self.log("unlock attempt exhausted before posting deadline=\(deadline)")
                case .postPassword(let attemptDeadline):
                    guard let password = self.fetchPassword(warn: true) else {
                        self.log("unlock attempt stopped deadline=\(attemptDeadline) reason=passwordUnavailable")
                        return
                    }
                    let requestTimestamp = Date().timeIntervalSince1970
                    self.lastUnlockRequestAt = requestTimestamp
                    self.lastAutomaticUnlockRequestAt = requestTimestamp
                    self.log("posting unlock key events deadline=\(attemptDeadline) screenState=locked accessibilityTrusted=\(AXIsProcessTrusted())")
                    self.fakeKeyStrokes(password)
                    self.log("unlock key events posted deadline=\(attemptDeadline) screenStateAfterPost=\(self.screenLockState().rawValue)")
                }
                previousDeadline = deadline
            }

            guard let self, self.unlockAttemptGeneration == generation else { return }
            self.unlockAttemptTask = nil
            self.log("unlock attempt exhausted without unlock screenState=\(self.screenLockState().rawValue)")
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        log("presence handler value=\(presence) reason=\(reason) currentState=\(self.presence) lastRSSI=\(lastRSSI.map(String.init) ?? "none") displaySleep=\(displaySleep) systemSleep=\(systemSleep)")
        guard settings.isEnabled else {
            log("presence action skipped reason=featureDisabled")
            return
        }
        if presence {
            if settings.unlockRSSI != Self.unlockDisabled {
                if displaySleep && !systemSleep && settings.wakeOnProximity {
                    log("waking display due to proximity reason=\(reason)")
                    bleWakeDisplay()
                    wakeRetryTask?.cancel()
                    wakeRetryTask = Task { [weak self] in
                        // A missing screensDidWake notification must not leave
                        // an endless user-activity assertion running overnight.
                        for _ in 0..<10 {
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled, self != nil else { return }
                            bleWakeDisplay()
                        }
                        self?.wakeRetryTask = nil
                        self?.log("display wake retry task finished")
                    }
                }
                tryUnlockScreen(trigger: "presence-\(reason)")
            } else {
                log("presence close observed but auto-unlock is disabled")
            }
        } else {
            wakeRetryTask?.cancel(); wakeRetryTask = nil
            cancelUnlockAttempt(reason: "presence-\(reason)")
            if !isScreenLocked() && settings.lockRSSI != Self.lockDisabled {
                log("locking due to presence loss reason=\(reason)")
                pauseNowPlaying()
                lockOrSaveScreen(source: .automatic)
                runScript(reason)
            } else {
                log("presence loss did not lock screen alreadyLocked=\(isScreenLocked()) lockRSSIDisabled=\(settings.lockRSSI == Self.lockDisabled)")
            }
            manualLock = false
        }
    }

    private func fakeKeyStrokes(_ string: String) {
        log("posting password key events")
        let src = CGEventSource(stateID: .hidSystemState)
        let per = 20
        let utf16 = string.utf16
        var index = utf16.startIndex
        for offset in stride(from: 0, to: utf16.count, by: per) {
            let len = offset + per < utf16.count ? per : utf16.count - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            for i in 0..<len {
                buffer[i] = utf16[index]
                index = utf16.index(after: index)
            }
            let down = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            down?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
            buffer.deallocate()
        }
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: Keychain password

    private var keychainService: String { Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier }
    private var keychainAccount: String { NSUserName() }

    private var keychainServices: [String] {
        var services = [keychainService]
        for service in AppIdentity.knownBundleIdentifiers where !services.contains(service) {
            services.append(service)
        }
        return services
    }

    var hasPassword: Bool {
        if let hasPasswordCache { return hasPasswordCache }
        return fetchPassword() != nil
    }

    @discardableResult
    func storePassword(_ password: String) -> Bool {
        let data = password.data(using: .utf8) ?? Data()
        let status = storePasswordData(data, service: keychainService)
        log("password stored in keychain success=\(status)")
        hasPasswordCache = status
        objectWillChange.send()
        return status
    }

    private func storePasswordData(_ data: Data, service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MacPilot BLE Unlock"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func fetchPassword(warn: Bool = false) -> String? {
        if warn {
            log("keychain password lookup started services=\(keychainServices.joined(separator: ","))")
        }
        for service in keychainServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: keychainAccount,
                kSecAttrService as String: service,
                kSecReturnData as String: kCFBooleanTrue!,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status != errSecItemNotFound else { continue }
            log("keychain lookup service=\(service) status=\(status)")
            guard status == errSecSuccess, let data = item as? Data,
                  let password = String(data: data, encoding: .utf8) else { continue }
            if service != keychainService {
                _ = storePasswordData(data, service: keychainService)
            }
            hasPasswordCache = true
            if warn {
                log("keychain password lookup succeeded service=\(service)")
            }
            return password
        }
        hasPasswordCache = false
        if warn {
            log("keychain password lookup failed reason=notFoundOrInaccessible")
        }
        return nil
    }

    // MARK: MediaRemote (optional)

    private func ensureMediaRemote() {
        guard mediaRemoteHandle == nil else { return }
        mediaRemoteHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        guard let handle = mediaRemoteHandle else { return }
        let sendPtr = dlsym(handle, "MRMediaRemoteSendCommand")
        let getPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
        if let sendPtr { mrSendCommand = unsafeBitCast(sendPtr, to: (@convention(c) (Int32, AnyObject?) -> Bool).self) }
        if let getPtr { mrGetPlaying = unsafeBitCast(getPtr, to: (@convention(c) (DispatchQueue, @convention(block) (Bool) -> Void) -> Void).self) }
    }

    private func pauseNowPlaying() {
        guard settings.pauseNowPlaying else { return }
        ensureMediaRemote()
        guard let get = mrGetPlaying else { return }
        get(.main) { [weak self] playing in
            guard let self else { return }
            self.nowPlayingWasPlaying = playing
            if playing { _ = self.mrSendCommand?(1, nil) }
        }
    }

    private func playNowPlaying() {
        guard settings.pauseNowPlaying, nowPlayingWasPlaying else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.nowPlayingWasPlaying = false
            _ = self.mrSendCommand?(0, nil)
        }
    }

    // MARK: Event script

    func runScript(_ arg: String) {
        let scriptsDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Scripts")
        var bundleIdentifiers = [Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier]
        bundleIdentifiers.append(contentsOf: AppIdentity.knownBundleIdentifiers.filter { !bundleIdentifiers.contains($0) })
        guard let file = bundleIdentifiers
            .map({ scriptsDirectory.appendingPathComponent($0).appendingPathComponent("event") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            log("event script not found arg=\(arg)")
            return
        }
        let process = Process()
        process.executableURL = file
        process.arguments = lastRSSI.map { [arg, String($0)] } ?? [arg]
        do {
            try process.run()
            log("event script started arg=\(arg) path=\(file.path)")
        } catch {
            log("event script failed arg=\(arg) error=\(error.localizedDescription)")
        }
    }

    // MARK: Display / system observers

    private var observers: [NSObjectProtocol] = []

    func handleSystemWillSleep() {
        log("system will sleep presence=\(presence) lastRSSI=\(lastRSSI.map(String.init) ?? "none") monitored=\(monitoredUUIDs.count)")
        systemSleep = true
        recoveringFromSystemSleep = true
        wakeRetryTask?.cancel(); wakeRetryTask = nil
        cancelUnlockAttempt()
        systemWakeRecoveryTask?.cancel(); systemWakeRecoveryTask = nil

        // Run-loop timers become immediately overdue after a long sleep. Stop
        // them here so they cannot turn a pre-sleep sample into a false wake
        // decision before CoreBluetooth has produced a fresh RSSI value.
        for runtime in monitoredRuntimes.values {
            runtime.invalidateTimers()
        }
        refreshPublishedMonitoringState()
    }

    private func prepareMonitoringForWakeRecovery() {
        guard settings.isEnabled, hasMonitoredDevice else {
            log("wake recovery preparation skipped enabled=\(settings.isEnabled) monitored=\(hasMonitoredDevice)")
            return
        }
        log("preparing monitoring for system wake recovery")

        for runtime in monitoredRuntimes.values {
            runtime.invalidateTimers()
            runtime.latestRSSIs.removeAll(keepingCapacity: true)
            if let peripheral = runtime.peripheral {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
            runtime.peripheral = nil
            runtime.presence = false
            runtime.lastRSSI = nil
        }
        cancelUnlockAttempt()

        // A CBPeripheral or scan that survived ordinary display sleep can be
        // stale after deep idle. Discard both and wait for a fresh sample.
        centralMgr?.stopScan()
        presence = false
        refreshPublishedMonitoringState()
        log("monitoring reset for system wake recovery")
    }

    private func restartMonitoringAfterWake() {
        guard settings.isEnabled, hasMonitoredDevice else {
            log("monitoring restart after wake skipped enabled=\(settings.isEnabled) monitored=\(hasMonitoredDevice)")
            return
        }
        log("restarting monitoring after system wake")
        ensureCentralManager()
        guard let central = centralMgr, central.state == .poweredOn else {
            log("monitoring restart after wake deferred centralState=\(String(describing: centralMgr?.state))")
            return
        }

        for uuid in monitoredUUIDs {
            let runtime = ensureRuntime(for: uuid)
            if runtime.peripheral == nil,
               let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first {
                runtime.peripheral = peripheral
                if !settings.passiveMode {
                    connectMonitoredPeripheral(for: uuid)
                }
            }
        }

        // CoreBluetooth can continue reporting isScanning after deep idle even
        // though no discoveries arrive. A stop/start creates a fresh session.
        central.stopScan()
        scanForPeripherals()
    }

    private var monitoringNeedsWakeRestart: Bool {
        monitoredUUIDs.contains { monitoredRuntimes[$0]?.lastRSSI == nil }
    }

    func startSystemWakeRecovery(using plan: BLEWakeRecoveryPlan) {
        log("system wake recovery scheduled monitoringDelays=\(plan.monitoringRestartDelays) unlockDelays=\(plan.unlockRetryDelays)")
        recoveringFromSystemSleep = true
        systemWakeRecoveryTask?.cancel()
        systemWakeRecoveryTask = Task { [weak self] in
            let deadlines = Set(plan.monitoringRestartDelays + plan.unlockRetryDelays).sorted()
            var previousDeadline: TimeInterval = 0

            for deadline in deadlines {
                let wait = deadline - previousDeadline
                if wait > 0 {
                    try? await Task.sleep(for: .milliseconds(Int64(wait * 1_000)))
                }
                guard !Task.isCancelled, let self else { return }
                self.log("system wake recovery deadline reached deadline=\(deadline) lastRSSI=\(self.lastRSSI.map(String.init) ?? "none") presence=\(self.presence)")

                if plan.monitoringRestartDelays.contains(deadline), self.monitoringNeedsWakeRestart {
                    self.restartMonitoringAfterWake()
                }
                if plan.unlockRetryDelays.contains(deadline) {
                    self.tryUnlockScreen(trigger: "systemWakeRecovery-\(deadline)")
                }
                previousDeadline = deadline
            }
            self?.recoveringFromSystemSleep = false
            self?.systemWakeRecoveryTask = nil
            self?.log("system wake recovery finished")
            self?.tryUnlockScreen(trigger: "systemWakeRecovery-finished")
        }
    }

    private func handleSystemDidWake() {
        log("system did wake")
        systemSleep = false
        guard let plan = BLEWakeRecoveryPlan.make(
            isEnabled: settings.isEnabled,
            hasMonitoredDevice: hasMonitoredDevice
        ) else {
            log("system wake recovery not needed enabled=\(settings.isEnabled) monitored=\(hasMonitoredDevice)")
            recoveringFromSystemSleep = false
            return
        }

        prepareMonitoringForWakeRecovery()
        startSystemWakeRecovery(using: plan)
    }

    func startObservingSystemState() {
        guard observers.isEmpty else {
            log("system observers already installed count=\(observers.count)")
            return
        }
        log("installing system observers")
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.displaySleep = true
                self.log("display sleep notification received")
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("display wake notification received")
                self?.displaySleep = false
                self?.recoveringFromSystemSleep = false
                self?.wakeRetryTask?.cancel()
                self?.tryUnlockScreen(trigger: "screensDidWake")
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSystemWillSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("system wake notification received")
                self?.handleSystemDidWake()
            }
        })

        let dnc = DistributedNotificationCenter.default
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordScreenLock(at: Date())
            }
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            let eventDate = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                let now = Date().timeIntervalSince1970
                let screenState = self.screenLockState()
                let requestAge = self.recentAutomaticUnlockRequestAge(at: eventDate)
                let confirmationAge = self.lastAutomaticUnlockConfirmationAt > 0 ? now - self.lastAutomaticUnlockConfirmationAt : nil
                self.log("screen unlocked notification received screenState=\(screenState.rawValue) requestAge=\(self.formattedUnlockAge(requestAge)) confirmationAge=\(self.formattedUnlockAge(confirmationAge))")

                guard BLEUnlockConfirmation.isConfirmed(screenState: screenState) else {
                    self.log("screen unlock notification ignored reason=sessionStillLocked")
                    return
                }

                if let requestAge, requestAge >= 0, requestAge < 15 {
                    self.confirmAutomaticUnlock(source: "screenIsUnlockedNotification", eventDate: eventDate)
                    return
                }

                if let confirmationAge, confirmationAge >= 0, confirmationAge < 5 {
                    self.log("screen unlock notification already handled reason=recentConfirmation")
                    self.manualLock = false
                    return
                }

                self.recordScreenUnlock(at: eventDate, source: .manual)
                if self.settings.unlockRSSI != Self.unlockDisabled { self.runScript("intruded") }
                self.playNowPlaying()
                self.log("screen unlock classified as external or manual")
                self.manualLock = false
            }
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.inScreensaver = true
                self?.log("screensaver started")
            }
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.inScreensaver = false
                self?.log("screensaver stopped")
            }
        })
    }
}

// MARK: - Low-level display helpers

func bleLockScreenViaShortcut() {
    // Posts the system "Lock Screen" shortcut (Control-Command-Q).
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 0x0C, keyDown: true)
    down?.flags = [.maskControl, .maskCommand]
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: src, virtualKey: 0x0C, keyDown: false)
    up?.flags = [.maskControl, .maskCommand]
    up?.post(tap: .cghidEventTap)
}

func bleSleepDisplay() {
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
    guard entry != 0 else { return }
    IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanTrue)
    IOObjectRelease(entry)
}

func bleWakeDisplay() {
    var assertionID: IOPMAssertionID = 0
    IOPMAssertionDeclareUserActivity("MacPilot" as CFString, kIOPMUserActiveLocal, &assertionID)
}
