import Foundation

extension SessionPolicy {
    /// Policy used by the agent presets: keep the system and background work
    /// running with the lid closed, while still letting the display sleep.
    static let agentBackground = SessionPolicy(
        preventSystemSleep: true,
        preventDisplaySleep: false,
        preventClosedLidSleep: true
    )
}

/// First-class shortcuts for the coding agents MacPilot is commonly used with.
///
/// A preset only builds an ordinary `AwakeTrigger`; there is no separate agent
/// trigger model and no custom process-tree inspection.
enum AwakeAgentPreset: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case openCode

    var id: String { rawValue }

    /// Process name matched by the existing `.processRunning` condition.
    var processName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .openCode: "opencode"
        }
    }

    var titleKey: String {
        switch self {
        case .claudeCode: "awakeAgentClaudeCode"
        case .codex: "awakeAgentCodex"
        case .openCode: "awakeAgentOpenCode"
        }
    }

    func makeTrigger(name: String) -> AwakeTrigger {
        AwakeTrigger(
            name: name,
            conditions: [.processRunning(name: processName)],
            sessionPolicy: .agentBackground
        )
    }
}
