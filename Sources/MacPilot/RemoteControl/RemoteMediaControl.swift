import AppKit
import ApplicationServices
import IOKit.hidsystem
import MacPilotRemoteProtocol

/// Posts the same system media-key pair as a keyboard. The active media app
/// owns playback state; the reply acknowledges dispatch, not playback itself.
@MainActor
enum RemoteMediaControl {
    static func events(for command: RemoteCommand) -> [NSEvent] {
        let key: Int
        switch command {
        case .mediaPrevious: key = Int(NX_KEYTYPE_PREVIOUS)
        case .mediaPlayPause: key = Int(NX_KEYTYPE_PLAY)
        case .mediaNext: key = Int(NX_KEYTYPE_NEXT)
        default: return []
        }
        return [true, false].compactMap { down in
            let state = down ? 0xA : 0xB
            return NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key << 16) | (state << 8),
                data2: -1
            )
        }
    }

    static func send(_ command: RemoteCommand) -> RemoteErrorCode? {
        guard AXIsProcessTrusted() else { return .accessibilityPermissionRequired }
        let events = events(for: command).compactMap(\.cgEvent)
        guard events.count == 2 else { return .internalError }
        for event in events { event.post(tap: .cghidEventTap) }
        return nil
    }
}
