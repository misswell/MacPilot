import Foundation

enum ConditionOperator: String, Codable, CaseIterable, Sendable {
    case all
    case any
}

enum NumericComparison: String, Codable, CaseIterable, Sendable {
    case lessThan
    case lessThanOrEqual
    case equal
    case greaterThanOrEqual
    case greaterThan

    func matches(_ lhs: Double, value rhs: Double) -> Bool {
        switch self {
        case .lessThan: lhs < rhs
        case .lessThanOrEqual: lhs <= rhs
        case .equal: lhs == rhs
        case .greaterThanOrEqual: lhs >= rhs
        case .greaterThan: lhs > rhs
        }
    }
}

enum AwakeTriggerMonitorKind: Hashable, Sendable {
    case application
    case process
    case power
    case display
}

struct ApplicationState: Equatable, Sendable {
    var runningBundleIDs: Set<String>
    var frontmostBundleID: String?

    static let unknown = ApplicationState(runningBundleIDs: [], frontmostBundleID: nil)
}

struct ProcessState: Equatable, Sendable {
    var runningNames: Set<String>
    var runningExecutablePaths: Set<String>

    static let unknown = ProcessState(runningNames: [], runningExecutablePaths: [])

    func contains(name: String) -> Bool {
        runningNames.contains(Self.normalizedName(name))
    }

