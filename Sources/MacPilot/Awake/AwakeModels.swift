import Foundation

// MARK: - Session models

enum SessionSource: Codable, Equatable, Sendable {
    case manual
    case trigger(UUID)
    case application(bundleID: String)
    case process(name: String)
    case file(URL)
    case automation(identifier: String)

    private enum Kind: String, Codable {
        case manual
        case trigger
        case application
        case process
        case file
        case automation
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
        case bundleID
        case name
        case url
        case identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .manual:
            self = .manual
        case .trigger:
            self = .trigger(try container.decode(UUID.self, forKey: .id))
        case .application:
            self = .application(bundleID: try container.decode(String.self, forKey: .bundleID))
        case .process:
            self = .process(name: try container.decode(String.self, forKey: .name))
        case .file:
            self = .file(try container.decode(URL.self, forKey: .url))
        case .automation:
            self = .automation(identifier: try container.decode(String.self, forKey: .identifier))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode(Kind.manual, forKey: .kind)
        case .trigger(let id):
            try container.encode(Kind.trigger, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .application(let bundleID):
            try container.encode(Kind.application, forKey: .kind)
            try container.encode(bundleID, forKey: .bundleID)
        case .process(let name):
            try container.encode(Kind.process, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .file(let url):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .automation(let identifier):
            try container.encode(Kind.automation, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        }
    }
}

enum SessionEndCondition: Codable, Equatable, Sendable {
    case manual
    case duration(TimeInterval)
    case date(Date)
    case trigger(UUID)
    case applicationTerminates(bundleID: String)
    case processTerminates(name: String)
    case fileInactive(url: URL, timeout: TimeInterval)

