import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct UUSessionObservation: Sendable, Equatable {
    enum Status: String, Sendable { case disconnected, connected, unknown, ambiguous }
    enum Uncertainty: String, Sendable, CaseIterable {
        case accessibilityPermission, windowUnavailable, interfaceUnreadable
        case traversalLimit, readTimeout, controllerUnconfirmed
    }
    var status: Status
    var controllers: [String] = []
    var uncertainty: Uncertainty?

    var statusTextKey: String {
        if status == .unknown, let uncertainty { return "displayUUUnknown_" + uncertainty.rawValue }
        return "displayUUState_" + status.rawValue
    }
}

/// UU 4.42 exposes a whole controller row as one AX text value; older
/// versions expose the device, mode and duration in separate text elements.
enum UUControllerRowParser {
    static func announcedControllerCount(in texts: [String]) -> Int? {
        let summary = texts.joined(separator: " ")
        guard summary.contains("本机被控中"),
              let expression = try? NSRegularExpression(pattern: #"当前有\s*(\d+)\s*台设备正在控制此电脑"#) else { return nil }
        return expression.matches(in: summary, range: NSRange(summary.startIndex..., in: summary))
            .compactMap { match -> Int? in
                guard let range = Range(match.range(at: 1), in: summary) else { return nil }
                return Int(summary[range])
            }.max()
    }

    static func controller(in texts: [String]) -> String? {
        let values = texts.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        let markers: Set<String> = ["远程控制", "Remote control", "Remote Control"]
        if values.contains(where: markers.contains) {
            return values.first {
                !markers.contains($0) && !$0.hasPrefix("连接时长") && !$0.hasPrefix("Duration")
            }
        }
        // Require the mode AND a valid duration suffix, so a device name or
        // a generic "remote control" label cannot establish a live session.
        let row = values.joined(separator: " ")
        let pattern = #"^(.+?)\s+(?:远程控制|Remote [Cc]ontrol)\s+(?:连接时长|Duration)\s*[:：]?\s*(?:\d+:)?\d{1,2}:\d{2}$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)),
              let range = Range(match.range(at: 1), in: row) else { return nil }
        let name = String(row[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

enum UUSessionEvidence {
    static func observation(controllers: [String], announcedCount: Int = 0,
                            overlay: Bool = false, readFailed: Bool = false) -> UUSessionObservation {
        if controllers.count > 1 || announcedCount > 1 {
            return .init(status: .ambiguous, controllers: controllers.sorted())
        }
        if controllers.count == 1 { return .init(status: .connected, controllers: controllers) }
        if readFailed { return .init(status: .unknown, uncertainty: .interfaceUnreadable) }
        if overlay || announcedCount > 0 {
            return .init(status: .unknown, uncertainty: .controllerUnconfirmed)
        }
        return .init(status: .disconnected)
    }
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
                publish(.init(status: .unknown, uncertainty: .readTimeout))
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
                    ? value : UUSessionObservation(status: .unknown, uncertainty: .readTimeout)
                self.publish(current)
            }
        }
    }

    private func publish(_ value: UUSessionObservation) {
        let previous = gate.observation
        gate.update(value, now: Date())
        if previous.status != value.status || previous.uncertainty != value.uncertainty {
            DiagnosticLog.write("UUDetection", "status=\(value.status.rawValue) reason=\(value.uncertainty?.rawValue ?? "none")")
        }
        onChange?(gate.observation, gate.sessionID)
    }
}

/// Reads only UU's own process tree. No mouse, keyboard, window activation or
/// permission prompts; all AX work stays off the main actor and is bounded.
enum UUAccessibilityReader {
    static func read() -> UUSessionObservation {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.uuremote").first,
              let bundle = app.bundleURL else { return .init(status: .disconnected) }
        guard AXIsProcessTrusted() else { return .init(status: .unknown, uncertainty: .accessibilityPermission) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var readFailed = false
        guard let windows = attribute(root, kAXWindowsAttribute, failed: &readFailed) as? [AXUIElement], !windows.isEmpty else {
            return .init(status: .unknown, uncertainty: readFailed ? .interfaceUnreadable : .windowUnavailable)
        }
        let deadline = Date().addingTimeInterval(1.5)
        var nodes = 0
        var complete = true
        var timedOut = false
        var names: [String] = []
        var summaryTexts: [String] = []
        var visited: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int, rowTexts: inout [String]?) {
            // UU's accessibility graph can contain cycles. Visiting a cycle
            // again is harmless; hitting a genuine traversal limit is unknown.
            guard !visited.contains(where: { CFEqual($0, element) }) else { return }
            guard depth < 18, nodes < 500, Date() < deadline else {
                complete = false
                timedOut = timedOut || Date() >= deadline
                return
            }
            visited.append(element)
            nodes += 1
            let role = attribute(element, kAXRoleAttribute, failed: &readFailed) as? String
            if role == kAXRowRole {
                var texts: [String]? = []
                for child in (attribute(element, kAXChildrenAttribute, failed: &readFailed) as? [AXUIElement]) ?? [] {
                    walk(child, depth: depth + 1, rowTexts: &texts)
                }
                if let name = UUControllerRowParser.controller(in: texts ?? []) { names.append(name) }
                return
            }
            if role == kAXStaticTextRole, let text = attribute(element, kAXValueAttribute, failed: &readFailed) as? String {
                rowTexts?.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                summaryTexts.append(text)
            }
            for child in (attribute(element, kAXChildrenAttribute, failed: &readFailed) as? [AXUIElement]) ?? [] {
                walk(child, depth: depth + 1, rowTexts: &rowTexts)
            }
        }
        for window in windows {
            var texts: [String]?
            walk(window, depth: 0, rowTexts: &texts)
        }
        guard complete else { return .init(status: .unknown, uncertainty: timedOut ? .readTimeout : .traversalLimit) }
        let announcedCount = UUControllerRowParser.announcedControllerCount(in: summaryTexts) ?? 0
        if !names.isEmpty || announcedCount > 1 || readFailed {
            return UUSessionEvidence.observation(controllers: names, announcedCount: announcedCount,
                                                 readFailed: readFailed)
        }
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
        return UUSessionEvidence.observation(controllers: names, announcedCount: announcedCount, overlay: overlay)
    }

    private static func attribute(_ element: AXUIElement, _ key: String, failed: inout Bool) -> CFTypeRef? {
        // AX timeouts belong to each individual AXUIElement, not its process
        // or parent. A timeout on the application root leaves child reads at
        // the default timeout and can stall the entire serial reader.
        guard AXUIElementSetMessagingTimeout(element, 0.15) == .success else {
            failed = true
            return nil
        }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &result)
        guard error == .success else {
            if error != .attributeUnsupported && error != .noValue { failed = true }
            return nil
        }
        return result
    }
}
