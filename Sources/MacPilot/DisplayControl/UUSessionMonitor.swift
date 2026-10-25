import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct UUSessionObservation: Sendable, Equatable {
    enum Status: String, Sendable { case disconnected, connected, unknown, ambiguous }
    var status: Status
    var controllers: [String] = []
}

/// Pure gate. A missing AX tree is not evidence of disconnection. Unknown
/// evidence stops renewing the helper's remote lease, without inventing a new session.
struct UUSessionGate {
    private(set) var sessionID: String?
    private(set) var observation = UUSessionObservation(status: .disconnected)
    private var absentSince: Date?
    private var lastConnectedControllers: [String] = []

    mutating func update(_ incoming: UUSessionObservation, now: Date) {
        if incoming.status == .connected {
            if sessionID == nil || lastConnectedControllers != incoming.controllers {
                sessionID = UUID().uuidString
            }
            lastConnectedControllers = incoming.controllers
            absentSince = nil
            observation = incoming
        } else {
            absentSince = incoming.status == .disconnected ? (absentSince ?? now) : nil
            observation = incoming
            if let absentSince, incoming.status == .disconnected, now.timeIntervalSince(absentSince) >= 1.5 {
                sessionID = nil
            }
        }
    }
}

@MainActor
final class UUSessionMonitor {
    private let queue = DispatchQueue(label: "com.misswell.macpilot.uu-observation", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var generation = UUID()
    private var readStartedAt = Date.distantPast
    private var gate = UUSessionGate()
    var onChange: ((UUSessionObservation, String?) -> Void)?
    private let read: @Sendable () -> UUSessionObservation

    init(read: @escaping @Sendable () -> UUSessionObservation = { UUAccessibilityReader.read() }) {
        self.read = read
    }

    func start() {
        guard timer == nil else { return }
        generation = UUID()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        gate = UUSessionGate()
    }

    private func tick() {
        guard !inFlight else {
            if Date().timeIntervalSince(readStartedAt) > 2 {
                gate.update(.init(status: .unknown), now: Date())
                onChange?(gate.observation, gate.sessionID)
            }
            return
        }
        inFlight = true
        let token = generation
        let started = Date()
        readStartedAt = started
        let read = read
        queue.async { [weak self] in
            let value = read()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard self.timer != nil, token == self.generation else { return }
                let current = Date().timeIntervalSince(started) <= 2
                    ? value : UUSessionObservation(status: .unknown)
                self.gate.update(current, now: Date())
                self.onChange?(self.gate.observation, self.gate.sessionID)
            }
        }
    }
}

/// Reads only UU's own process tree. No mouse, keyboard, window activation or
/// permission prompts; all AX work stays off the main actor and is bounded.
enum UUAccessibilityReader {
    static func read() -> UUSessionObservation {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.uuremote").first,
              let bundle = app.bundleURL else { return .init(status: .disconnected) }
        guard AXIsProcessTrusted() else { return .init(status: .unknown) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            return .init(status: .unknown)
        }
        let deadline = Date().addingTimeInterval(1.5)
        var nodes = 0
        var complete = true
        var names: [String] = []
        var visited: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int, rowTexts: inout [String]?) {
            // UU's accessibility graph can contain cycles. Visiting a cycle
            // again is harmless; hitting a genuine traversal limit is unknown.
            guard !visited.contains(where: { CFEqual($0, element) }) else { return }
            guard depth < 18, nodes < 500, Date() < deadline else { complete = false; return }
            visited.append(element)
            nodes += 1
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == kAXRowRole {
                var texts: [String]? = []
                for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    walk(child, depth: depth + 1, rowTexts: &texts)
                }
                let values = texts ?? []
                let markers: Set<String> = ["远程控制", "Remote control", "Remote Control"]
                if values.contains(where: markers.contains), let name = values.first(where: {
                    !markers.contains($0) && !$0.hasPrefix("连接时长") && !$0.hasPrefix("Duration") && !$0.isEmpty
                }) { names.append(name) }
                return
            }
            if role == kAXStaticTextRole, let text = attribute(element, kAXValueAttribute) as? String {
                rowTexts?.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                walk(child, depth: depth + 1, rowTexts: &rowTexts)
            }
        }
        for window in windows {
            var texts: [String]?
            walk(window, depth: 0, rowTexts: &texts)
        }
        guard complete else { return .init(status: .unknown) }
        if names.count > 1 { return .init(status: .ambiguous, controllers: names.sorted()) }
        if names.count == 1 { return .init(status: .connected, controllers: names.sorted()) }
        // The owner name alone is insufficient: another process could use it.
        // An overlay with no readable controller must not enable destructive policy.
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let overlay = list.contains { entry in
            guard entry[kCGWindowOwnerName as String] as? String == "UURemoteServer",
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let process = NSRunningApplication(processIdentifier: pid),
                  let executable = process.executableURL else { return false }
            return executable.resolvingSymlinksInPath().path.hasPrefix(bundle.resolvingSymlinksInPath().path + "/")
        }
        return .init(status: overlay ? .unknown : .disconnected)
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
}