    private enum Kind: String, Codable {
        case manual
        case duration
        case date
        case trigger
        case applicationTerminates
        case processTerminates
        case fileInactive
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case duration
        case date
        case id
        case bundleID
        case name
        case url
        case timeout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .manual:
            self = .manual
        case .duration:
            self = .duration(try container.decode(TimeInterval.self, forKey: .duration))
        case .date:
            self = .date(try container.decode(Date.self, forKey: .date))
        case .trigger:
            self = .trigger(try container.decode(UUID.self, forKey: .id))
        case .applicationTerminates:
            self = .applicationTerminates(bundleID: try container.decode(String.self, forKey: .bundleID))
        case .processTerminates:
            self = .processTerminates(name: try container.decode(String.self, forKey: .name))
        case .fileInactive:
            self = .fileInactive(
                url: try container.decode(URL.self, forKey: .url),
                timeout: try container.decode(TimeInterval.self, forKey: .timeout)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode(Kind.manual, forKey: .kind)
        case .duration(let duration):
            try container.encode(Kind.duration, forKey: .kind)
            try container.encode(duration, forKey: .duration)
        case .date(let date):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(date, forKey: .date)
        case .trigger(let id):
            try container.encode(Kind.trigger, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .applicationTerminates(let bundleID):
            try container.encode(Kind.applicationTerminates, forKey: .kind)
            try container.encode(bundleID, forKey: .bundleID)
        case .processTerminates(let name):
            try container.encode(Kind.processTerminates, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .fileInactive(let url, let timeout):
            try container.encode(Kind.fileInactive, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encode(timeout, forKey: .timeout)
        }
    }

    func expirationDate(startedAt: Date) -> Date? {
        switch self {
        case .duration(let duration):
            return startedAt.addingTimeInterval(max(0, duration))
        case .date(let date):
            return date
        case .manual, .trigger, .applicationTerminates, .processTerminates, .fileInactive:
            return nil
        }
    }
}

enum SessionState: String, Codable, Equatable, Sendable {
    case active
    case ended
    case suspended
}

enum ScreenSaverPolicy: String, Codable, Equatable, Sendable {
    case systemDefault
    case prevent
    case custom
}

enum LockPolicy: String, Codable, Equatable, Sendable {
    case systemDefault
    case prevent
    case custom
}

enum MouseMovementPolicy: String, Codable, Equatable, Sendable {
    case disabled
    case enabled
}

struct SessionPolicy: Codable, Equatable, Sendable {
    var preventSystemSleep: Bool
    var preventDisplaySleep: Bool
    var preventClosedLidSleep: Bool
    var screenSaverPolicy: ScreenSaverPolicy
    var lockPolicy: LockPolicy
    var mouseMovementPolicy: MouseMovementPolicy
    /// How this session's timed countdown reacts to system sleep.
    var endCalculation: SessionEndCalculation
    var endOnForcedSleep: Bool
    var allowSystemSleepWhenDisplayOff: Bool
    var blockScreenSaver: Bool
    /// Idle minutes after which this session lifts the screen-saver block.
    var screenSaverIdleMinutes: Int

    static let standard = SessionPolicy(
        preventSystemSleep: true,
        preventDisplaySleep: false,
        preventClosedLidSleep: false,
        screenSaverPolicy: .systemDefault,
        lockPolicy: .systemDefault,
        mouseMovementPolicy: .disabled
    )

    init(
        preventSystemSleep: Bool = true,
        preventDisplaySleep: Bool = false,
        preventClosedLidSleep: Bool = false,
        screenSaverPolicy: ScreenSaverPolicy = .systemDefault,
        lockPolicy: LockPolicy = .systemDefault,
        mouseMovementPolicy: MouseMovementPolicy = .disabled,
        endCalculation: SessionEndCalculation = .timer,
        endOnForcedSleep: Bool = false,
        allowSystemSleepWhenDisplayOff: Bool = false,
        blockScreenSaver: Bool = false,
        screenSaverIdleMinutes: Int = 45
    ) {
        self.preventSystemSleep = preventSystemSleep || preventClosedLidSleep
        self.preventDisplaySleep = preventDisplaySleep
        self.preventClosedLidSleep = preventClosedLidSleep
        self.screenSaverPolicy = screenSaverPolicy
        self.lockPolicy = lockPolicy
        self.mouseMovementPolicy = mouseMovementPolicy
        self.endCalculation = endCalculation
        self.endOnForcedSleep = endOnForcedSleep
        self.allowSystemSleepWhenDisplayOff = allowSystemSleepWhenDisplayOff
        self.blockScreenSaver = blockScreenSaver
        self.screenSaverIdleMinutes = min(max(screenSaverIdleMinutes, 5), 180)
    }

    private enum CodingKeys: String, CodingKey {
        case preventSystemSleep
        case preventDisplaySleep
        case preventClosedLidSleep
        case screenSaverPolicy
        case lockPolicy
        case mouseMovementPolicy
        case endCalculation
        case endOnForcedSleep
        case allowSystemSleepWhenDisplayOff
        case blockScreenSaver
        case screenSaverIdleMinutes
    }

    /// Keeping the Mac running with the lid closed is only meaningful while
    /// the system itself is prevented from idling to sleep, so the two flags
    /// can never disagree.
    mutating func setPreventClosedLidSleep(_ enabled: Bool) {
        preventClosedLidSleep = enabled
        if enabled { preventSystemSleep = true }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            preventSystemSleep: try container.decodeIfPresent(Bool.self, forKey: .preventSystemSleep) ?? true,
            preventDisplaySleep: try container.decodeIfPresent(Bool.self, forKey: .preventDisplaySleep) ?? false,
            preventClosedLidSleep: try container.decodeIfPresent(Bool.self, forKey: .preventClosedLidSleep) ?? false,
            screenSaverPolicy: try container.decodeIfPresent(ScreenSaverPolicy.self, forKey: .screenSaverPolicy) ?? .systemDefault,
            lockPolicy: try container.decodeIfPresent(LockPolicy.self, forKey: .lockPolicy) ?? .systemDefault,
            mouseMovementPolicy: try container.decodeIfPresent(MouseMovementPolicy.self, forKey: .mouseMovementPolicy) ?? .disabled,
            endCalculation: try container.decodeIfPresent(SessionEndCalculation.self, forKey: .endCalculation) ?? .timer,
            endOnForcedSleep: try container.decodeIfPresent(Bool.self, forKey: .endOnForcedSleep) ?? false,
            allowSystemSleepWhenDisplayOff: try container.decodeIfPresent(Bool.self, forKey: .allowSystemSleepWhenDisplayOff) ?? false,
            blockScreenSaver: try container.decodeIfPresent(Bool.self, forKey: .blockScreenSaver) ?? false,
            screenSaverIdleMinutes: try container.decodeIfPresent(Int.self, forKey: .screenSaverIdleMinutes) ?? 45
        )
    }
}

struct AwakeSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var source: SessionSource
    var startedAt: Date
    var endCondition: SessionEndCondition
    var policy: SessionPolicy
    var state: SessionState

