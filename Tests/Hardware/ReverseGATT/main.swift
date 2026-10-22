import AppKit
import Foundation

// This executable is assembled with an exact copy of the production Peripheral
// by prepare-host.sh. No MacPilot model or screen-control code is linked here.
@main
struct ReverseGATTHardwareHost {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            await run()
            app.terminate(nil)
        }
        // CoreBluetooth/TCC needs a normal AppKit run loop, including launch
        // events, even though this isolated accessory has no visible window.
        app.run()
    }

    @MainActor
    private static func run() async {
        guard ProcessInfo.processInfo.environment["MACPILOT_GATT_HARDWARE"] == "1",
              CommandLine.arguments.count == 2 else { return }
        let commandFile = CommandLine.arguments[1]
        let peripheral = ProximityBLEPeripheral()
        let deviceID = UUID(uuidString: "AF07681C-5639-4776-875A-6FB41EA01922")!
        let cycleSeconds = Double(ProcessInfo.processInfo.environment["MACPILOT_GATT_HARDWARE_CYCLE_SECONDS"] ?? "0") ?? 0
        let startedAt = Date.now
        var cyclingStopped = false
        var previousCommand = ""
        var previousSnapshot = Data()
        peripheral.start(macDeviceID: deviceID)
        defer { peripheral.stop() }
        while !Task.isCancelled {
            let command = (try? String(contentsOfFile: commandFile, encoding: .utf8)) ?? ""
            if command != previousCommand {
                previousCommand = command
                switch command.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last {
                case "stop": peripheral.stop()
                case "start": peripheral.start(macDeviceID: deviceID)
                case "quit": return
                default: break
                }
            }
            if cycleSeconds >= 10 {
                let phase = Date.now.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: cycleSeconds)
                let shouldStop = phase >= cycleSeconds - 4
                if shouldStop != cyclingStopped {
                    cyclingStopped = shouldStop
                    if shouldStop { peripheral.stop() }
                    else { peripheral.start(macDeviceID: deviceID) }
                }
            }
            let fields: [String: Any] = [
                "status": String(describing: peripheral.status),
                "advertising": peripheral.isAdvertising,
                "subscribers": peripheral.subscriberCount,
                "receivedBytes": peripheral.receivedBytes,
                "sentBytes": peripheral.sentBytes,
                "events": peripheral.logLines
            ]
            if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
               data != previousSnapshot {
                previousSnapshot = data
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