    func contains(executablePath: String) -> Bool {
        runningExecutablePaths.contains(URL(fileURLWithPath: executablePath).standardizedFileURL.path)
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct DisplayInfo: Equatable, Identifiable, Sendable {
    let id: UInt32
    let isBuiltIn: Bool
}

struct DisplayState: Equatable, Sendable {
    var onlineDisplays: [DisplayInfo]
    var externalDisplayCount: Int
    var mirroringActive: Bool

    static let unknown = DisplayState(
        onlineDisplays: [],
        externalDisplayCount: 0,
        mirroringActive: false
    )
}

struct AwakeTriggerSystemState: Equatable, Sendable {
    var application: ApplicationState
    var process: ProcessState
    var power: PowerState
    var display: DisplayState

    static let unknown = AwakeTriggerSystemState(
        application: .unknown,
        process: .unknown,
        power: .unknown,
        display: .unknown
    )
}

enum TriggerConditionConfiguration: Codable, Equatable, Sendable {
    case applicationRunning(bundleID: String)
    case applicationFrontmost(bundleID: String)
    case processRunning(name: String)
    case processExecutable(path: String)
    case powerAdapter(connected: Bool)
    case charging(value: Bool)
    case batteryLevel(comparison: NumericComparison, value: Double)
    case externalDisplay(minimumCount: Int)
    case displayMirroring(active: Bool)

    private enum Kind: String, Codable {
        case applicationRunning
        case applicationFrontmost
        case processRunning
        case processExecutable
        case powerAdapter
        case charging
        case batteryLevel
        case externalDisplay
        case displayMirroring
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case bundleID
        case name
        case path
        case connected
        case value
        case comparison
        case minimumCount
        case active
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .applicationRunning:
            self = .applicationRunning(bundleID: try container.decode(String.self, forKey: .bundleID))
        case .applicationFrontmost:
            self = .applicationFrontmost(bundleID: try container.decode(String.self, forKey: .bundleID))
        case .processRunning:
            self = .processRunning(name: try container.decode(String.self, forKey: .name))
        case .processExecutable:
            self = .processExecutable(path: try container.decode(String.self, forKey: .path))
        case .powerAdapter:
            self = .powerAdapter(connected: try container.decode(Bool.self, forKey: .connected))
        case .charging:
            self = .charging(value: try container.decode(Bool.self, forKey: .value))
        case .batteryLevel:
            self = .batteryLevel(
                comparison: try container.decode(NumericComparison.self, forKey: .comparison),
                value: try container.decode(Double.self, forKey: .value)
            )
        case .externalDisplay:
            self = .externalDisplay(minimumCount: try container.decode(Int.self, forKey: .minimumCount))
        case .displayMirroring:
            self = .displayMirroring(active: try container.decode(Bool.self, forKey: .active))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .applicationRunning(let bundleID):
            try container.encode(Kind.applicationRunning, forKey: .kind)
            try container.encode(bundleID, forKey: .bundleID)
        case .applicationFrontmost(let bundleID):
            try container.encode(Kind.applicationFrontmost, forKey: .kind)
            try container.encode(bundleID, forKey: .bundleID)
        case .processRunning(let name):
            try container.encode(Kind.processRunning, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .processExecutable(let path):
            try container.encode(Kind.processExecutable, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .powerAdapter(let connected):
            try container.encode(Kind.powerAdapter, forKey: .kind)
            try container.encode(connected, forKey: .connected)
        case .charging(let value):
            try container.encode(Kind.charging, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .batteryLevel(let comparison, let value):
            try container.encode(Kind.batteryLevel, forKey: .kind)
            try container.encode(comparison, forKey: .comparison)
            try container.encode(value, forKey: .value)
        case .externalDisplay(let minimumCount):
            try container.encode(Kind.externalDisplay, forKey: .kind)
            try container.encode(minimumCount, forKey: .minimumCount)
        case .displayMirroring(let active):
            try container.encode(Kind.displayMirroring, forKey: .kind)
            try container.encode(active, forKey: .active)
        }
    }

    var requiredMonitorKinds: Set<AwakeTriggerMonitorKind> {
        switch self {
        case .applicationRunning, .applicationFrontmost:
            [.application]
        case .processRunning, .processExecutable:
            [.process]
        case .powerAdapter, .charging, .batteryLevel:
            [.power]
        case .externalDisplay, .displayMirroring:
            [.display]
        }
    }

    func matches(_ state: AwakeTriggerSystemState) -> Bool {
        switch self {
        case .applicationRunning(let bundleID):
            return state.application.runningBundleIDs.contains(bundleID)
        case .applicationFrontmost(let bundleID):
            return state.application.frontmostBundleID == bundleID
        case .processRunning(let name):
            return state.process.contains(name: name)
        case .processExecutable(let path):
            return state.process.contains(executablePath: path)
        case .powerAdapter(let connected):
            return state.power.onExternalPower == connected
        case .charging(let value):
            return state.power.charging == value
        case .batteryLevel(let comparison, let value):
            guard let batteryLevel = state.power.batteryLevel else { return false }
            return comparison.matches(batteryLevel, value: value)
        case .externalDisplay(let minimumCount):
            return state.display.externalDisplayCount >= max(0, minimumCount)
        case .displayMirroring(let active):
            return state.display.mirroringActive == active
        }
    }

    var summaryValue: String {
        switch self {
        case .applicationRunning(let bundleID), .applicationFrontmost(let bundleID): bundleID
        case .processRunning(let name): name
        case .processExecutable(let path): path
        case .powerAdapter(let connected): connected ? "connected" : "disconnected"
        case .charging(let value): value ? "charging" : "not charging"
        case .batteryLevel(let comparison, let value): comparison.rawValue + " " + String(value)
        case .externalDisplay(let minimumCount): String(minimumCount)
        case .displayMirroring(let active): active ? "active" : "inactive"
        }
    }
}

struct TriggerTimingPolicy: Codable, Equatable, Sendable {
    var activationDelay: TimeInterval
    var deactivationDelay: TimeInterval

    static let standard = TriggerTimingPolicy(activationDelay: 0, deactivationDelay: 0)

    init(activationDelay: TimeInterval = 0, deactivationDelay: TimeInterval = 0) {
        self.activationDelay = max(0, activationDelay)
        self.deactivationDelay = max(0, deactivationDelay)
    }
}

struct AwakeTrigger: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var enabled: Bool
    var priority: Int
    var operatorType: ConditionOperator
    var conditions: [TriggerConditionConfiguration]
    var sessionPolicy: SessionPolicy
    var timingPolicy: TriggerTimingPolicy

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        priority: Int = 0,
        operatorType: ConditionOperator = .all,
        conditions: [TriggerConditionConfiguration],
        sessionPolicy: SessionPolicy = .standard,
        timingPolicy: TriggerTimingPolicy = .standard
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.operatorType = operatorType
        self.conditions = conditions
        self.sessionPolicy = sessionPolicy
        self.timingPolicy = timingPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case priority
        case operatorType
        case conditions
        case sessionPolicy
        case timingPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Awake Trigger",
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            priority: try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0,
            operatorType: try container.decodeIfPresent(ConditionOperator.self, forKey: .operatorType) ?? .all,
            conditions: try container.decodeIfPresent([TriggerConditionConfiguration].self, forKey: .conditions) ?? [],
            sessionPolicy: try container.decodeIfPresent(SessionPolicy.self, forKey: .sessionPolicy) ?? .standard,
            timingPolicy: try container.decodeIfPresent(TriggerTimingPolicy.self, forKey: .timingPolicy) ?? .standard
        )
    }

    var requiredMonitorKinds: Set<AwakeTriggerMonitorKind> {
        conditions.reduce(into: Set<AwakeTriggerMonitorKind>()) { result, condition in
            result.formUnion(condition.requiredMonitorKinds)
        }
    }

    func matches(_ state: AwakeTriggerSystemState) -> Bool {
        guard enabled, !conditions.isEmpty else { return false }
        switch operatorType {
        case .all:
            return conditions.allSatisfy { $0.matches(state) }
        case .any:
            return conditions.contains { $0.matches(state) }
        }
    }
}