    var expectedEndAt: Date? {
        endCondition.expirationDate(startedAt: startedAt)
    }
}

struct DesiredAwakeState: Codable, Equatable, Sendable {
    var preventSystemSleep: Bool
    var preventDisplaySleep: Bool
    var preventClosedLidSleep: Bool

    static let inactive = DesiredAwakeState(
        preventSystemSleep: false,
        preventDisplaySleep: false,
        preventClosedLidSleep: false
    )
}

struct AwakeSafetyPolicy: Codable, Equatable, Sendable {
    var lowBatteryProtectionEnabled: Bool
    var minimumBatteryLevel: Int

    static let standard = AwakeSafetyPolicy(
        lowBatteryProtectionEnabled: true,
        minimumBatteryLevel: 15
    )

    init(lowBatteryProtectionEnabled: Bool = true, minimumBatteryLevel: Int = 15) {
        self.lowBatteryProtectionEnabled = lowBatteryProtectionEnabled
        self.minimumBatteryLevel = min(max(minimumBatteryLevel, 10), 50)
    }

    private enum CodingKeys: String, CodingKey {
        case lowBatteryProtectionEnabled
        case minimumBatteryLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lowBatteryProtectionEnabled: try container.decodeIfPresent(Bool.self, forKey: .lowBatteryProtectionEnabled) ?? true,
            minimumBatteryLevel: try container.decodeIfPresent(Int.self, forKey: .minimumBatteryLevel) ?? 15
        )
    }
}

/// How a timed session computes its end while the Mac sleeps.
enum SessionEndCalculation: String, Codable, Equatable, Sendable {
    /// The countdown keeps running in wall-clock time.
    case timer
    /// The countdown pauses while the Mac is asleep and resumes on wake.
    case pausesDuringSleep
}

/// Settings for the default Awake session that can start automatically
/// when the app launches or when the Mac wakes from sleep. Per-session
/// behavior options live on `SessionPolicy`; these settings cover the
/// session duration, battery warnings, power-adapter behavior, and the
/// automatic starts that apply to every session kind.
struct AwakeDefaultSessionSettings: Codable, Equatable, Sendable {
    /// 0 means the session runs until it is ended manually.
    var durationMinutes: Int
    /// When set, the default session ends at this absolute date instead of
    /// using `durationMinutes`（「直到指定时间」预设）。
    var usesUntilDate: Bool
    /// `nil` 直到用户选择该预设并指定日期；过期日期按手动结束处理。
    var untilDate: Date?
    var warnBeforeBatteryTermination: Bool
    var ignoreBatteryLevelOnExternalPower: Bool
    var restartOnPowerReconnect: Bool
    var autoStartOnLaunch: Bool
    var autoStartOnWake: Bool

    static let standard = AwakeDefaultSessionSettings()

