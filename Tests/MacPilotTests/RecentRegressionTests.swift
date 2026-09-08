import AppKit
import CoreGraphics
import Darwin
import SwiftUI
import Testing
@testable import MacPilot

struct RecentRegressionTests {
    @Test @MainActor func secondPencilStrokeDoesNotContainTheFirstStroke() throws {
        let model = SmartAnnotationModel(initialTool: .pencil)
        let window = try makeAnnotationWindow(model: model)
        defer { window.close() }

        drag(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 60), eventNumber: 1)
        drag(in: window, from: CGPoint(x: 120, y: 20), to: CGPoint(x: 160, y: 60), eventNumber: 4)

        #expect(model.annotations.count == 2)
        guard model.annotations.count == 2,
              case .pencil(let secondPoints) = model.annotations[1] else { return }
        #expect(secondPoints.allSatisfy { $0.x >= 0.5 })
    }

    @Test @MainActor func singleClickAnnotationCommitsBeforeTheGestureEnds() throws {
        let model = SmartAnnotationModel(initialTool: .counter)
        let window = try makeAnnotationWindow(model: model, onDoubleClickCanvas: {})
        defer { window.close() }

        drag(in: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), eventNumber: 10)

        #expect(model.annotations == [.counter(1, CGPoint(x: 0.5, y: 0.5))])
    }

    @Test @MainActor func textEntryUsesContentSizedFieldAtClickAnchor() throws {
        let model = SmartAnnotationModel(initialTool: .text)
        let window = try makeAnnotationWindow(model: model)
        defer { window.close() }

        let clickPoint = CGPoint(x: 74, y: 82)
        click(in: window, at: clickPoint, eventNumber: 30)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let field = try #require(textFields(in: window.contentView).first)
        let frame = field.convert(field.bounds, to: window.contentView)

        #expect(frame.width < 48)
        #expect(abs(frame.minX - clickPoint.x) <= 2.5)

        field.window?.makeFirstResponder(field)
        field.currentEditor()?.insertText("MacPilot")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let typedField = try #require(textFields(in: window.contentView).first)
        let typedFrame = typedField.convert(typedField.bounds, to: window.contentView)
        #expect(typedFrame.width > frame.width)
        #expect(abs(typedFrame.minX - frame.minX) <= 2.5)
        #expect(abs(typedFrame.maxY - frame.maxY) <= 2.5)
    }

    @Test @MainActor func editedLineWidthBecomesTheNextAnnotationDefault() {
        let model = SmartAnnotationModel(initialTool: .line)
        model.append(.line(CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.3)))
        model.setLineWidth(11)
        model.selectAnnotation(nil)
        model.append(.line(CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.8, y: 0.8)))

        #expect(model.style(at: 1).lineWidth == 11)
    }

    @Test @MainActor func processExecutablePathsPreserveSpaces() {
        let state = ProcessStateProvider.parseProcessList(
            "42 /Applications/Foo Bar.app/Contents/MacOS/Foo Bar\n"
        )

        #expect(state.runningExecutablePaths.contains(
            "/Applications/Foo Bar.app/Contents/MacOS/Foo Bar"
        ))
        #expect(state.runningNames.contains("foo bar"))
    }

    @Test @MainActor func processSnapshotCollectionDoesNotBlockTheMainActor() async {
        let provider = ProcessStateProvider(
            pollInterval: .seconds(60),
            snapshotReader: {
                usleep(150_000)
                return ProcessState(
                    runningNames: ["background-reader"],
                    runningExecutablePaths: ["/usr/bin/background-reader"]
                )
            }
        )
        defer { provider.stopMonitoring() }

        let startedAt = ContinuousClock.now
        provider.startMonitoring {}
        let elapsed = startedAt.duration(to: .now)

        #expect(elapsed < .milliseconds(50))
        for _ in 0..<40 where !provider.currentState.runningNames.contains("background-reader") {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(provider.currentState.runningNames.contains("background-reader"))
    }

    @Test @MainActor func doubleClickCounterRollsBackTheClickAndConfirms() throws {
        let model = SmartAnnotationModel(initialTool: .counter)
        var didConfirm = false
        let window = try makeAnnotationWindow(
            model: model,
            onDoubleClickCanvas: { didConfirm = true }
        )
        defer { window.close() }

        let point = CGPoint(x: 100, y: 100)
        drag(in: window, from: point, to: point, eventNumber: 20)
        drag(in: window, from: point, to: point, eventNumber: 23)

        #expect(didConfirm)
        #expect(model.annotations.isEmpty)
    }

    @Test func settingsSliderAdjustmentsStayInsideTheDeclaredRange() {
        #expect(SettingsSlider.normalizedValue(-1, in: 0...10, step: 1) == 0)
        #expect(SettingsSlider.normalizedValue(11, in: 0...10, step: 1) == 10)
        #expect(SettingsSlider.normalizedValue(-1, in: 0...10, step: nil) == 0)
        #expect(SettingsSlider.normalizedValue(11, in: 0...10, step: nil) == 10)
    }

    @Test func awakeEditorMapsEverySupportedConditionKind() {
        let conditions: [TriggerConditionConfiguration] = [
            .applicationRunning(bundleID: "com.example.app"),
            .applicationFrontmost(bundleID: "com.example.app"),
            .processRunning(name: "example"),
            .processExecutable(path: "/usr/bin/example"),
            .powerAdapter(connected: true),
            .charging(value: true),
            .batteryLevel(comparison: .greaterThanOrEqual, value: 50),
            .externalDisplay(minimumCount: 1),
            .displayMirroring(active: true),
        ]

        for condition in conditions {
            let kind = AwakeConditionKind(condition: condition)
            #expect(AwakeConditionKind(condition: kind.defaultCondition) == kind)
        }
    }

    @MainActor
    private func makeAnnotationWindow(
        model: SmartAnnotationModel,
        onDoubleClickCanvas: (() -> Void)? = nil
    ) throws -> NSWindow {
        _ = NSApplication.shared
        let image = try #require(makeImage(width: 200, height: 200))
        let editor = SmartAnnotationEditor(
            image: image,
            language: .english,
            model: model,
            embedded: true,
            showsToolbar: false,
            embeddedCanvasSize: CGSize(width: 200, height: 200),
            onCancel: {},
            onComplete: {},
            onDoubleClickCanvas: onDoubleClickCanvas
        )
        let host = NSHostingView(rootView: editor)
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return window
    }

    @MainActor
    private func drag(in window: NSWindow, from start: CGPoint, to end: CGPoint, eventNumber: Int) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let events: [(NSEvent.EventType, CGPoint, Int)] = [
            (.leftMouseDown, start, eventNumber),
            (.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), eventNumber + 1),
            (.leftMouseUp, end, eventNumber + 2),
        ]
        for (type, location, number) in events {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { continue }
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor
    private func click(in window: NSWindow, at location: CGPoint, eventNumber: Int) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        for (type, number) in [(NSEvent.EventType.leftMouseDown, eventNumber), (.leftMouseUp, eventNumber + 1)] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { continue }
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor
    private func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        return (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
