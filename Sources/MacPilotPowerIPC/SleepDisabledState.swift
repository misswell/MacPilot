import Foundation

/// What the helper remembers across launches so it can restore the user's
/// original power configuration after a crash or an app restart.
public struct SleepDisabledRuntimeState: Codable, Equatable, Sendable {
    /// True only while MacPilot itself turned `SleepDisabled` on. When the
    /// setting was already on before MacPilot, this stays false and the helper
    /// never touches it.
    public var macPilotOwnedSleepDisable: Bool
    /// The value observed immediately before MacPilot enabled the setting.
    public var previousSleepDisabled: Bool
    /// Last time the app proved it was alive.
    public var lastHeartbeat: Date?

    public init(
        macPilotOwnedSleepDisable: Bool = false,
        previousSleepDisabled: Bool = false,
        lastHeartbeat: Date? = nil
    ) {
        self.macPilotOwnedSleepDisable = macPilotOwnedSleepDisable
        self.previousSleepDisabled = previousSleepDisabled
        self.lastHeartbeat = lastHeartbeat
    }

    /// No ownership is recorded.
    public static let empty = SleepDisabledRuntimeState()

    /// The value that should be restored when ownership is released.
    public var restoreValue: Bool { previousSleepDisabled }
}

/// The fixed power operation the helper is about to run.
public enum SleepDisabledPlan: Equatable, Sendable {
    /// The system is already in the requested state, or the setting is owned
    /// by somebody else. Do not run `pmset`.
    case noChange
    /// Run `/usr/bin/pmset -a disablesleep 1`.
    case enableByRunningPMSet
    /// Run `/usr/bin/pmset -a disablesleep 0`.
    case disableByRunningPMSet
}

/// Pure decision logic for the helper. Kept free of IOKit / Process so it can
/// be unit tested without ever touching the real power configuration.
public enum SleepDisabledPlanner {
    /// Decides how to honor an "enable" request.
    ///
    /// - If MacPilot already owns the setting, nothing to do (idempotent).
    /// - If the setting is already on but not owned by MacPilot, another tool
    ///   or the user set it: leave it alone and do not claim ownership.
    /// - Otherwise MacPilot turns it on and takes ownership.
    public static func planEnable(
        currentSleepDisabled: Bool,
        state: SleepDisabledRuntimeState
    ) -> SleepDisabledPlan {
        if state.macPilotOwnedSleepDisable { return .noChange }
        if currentSleepDisabled { return .noChange }
        return .enableByRunningPMSet
    }

    /// Decides how to honor a "release" request. Only a setting MacPilot owns
    /// is ever turned off.
    public static func planDisable(
        currentSleepDisabled: Bool,
        state: SleepDisabledRuntimeState
    ) -> SleepDisabledPlan {
        guard state.macPilotOwnedSleepDisable else { return .noChange }
        return currentSleepDisabled ? .disableByRunningPMSet : .noChange
    }

    /// The state to persist after an enable request succeeded.
    public static func stateAfterEnable(
        currentSleepDisabled: Bool,
        state: SleepDisabledRuntimeState,
        now: Date
    ) -> SleepDisabledRuntimeState {
        var updated = state
        updated.lastHeartbeat = now
        guard planEnable(currentSleepDisabled: currentSleepDisabled, state: state) == .enableByRunningPMSet else {
            // We did not change anything, so we own nothing.
            updated.macPilotOwnedSleepDisable = state.macPilotOwnedSleepDisable
            if !state.macPilotOwnedSleepDisable {
                updated.previousSleepDisabled = currentSleepDisabled
            }
            return updated
        }
        updated.macPilotOwnedSleepDisable = true
        updated.previousSleepDisabled = false
        return updated
    }

    /// The state to persist after a release request succeeded.
    public static func stateAfterDisable(
        currentSleepDisabled: Bool,
        state: SleepDisabledRuntimeState
    ) -> SleepDisabledRuntimeState {
        var updated = state
        guard state.macPilotOwnedSleepDisable else { return updated }
        updated.macPilotOwnedSleepDisable = false
        updated.previousSleepDisabled = false
        updated.lastHeartbeat = nil
        return updated
    }

    /// `true` when the helper must restore the setting because the app stopped
    /// sending heartbeats (crash, force-quit, lost connection).
    public static func shouldWatchdogRecover(
        state: SleepDisabledRuntimeState,
        now: Date,
        timeout: TimeInterval
    ) -> Bool {
        guard state.macPilotOwnedSleepDisable else { return false }
        guard let lastHeartbeat = state.lastHeartbeat else {
            // We own the setting but never saw a heartbeat: treat as stale.
            return true
        }
        return now.timeIntervalSince(lastHeartbeat) > timeout
    }

    /// Parses the `SleepDisabled` line out of `pmset -g` output.
    public static func parseSleepDisabled(fromPMSetOutput text: String) -> Bool? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let value = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  value == "SleepDisabled" else { continue }
            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let rawValue = tokens.last else { return nil }
            switch rawValue.lowercased() {
            case "1", "yes", "true":
                return true
            case "0", "no", "false":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
