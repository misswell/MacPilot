import AppKit
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

struct BLEUnlockSettings: Codable {
    var isEnabled: Bool = false
    var monitoredDeviceUUID: String?
    var monitoredDeviceName: String?
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
    private var monitoredPeripheral: CBPeripheral?
    private var proximityTimer: Timer?
    private var signalTimer: Timer?
    private var activeModeTimer: Timer?
    private var connectionTimer: Timer?
    private var wakeRetryTask: Task<Void, Never>?
    private var systemWakeRecoveryTask: Task<Void, Never>?
    private var latestRSSIs: [Double] = []
    private let latestN = 5
    private var hasPasswordCache: Bool?

    private var displaySleep = false
    private var systemSleep = false
    private var recoveringFromSystemSleep = false
    private var manualLock = false
    private var inScreensaver = false
    private var unlockedAt: TimeInterval = 0
    private var nowPlayingWasPlaying = false

    var isRecoveringFromSystemSleep: Bool { recoveringFromSystemSleep }

    // MediaRemote (private framework, loaded lazily).
    private var mediaRemoteHandle: UnsafeMutableRawPointer?
    private var mrSendCommand: (@convention(c) (Int32, AnyObject?) -> Bool)?
    private var mrGetPlaying: (@convention(c) (DispatchQueue, @convention(block) (Bool) -> Void) -> Void)?

    // MARK: Settings mutations