    init(
        durationMinutes: Int = 60,
        usesUntilDate: Bool = false,
        untilDate: Date? = nil,
        warnBeforeBatteryTermination: Bool = false,
        ignoreBatteryLevelOnExternalPower: Bool = true,
        restartOnPowerReconnect: Bool = false,
        autoStartOnLaunch: Bool = false,
        autoStartOnWake: Bool = false
    ) {
        self.durationMinutes = max(0, durationMinutes)
        self.usesUntilDate = usesUntilDate
        self.untilDate = untilDate
        self.warnBeforeBatteryTermination = warnBeforeBatteryTermination
        self.ignoreBatteryLevelOnExternalPower = ignoreBatteryLevelOnExternalPower
        self.restartOnPowerReconnect = restartOnPowerReconnect
        self.autoStartOnLaunch = autoStartOnLaunch
        self.autoStartOnWake = autoStartOnWake
    }

    var endCondition: SessionEndCondition {
        guard usesUntilDate else {
            return durationMinutes > 0 ? .duration(TimeInterval(durationMinutes) * 60) : .manual
        }
        // 日期缺失或已过时退回手动结束，自动启动不会得到一个立刻过期的会话。
        guard let untilDate, untilDate > Date() else { return .manual }
        return .date(untilDate)
    }

    private enum CodingKeys: String, CodingKey {
        case durationMinutes
        case usesUntilDate
        case untilDate
        case warnBeforeBatteryTermination
        case ignoreBatteryLevelOnExternalPower
        case restartOnPowerReconnect
        case autoStartOnLaunch
        case autoStartOnWake
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            durationMinutes: try container.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 60,
            usesUntilDate: try container.decodeIfPresent(Bool.self, forKey: .usesUntilDate) ?? false,
            untilDate: try container.decodeIfPresent(Date.self, forKey: .untilDate),
            warnBeforeBatteryTermination: try container.decodeIfPresent(Bool.self, forKey: .warnBeforeBatteryTermination) ?? false,
            ignoreBatteryLevelOnExternalPower: try container.decodeIfPresent(Bool.self, forKey: .ignoreBatteryLevelOnExternalPower) ?? true,
            restartOnPowerReconnect: try container.decodeIfPresent(Bool.self, forKey: .restartOnPowerReconnect) ?? false,
            autoStartOnLaunch: try container.decodeIfPresent(Bool.self, forKey: .autoStartOnLaunch) ?? false,
            autoStartOnWake: try container.decodeIfPresent(Bool.self, forKey: .autoStartOnWake) ?? false
        )
    }
}

struct AwakeSettings: Codable, Equatable, Sendable {
    var defaultPolicy: SessionPolicy
    var defaultSession: AwakeDefaultSessionSettings
    var safetyPolicy: AwakeSafetyPolicy

    static let standard = AwakeSettings(
        defaultPolicy: .standard,
        defaultSession: .standard,
        safetyPolicy: .standard
    )

    init(
        defaultPolicy: SessionPolicy = .standard,
        defaultSession: AwakeDefaultSessionSettings = .standard,
        safetyPolicy: AwakeSafetyPolicy = .standard
    ) {
        self.defaultPolicy = defaultPolicy
        self.defaultSession = defaultSession
        self.safetyPolicy = safetyPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case defaultPolicy
        case defaultSession
        case safetyPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultPolicy: try container.decodeIfPresent(SessionPolicy.self, forKey: .defaultPolicy) ?? .standard,
            defaultSession: try container.decodeIfPresent(AwakeDefaultSessionSettings.self, forKey: .defaultSession) ?? .standard,
            safetyPolicy: try container.decodeIfPresent(AwakeSafetyPolicy.self, forKey: .safetyPolicy) ?? .standard
        )
    }
}

struct PowerState: Equatable, Sendable {
    var batteryLevel: Double?
    var charging: Bool
    var onExternalPower: Bool

    static let unknown = PowerState(
        batteryLevel: nil,
        charging: false,
        onExternalPower: false
    )

    var batteryLevelPercentage: Int? {
        batteryLevel.map { Int($0.rounded()) }
    }
}
