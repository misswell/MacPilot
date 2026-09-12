import Foundation

/// Unified log prefix for the iPhone remote control. Secrets (passwords, pairing
/// keys, session keys and sealed payloads) must never reach the log.
func remoteControlLog(_ message: String) {
    DiagnosticLog.write("RemoteControl", "MacPilot Remote: \(message)")
}