    private func notifyChange() {
        objectWillChange.send()
        persist?()
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            if let uuid = monitoredUUID {
                ensureCentralManager()
                if centralMgr?.state == .poweredOn { startMonitor(uuid) }
            }
        } else {
            stopMonitoring()
        }
        notifyChange()
    }

    func activateFromConfiguration() {
        guard settings.isEnabled else { return }
        ensureCentralManager()
        if let uuid = monitoredUUID { startMonitor(uuid) }
    }

    func setLockRSSI(_ value: Int) { settings.lockRSSI = value; notifyChange() }
    func setUnlockRSSI(_ value: Int) { settings.unlockRSSI = value; notifyChange() }
    func setProximityTimeout(_ value: Int) { settings.proximityTimeout = value; notifyChange() }
    func setSignalTimeout(_ value: Int) { settings.signalTimeout = value; notifyChange() }
    func setThresholdRSSI(_ value: Int) { settings.thresholdRSSI = value; notifyChange() }
    func setWakeOnProximity(_ value: Bool) { settings.wakeOnProximity = value; notifyChange() }
    func setWakeWithoutUnlocking(_ value: Bool) { settings.wakeWithoutUnlocking = value; notifyChange() }
    func setPauseNowPlaying(_ value: Bool) { settings.pauseNowPlaying = value; notifyChange() }
    func setUseScreensaver(_ value: Bool) { settings.useScreensaver = value; notifyChange() }
    func setTurnOffScreen(_ value: Bool) { settings.turnOffScreen = value; notifyChange() }

    func setPassiveMode(_ value: Bool) {
        settings.passiveMode = value
        applyPassiveMode()
        notifyChange()
    }

    func selectDevice(_ uuid: UUID) {
        deviceMap[uuid]?.resolveIdentity()
        let selectedName = deviceMap[uuid]?.displayName
        stopScanning()
        settings.monitoredDeviceUUID = uuid.uuidString
        settings.monitoredDeviceName = selectedName
        connected = false
        presence = false
        ensureCentralManager()
        startMonitor(uuid)
        notifyChange()
    }

    func applyLoadedSettings(_ loaded: BLEUnlockSettings) {
        settings = loaded
        if let uuidString = loaded.monitoredDeviceUUID, let uuid = UUID(uuidString: uuidString) {
            monitoredUUID = uuid
        }
        objectWillChange.send()
    }

    // MARK: Lifecycle

    func ensureCentralManager() {
        guard centralMgr == nil else { return }
        centralMgr = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func startScanning() {
        ensureCentralManager()
        isScanning = true
        startScanCleanupTimer()
        scanForPeripherals()
    }

    func stopScanning() {
        isScanning = false
        scanCleanupTimer?.invalidate()
        scanCleanupTimer = nil
        clearDiscoveredDevices()
        if activeModeTimer == nil && monitoredUUID == nil { centralMgr?.stopScan() }
    }

    private func stopMonitoring() {
        isScanning = false
        activeModeTimer?.invalidate(); activeModeTimer = nil
        proximityTimer?.invalidate(); proximityTimer = nil
        signalTimer?.invalidate(); signalTimer = nil
        connectionTimer?.invalidate(); connectionTimer = nil
        scanCleanupTimer?.invalidate(); scanCleanupTimer = nil
        deviceRefreshTask?.cancel(); deviceRefreshTask = nil
        wakeRetryTask?.cancel(); wakeRetryTask = nil
        systemWakeRecoveryTask?.cancel(); systemWakeRecoveryTask = nil
        centralMgr?.stopScan()
        clearDiscoveredDevices()
        if let p = monitoredPeripheral { centralMgr?.cancelPeripheralConnection(p) }
        monitoredPeripheral = nil
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
        for peripheral in discoveredPeripherals where peripheral !== monitoredPeripheral {
            centralMgr?.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
        }
    }

    private func scanForPeripherals() {
        guard let central = centralMgr, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func applyPassiveMode() {
        if settings.passiveMode {
            activeModeTimer?.invalidate(); activeModeTimer = nil
            if let p = monitoredPeripheral { centralMgr?.cancelPeripheralConnection(p) }
        }
        scanForPeripherals()
    }

    func startMonitor(_ uuid: UUID) {
        if let p = monitoredPeripheral { centralMgr?.cancelPeripheralConnection(p) }
        monitoredUUID = uuid
        proximityTimer?.invalidate()
        resetSignalTimer()
        presence = true
        monitoredPeripheral = nil
        activeModeTimer?.invalidate(); activeModeTimer = nil
        scanForPeripherals()
    }

    private func resetSignalTimer() {
        signalTimer?.invalidate()
        signalTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.signalTimeout), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastRSSI = nil
                self.connected = false
                self.activeMode = false
                if self.presence {
                    self.presence = false
                    self.updatePresence(presence: false, reason: "lost")
                }
            }
        }
        RunLoop.main.add(signalTimer!, forMode: .common)
    }

    private func estimatedRSSI(_ rssi: Int) -> Int {
        latestRSSIs.append(Double(rssi))
        if latestRSSIs.count > latestN { latestRSSIs.removeFirst() }
        let mean = latestRSSIs.reduce(0, +) / Double(latestRSSIs.count)
        return Int(mean)
    }

    private func updateMonitoredPeripheral(_ rssi: Int) {
        let unlockThreshold = settings.unlockRSSI == Self.unlockDisabled ? settings.lockRSSI : settings.unlockRSSI
        if rssi >= unlockThreshold && !presence {
            presence = true
            updatePresence(presence: true, reason: "close")
            latestRSSIs.removeAll()
        }

        let estimated = estimatedRSSI(rssi)
        lastRSSI = estimated
        activeMode = activeModeTimer != nil

        let lockThreshold = settings.lockRSSI == Self.lockDisabled ? settings.unlockRSSI : settings.lockRSSI
        if estimated >= lockThreshold {
            proximityTimer?.invalidate()
            proximityTimer = nil
        } else if presence && proximityTimer == nil {
            proximityTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.proximityTimeout), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.presence = false
                    self.updatePresence(presence: false, reason: "away")
                    self.proximityTimer = nil
                }
            }
            RunLoop.main.add(proximityTimer!, forMode: .common)
        }
        resetSignalTimer()
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
        for device in stale {
            deviceMap.removeValue(forKey: device.uuid)
            if let peripheral = device.peripheral { centralMgr?.cancelPeripheralConnection(peripheral) }
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

    private func connectMonitoredPeripheral() {
        guard let p = monitoredPeripheral else { return }
        p.readRSSI()
        guard p.state == .disconnected else { return }
        centralMgr?.connect(p, options: nil)
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.monitoredPeripheral, p.state == .connecting else { return }
                self.centralMgr?.cancelPeripheralConnection(p)
            }
        }
        if let timer = connectionTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothPoweredOn = true
            bluetoothPowerWarned = false
            if monitoredUUID != nil || isScanning { scanForPeripherals() }
        case .poweredOff:
            bluetoothPoweredOn = false
            presence = false
            signalTimer?.invalidate(); signalTimer = nil
            if !bluetoothPowerWarned {
                bluetoothPowerWarned = true
            }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue

        if let uuid = monitoredUUID, peripheral.identifier == uuid {
            if monitoredPeripheral == nil { monitoredPeripheral = peripheral }
            if activeModeTimer == nil {
                updateMonitoredPeripheral(rssi)
                if !settings.passiveMode { connectMonitoredPeripheral() }
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
        if device.bluetoothName == nil, peripheral.name == nil, rssi >= -55 {
            central.connect(peripheral, options: nil)
        }
        requestDeviceRefresh()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isScanning || peripheral === monitoredPeripheral else {
            central.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
            return
        }
        peripheral.delegate = self
        if isScanning { peripheral.discoverServices([deviceInformationUUID]) }
        if peripheral == monitoredPeripheral && !settings.passiveMode {
            connectionTimer?.invalidate(); connectionTimer = nil
            peripheral.readRSSI()
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard peripheral == monitoredPeripheral else { return }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        updateMonitoredPeripheral(rssi)

        if activeModeTimer == nil && !settings.passiveMode {
            if !isScanning { centralMgr?.stopScan() }
            activeModeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let p = self.monitoredPeripheral {
                        if p.state == .connected { p.readRSSI() } else { self.connectMonitoredPeripheral() }
                    }
                }
            }
            if let timer = activeModeTimer { RunLoop.main.add(timer, forMode: .common) }
            activeMode = true
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == deviceInformationUUID {
            peripheral.discoverCharacteristics([manufacturerNameUUID, modelNameUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for chara in service.characteristics ?? [] where chara.uuid == manufacturerNameUUID || chara.uuid == modelNameUUID {
            peripheral.readValue(for: chara)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value, let str = String(data: value, encoding: .utf8) else { return }
        guard let device = deviceMap[peripheral.identifier] else { return }
        if characteristic.uuid == manufacturerNameUUID { device.manufacturer = str }
        if characteristic.uuid == modelNameUUID { device.model = str }
        if device.model != nil, device.peripheral !== monitoredPeripheral {
            centralMgr?.cancelPeripheralConnection(peripheral)
        }
        requestDeviceRefresh()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        peripheral.discoverServices([deviceInformationUUID])
    }

    // MARK: Screen control

    func lockNow() {
        guard !isScreenLocked() else { return }
        manualLock = true
        pauseNowPlaying()
        lockOrSaveScreen()
    }

    private func lockOrSaveScreen() {
        if settings.useScreensaver {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
        } else {
            bleLockScreenViaShortcut()
            if settings.turnOffScreen { bleSleepDisplay() }
        }
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let locked = dict["CGSSessionScreenIsLocked"] as? Int {
            return locked == 1
        }
        return false
    }

    private func tryUnlockScreen() {
        guard !manualLock, presence,
              settings.unlockRSSI != Self.unlockDisabled,
              !systemSleep, !displaySleep, !recoveringFromSystemSleep else { return }

        if inScreensaver {
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
        }

        guard !settings.wakeWithoutUnlocking else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard self.isScreenLocked() else { return }
            guard let password = self.fetchPassword(warn: true) else { return }
            self.unlockedAt = Date().timeIntervalSince1970
            self.fakeKeyStrokes(password)
            self.playNowPlaying()
            self.runScript("unlocked")
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        if presence {
            if settings.unlockRSSI != Self.unlockDisabled {
                if displaySleep && !systemSleep && !recoveringFromSystemSleep && settings.wakeOnProximity {
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
                    }
                }
                tryUnlockScreen()
            }
        } else {
            if !isScreenLocked() && settings.lockRSSI != Self.lockDisabled {
                pauseNowPlaying()
                lockOrSaveScreen()
                runScript(reason)
            }
            manualLock = false
        }
    }

    private func fakeKeyStrokes(_ string: String) {
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
            guard status == errSecSuccess, let data = item as? Data,
                  let password = String(data: data, encoding: .utf8) else { continue }
            if service != keychainService {
                _ = storePasswordData(data, service: keychainService)
            }
            hasPasswordCache = true
            return password
        }
        hasPasswordCache = false
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
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return }
        let process = Process()
        process.executableURL = file
        process.arguments = lastRSSI.map { [arg, String($0)] } ?? [arg]
        try? process.run()
    }

    // MARK: Display / system observers

    private var observers: [NSObjectProtocol] = []

    func handleSystemWillSleep() {
        systemSleep = true
        recoveringFromSystemSleep = true
        wakeRetryTask?.cancel(); wakeRetryTask = nil
        systemWakeRecoveryTask?.cancel(); systemWakeRecoveryTask = nil

        // Run-loop timers become immediately overdue after a long sleep. Stop
        // them here so they cannot turn a pre-sleep sample into a false wake
        // decision before CoreBluetooth has produced a fresh RSSI value.
        activeModeTimer?.invalidate(); activeModeTimer = nil
        proximityTimer?.invalidate(); proximityTimer = nil
        signalTimer?.invalidate(); signalTimer = nil
        connectionTimer?.invalidate(); connectionTimer = nil
        activeMode = false
    }

    private func prepareMonitoringForWakeRecovery() {
        guard settings.isEnabled, monitoredUUID != nil else { return }

        activeModeTimer?.invalidate(); activeModeTimer = nil
        proximityTimer?.invalidate(); proximityTimer = nil
        signalTimer?.invalidate(); signalTimer = nil
        connectionTimer?.invalidate(); connectionTimer = nil
        latestRSSIs.removeAll()

        // A CBPeripheral or scan that survived ordinary display sleep can be
        // stale after deep idle. Discard both and wait for a fresh sample.
        if let peripheral = monitoredPeripheral {
            centralMgr?.cancelPeripheralConnection(peripheral)
        }
        monitoredPeripheral = nil
        centralMgr?.stopScan()
        presence = false
        lastRSSI = nil
        connected = false
        activeMode = false
    }

    private func restartMonitoringAfterWake() {
        guard settings.isEnabled, let uuid = monitoredUUID else { return }
        ensureCentralManager()
        guard let central = centralMgr, central.state == .poweredOn else { return }

        if monitoredPeripheral == nil,
           let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            monitoredPeripheral = peripheral
            if !settings.passiveMode {
                connectMonitoredPeripheral()
            }
        }

        // CoreBluetooth can continue reporting isScanning after deep idle even
        // though no discoveries arrive. A stop/start creates a fresh session.
        central.stopScan()
        scanForPeripherals()
    }

    func startSystemWakeRecovery(using plan: BLEWakeRecoveryPlan) {
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

                if plan.monitoringRestartDelays.contains(deadline), self.lastRSSI == nil {
                    self.restartMonitoringAfterWake()
                }
                if plan.unlockRetryDelays.contains(deadline) {
                    self.tryUnlockScreen()
                }
                previousDeadline = deadline
            }
            self?.recoveringFromSystemSleep = false
            self?.systemWakeRecoveryTask = nil
            self?.tryUnlockScreen()
        }
    }

    private func handleSystemDidWake() {
        systemSleep = false
        guard let plan = BLEWakeRecoveryPlan.make(
            isEnabled: settings.isEnabled,
            hasMonitoredDevice: monitoredUUID != nil
        ) else {
            recoveringFromSystemSleep = false
            return
        }

        prepareMonitoringForWakeRecovery()
        startSystemWakeRecovery(using: plan)
    }

    func startObservingSystemState() {
        guard observers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.displaySleep = true } })
        observers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaySleep = false
                self?.recoveringFromSystemSleep = false
                self?.wakeRetryTask?.cancel()
                self?.tryUnlockScreen()
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.handleSystemWillSleep() } })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemDidWake()
            }
        })

        let dnc = DistributedNotificationCenter.default
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                if Date().timeIntervalSince1970 >= self.unlockedAt + 10 {
                    if self.settings.unlockRSSI != Self.unlockDisabled { self.runScript("intruded") }
                    self.playNowPlaying()
                }
                self.manualLock = false
            }
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.inScreensaver = true } })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.inScreensaver = false } })
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
