#if DEBUG
import AppKit
import Darwin
import SwiftUI

/// Debug-only, real-AppKit acceptance run for the screenshot annotation flow.
///
/// Launch a debug `.app` bundle with `--acceptance-annotation` (and optionally
/// `--acceptance-output <dir>`). The mode skips `MacPilotAppServices`, so no
/// global shortcut, config file, screen capture or TCC prompt is touched. It
/// then opens the real full editor and the real inline action bar, drives them
/// with real NSEvent mouse/key events, and writes screenshots plus a report.
///
/// This is component-level real-machine acceptance: it does not capture the
/// screen, but every window, event, clipboard write and render is the shipping
/// code path used by the screenshot UI.
@MainActor
enum MacPilotAcceptanceRunner {
    static let isRequested = CommandLine.arguments.contains("--acceptance-annotation")

    private static var outputDirectory: URL = {
        if let index = CommandLine.arguments.firstIndex(of: "--acceptance-output"),
           CommandLine.arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MacPilotAcceptance", isDirectory: true)
    }()

    private static var pauseSeconds: Double {
        argumentDouble("--acceptance-pause")
    }

    private static var propertyPauseSeconds: Double {
        argumentDouble("--acceptance-property-pause")
    }

    private static func argumentDouble(_ name: String) -> Double {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1),
              let value = Double(CommandLine.arguments[index + 1]) else { return 0 }
        return value
    }

    private static var failures: [String] = []
    private static var checks: [(String, String, String)] = []
    private static var pasteboard = NSPasteboard(
        name: NSPasteboard.Name("MacPilot.Acceptance.\(UUID().uuidString)")
    )
    private static var editor: SmartAnnotationWindowController?
    private static var inlineWindow: NSWindow?
    private static var inlineBar: AreaSelectionActionBar?
    private static var inlineModel: SmartAnnotationModel?
    private static var screenWasLocked = false

    static func run() {
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        Task { @MainActor in
            await execute()
            finish()
        }
    }

    private static func execute() async {
        // Let SwiftUI finish its first layout and let `open` finish activation.
        try? await Task.sleep(for: .milliseconds(900))
        NSApp.activate(ignoringOtherApps: true)

        let source = makeImage(width: 900, height: 600)
        let controller = SmartAnnotationWindowController(
            image: source,
            language: .simplifiedChinese,
            onComplete: { _ in },
            onClose: {},
            onCopyAndClose: { image in
                SmartCaptureClipboard.copy(image: image, to: pasteboard)
            },
            onPin: { _ in },
            onDelete: {}
        )
        editor = controller
        controller.show()
        try? await Task.sleep(for: .milliseconds(700))
        controller.testWindow?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        if pauseSeconds > 0 {
            try? await Task.sleep(for: .seconds(pauseSeconds))
        }

        guard let window = controller.testWindow else {
            record("完整编辑器窗口", false, "窗口未创建")
            return
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let screenLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        screenWasLocked = screenLocked
        if window.isKeyWindow {
            record("完整编辑器窗口", true, "isKeyWindow=true")
        } else if screenLocked {
            recordBlocked("完整编辑器窗口激活", "当前 macOS 会话已锁屏，App 无法成为前台")
        } else {
            record("完整编辑器窗口", false, "isKeyWindow=false")
        }
        capture(window.contentView, name: "01-full-editor-bottom-bar.png")

        // Real mouse drags on the canvas: one rectangle, then a second one.
        drag(in: window, from: CGPoint(x: 0.30, y: 0.35), to: CGPoint(x: 0.52, y: 0.60))
        try? await Task.sleep(for: .milliseconds(300))
        if controller.testAnnotationCount == 1 {
            record("鼠标绘制第一个矩形", true, "annotations=1")
        } else if screenLocked {
            recordBlocked("鼠标绘制第一个矩形", "锁屏会话不接收前台鼠标事件（session locked）")
        } else {
            record("鼠标绘制第一个矩形", false, "annotations=\(controller.testAnnotationCount)")
        }
        drag(in: window, from: CGPoint(x: 0.58, y: 0.40), to: CGPoint(x: 0.76, y: 0.58))
        try? await Task.sleep(for: .milliseconds(300))
        if controller.testAnnotationCount == 2 {
            record("连续绘制第二个矩形", true, "annotations=2")
        } else if screenLocked {
            recordBlocked("连续绘制第二个矩形", "锁屏会话不接收前台鼠标事件（session locked）")
        } else {
            record("连续绘制第二个矩形", false, "annotations=\(controller.testAnnotationCount)")
        }
        capture(window.contentView, name: "02-two-rectangles.png")

        // Undo/redo exercise the real window key path. Seed the same two
        // annotations when the locked session cannot deliver mouse events, so
        // the history transaction itself is still verified end to end.
        if controller.testAnnotationCount == 0 {
            controller.testAppendRectangle(
                CGRect(x: 0.12, y: 0.18, width: 0.26, height: 0.30)
            )
            controller.testAppendRectangle(
                CGRect(x: 0.55, y: 0.48, width: 0.24, height: 0.24)
            )
        }
        try? await Task.sleep(for: .milliseconds(150))
        record(
            "历史栈初始状态",
            controller.testAnnotationCount == 2,
            "annotations=\(controller.testAnnotationCount)"
        )

        // Cmd+Z / Cmd+Shift+Z through the real window key equivalent path.
        sendKey(to: window, keyCode: 6, modifiers: .command, characters: "z")
        try? await Task.sleep(for: .milliseconds(250))
        record(
            "Cmd+Z 撤销",
            controller.testAnnotationCount == 1,
            "annotations=\(controller.testAnnotationCount)"
        )
        capture(window.contentView, name: "03-after-undo.png")

        sendKey(to: window, keyCode: 6, modifiers: [.command, .shift], characters: "z")
        try? await Task.sleep(for: .milliseconds(250))
        record(
            "Cmd+Shift+Z 重做",
            controller.testAnnotationCount == 2,
            "annotations=\(controller.testAnnotationCount)"
        )
        capture(window.contentView, name: "04-after-redo.png")

        // Real mouse resize: start at the second rectangle's dragged corner.
        // The corner is also the resize handle hit area.
        if controller.testAnnotationBounds.indices.contains(1) {
            let beforeResize = controller.testAnnotationBounds[1]
            drag(in: window, from: CGPoint(x: 0.76, y: 0.58), to: CGPoint(x: 0.84, y: 0.66))
            try? await Task.sleep(for: .milliseconds(250))
            let afterResize = controller.testAnnotationBounds.indices.contains(1)
                ? controller.testAnnotationBounds[1]
                : .zero
            record(
                "鼠标调整对象大小",
                afterResize.width > beforeResize.width + 0.01
                    && afterResize.height > beforeResize.height + 0.01,
                "before=\(beforeResize) after=\(afterResize)"
            )
        }

        // Real mouse move: drag from inside the second rectangle, away from
        // any handle, and verify the origin moved without changing the size.
        if controller.testAnnotationBounds.indices.contains(1) {
            let beforeMove = controller.testAnnotationBounds[1]
            drag(in: window, from: CGPoint(x: 0.68, y: 0.50), to: CGPoint(x: 0.60, y: 0.57))
            try? await Task.sleep(for: .milliseconds(250))
            let afterMove = controller.testAnnotationBounds.indices.contains(1)
                ? controller.testAnnotationBounds[1]
                : .zero
            let sizeUnchanged = abs(afterMove.width - beforeMove.width) < 0.02
                && abs(afterMove.height - beforeMove.height) < 0.02
            let originMoved = abs(afterMove.minX - beforeMove.minX) > 0.01
                || abs(afterMove.minY - beforeMove.minY) > 0.01
            record(
                "鼠标移动对象",
                sizeUnchanged && originMoved,
                "before=\(beforeMove) after=\(afterMove)"
            )
        }


        // Real mouse property edits. Prefer an external AX/mouse helper when
        // `--acceptance-property-pause` is set; otherwise use the stable
        // toolbar coordinates of the fixed 900×680 editor.
        if let content = window.contentView {
            let widthBefore = controller.testCurrentStyle.lineWidth
            let colorBefore = controller.testCurrentStyle.color

            if propertyPauseSeconds > 0 {
                let ready = outputDirectory.appendingPathComponent("property-ready")
                let done = outputDirectory.appendingPathComponent("property-done")
                try? FileManager.default.removeItem(at: done)
                try? Data().write(to: ready)
                let deadline = Date().addingTimeInterval(propertyPauseSeconds + 8)
                while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? FileManager.default.removeItem(at: ready)
                try? FileManager.default.removeItem(at: done)
            } else {
                let widthRow = accessibilityElement(
                    in: content,
                    identifier: "annotation-line-width-row"
                ).flatMap(accessibilityFrame(of:))
                let widthStart: CGPoint
                let widthEnd: CGPoint
                if let widthRow {
                    widthStart = CGPoint(x: widthRow.minX + 4, y: widthRow.midY)
                    widthEnd = CGPoint(x: widthRow.maxX - 8, y: widthRow.midY)
                } else {
                    // Fixed 900×680 editor: the slider sits at content
                    // x=534…600, y=650. Convert content points to screen.
                    widthStart = window.convertPoint(
                        toScreen: NSPoint(x: 240, y: 609)
                    )
                    widthEnd = window.convertPoint(
                        toScreen: NSPoint(x: 320, y: 609)
                    )
                }
                drag(window: window, fromScreen: widthStart, toScreen: widthEnd)

                let colorSwatch = accessibilityElement(
                    in: content,
                    identifier: "annotation-color-preset-3"
                ).flatMap(accessibilityFrame(of:))
                let colorPoint = colorSwatch.map {
                    CGPoint(x: $0.midX, y: $0.midY)
                } ?? window.convertPoint(toScreen: NSPoint(x: 73, y: 609))
                click(window: window, screenPoint: colorPoint)
            }

            record(
                "鼠标修改线宽",
                controller.testCurrentStyle.lineWidth != widthBefore,
                "before=\(widthBefore) after=\(controller.testCurrentStyle.lineWidth)"
            )
            record(
                "鼠标修改颜色",
                controller.testCurrentStyle.color != colorBefore,
                "before=\(colorBefore) after=\(controller.testCurrentStyle.color)"
            )
        }
        capture(window.contentView, name: "08-after-move-resize-color-width.png")

        // Inline HUD: every tool must be a direct visible button.
        let model = SmartAnnotationModel(initialTool: .rectangle)
        let bar = AreaSelectionActionBar { _ in }
        bar.bindAnnotationSession(.init(model: model) { _ in })
        let size = bar.intrinsicContentSize
        bar.frame = CGRect(origin: .zero, size: size)
        let barWindow = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        barWindow.isReleasedWhenClosed = false
        barWindow.contentView = bar
        barWindow.level = .floating
        barWindow.orderFrontRegardless()
        inlineWindow = barWindow
        inlineBar = bar
        inlineModel = model
        try? await Task.sleep(for: .milliseconds(300))
        let visibleTooltips = Set(bar.visibleToolButtons.compactMap(\.toolTip))
        let expectedToolKeys = [
            "scAnnotationRectangle", "scAnnotationFilledRectangle", "scAnnotationEllipse",
            "scAnnotationArrow", "scAnnotationLine", "scAnnotationPencil",
            "scAnnotationHighlighter", "scAnnotationText", "scAnnotationWatermark",
            "scAnnotationCounter", "scAnnotationBlur", "scAnnotationSpotlight",
            "scAnnotationEraser",
        ]
        let missing = expectedToolKeys.filter {
            !visibleTooltips.contains(AppText.value($0, language: .system))
        }
        record(
            "Inline 工具常驻数量",
            missing.isEmpty,
            "visible=\(visibleTooltips.count) missing=\(missing.joined(separator: ","))"
        )
        capture(bar, name: "05-inline-toolbar.png")

        // Layout reachability at common display sizes: the bar must stay fully
        // inside the screen even for a right/bottom edge selection.
        let barSize = bar.intrinsicContentSize
        for bounds in [CGSize(width: 1_024, height: 768), CGSize(width: 1_920, height: 1_080)] {
            let selection = CGRect(
                x: bounds.width - 90,
                y: 8,
                width: 80,
                height: 50
            )
            let frame = AreaSelectionBarLayout.resolve(
                selectionRect: selection,
                barSize: barSize,
                bounds: bounds
            )
            let inside = frame.minX >= AreaSelectionBarLayout.edgeMargin - 0.5
                && frame.minY >= AreaSelectionBarLayout.edgeMargin - 0.5
                && frame.maxX <= bounds.width - AreaSelectionBarLayout.edgeMargin + 0.5
                && frame.maxY <= bounds.height - AreaSelectionBarLayout.edgeMargin + 0.5
            record(
                "工具栏在 \(Int(bounds.width))×\(Int(bounds.height)) 内可达",
                inside,
                "frame=\(frame)"
            )
        }

        // Real per-display placement: one bar window on every connected
        // physical display, anchored near that display's bottom-right corner.
        let screens = NSScreen.screens
        record(
            "物理显示器数量",
            true,
            screens.enumerated().map { index, screen in
                "#\(index + 1) \(Int(screen.frame.width))×\(Int(screen.frame.height))@\(screen.backingScaleFactor)x"
            }.joined(separator: ", ")
        )
        for (index, screen) in screens.enumerated() {
            let displaySize = screen.frame.size
            let displayBar = AreaSelectionActionBar { _ in }
            let displayModel = SmartAnnotationModel(initialTool: .rectangle)
            displayBar.bindAnnotationSession(.init(model: displayModel) { _ in })
            let displayBarSize = displayBar.intrinsicContentSize
            let localFrame = AreaSelectionBarLayout.resolve(
                selectionRect: CGRect(
                    x: displaySize.width - 90,
                    y: 8,
                    width: 80,
                    height: 50
                ),
                barSize: displayBarSize,
                bounds: displaySize
            )
            let frame = CGRect(
                x: screen.frame.minX + localFrame.minX,
                y: screen.frame.minY + localFrame.minY,
                width: localFrame.width,
                height: localFrame.height
            )
            let displayWindow = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            displayWindow.isReleasedWhenClosed = false
            displayWindow.contentView = displayBar
            displayWindow.level = .floating
            displayWindow.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(200))
            record(
                "工具栏落在显示器 #\(index + 1)",
                displayWindow.frame.minX >= screen.visibleFrame.minX - 0.5
                    && displayWindow.frame.minY >= screen.visibleFrame.minY - 0.5
                    && displayWindow.frame.maxX <= screen.visibleFrame.maxX + 0.5
                    && displayWindow.frame.maxY <= screen.visibleFrame.maxY + 0.5,
                "frame=\(displayWindow.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)"
            )
            capture(displayBar, name: "09-toolbar-display-\(index + 1).png")
            displayWindow.close()
        }

        // Full editor window floor keeps the fixed controls reachable.
        let minSize = window.minSize
        record(
            "完整编辑器最小窗口",
            minSize.width >= 720 && minSize.height >= 420,
            "minSize=\(minSize)"
        )

        // Copy & Close must close only after the clipboard write succeeds.
        sendKey(to: window, keyCode: 8, modifiers: [.command, .shift], characters: "c")
        try? await Task.sleep(for: .milliseconds(500))
        record(
            "Copy & Close 关闭编辑器",
            controller.testWindow == nil,
            "window=\(controller.testWindow == nil ? "closed" : "open")"
        )
        let clipboardData = pasteboard.data(forType: .png)
        record("Copy & Close 写入剪贴板", clipboardData != nil, "pngBytes=\(clipboardData?.count ?? 0)")
        if let clipboardData {
            try? clipboardData.write(to: outputDirectory.appendingPathComponent("06-copy-and-close-clipboard.png"))
        }

        // Real area-selection result path with a synthetic frozen snapshot:
        // crop → delivery → clipboard success → dismiss. ScreenCaptureKit is
        // bypassed because this acceptance app never captures the screen.
        SnapzyAreaSelectionController.shared.testResetOutputStyle()
        let dismissalsBefore = SnapzyAreaSelectionController.shared.testDismissSelectionCount
        let areaController = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _, _, _ in },
            onCaptureReporting: { image, _, _, completion in
                completion(SmartCaptureClipboard.copy(image: image, to: pasteboard))
            },
            onError: { _ in },
            screenCaptureAccessProvider: { true }
        )
        areaController.testFinishAreaSelectionAction(
            image: makeImage(width: 200, height: 100),
            rect: CGRect(x: 20, y: 20, width: 80, height: 50),
            screenFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
            action: .copy
        )
        try? await Task.sleep(for: .milliseconds(800))
        let areaData = pasteboard.data(forType: .png)
        var areaSize: (Int, Int)?
        if let areaData,
           let source = CGImageSourceCreateWithData(areaData as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            areaSize = (image.width, image.height)
        }
        record(
            "区域选区 Copy 裁剪尺寸",
            areaSize?.0 == 80 && areaSize?.1 == 50,
            "size=\(String(describing: areaSize))"
        )
        record(
            "区域选区 Copy 成功后关闭",
            SnapzyAreaSelectionController.shared.testDismissSelectionCount > dismissalsBefore,
            "dismissals=\(SnapzyAreaSelectionController.shared.testDismissSelectionCount - dismissalsBefore)"
        )
        if let areaData {
            try? areaData.write(to: outputDirectory.appendingPathComponent("07-area-selection-copy.png"))
        }
        barWindow.close()
    }

    private static func accessibilityElement(
        in element: Any,
        identifier: String
    ) -> Any? {
        let object = element as AnyObject
        guard let accessible = object as? NSAccessibilityProtocol else { return nil }
        if accessible.accessibilityIdentifier() == identifier { return object }
        for child in accessible.accessibilityChildren() ?? [] {
            if let found = accessibilityElement(in: child, identifier: identifier) {
                return found
            }
        }
        return nil
    }

    private static func accessibilityFrame(of element: Any) -> CGRect? {
        (element as? NSAccessibilityProtocol)?.accessibilityFrame()
    }

    private static func click(window: NSWindow, screenPoint: CGPoint) {
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }
        window.sendEvent(event(.mouseMoved))
        window.sendEvent(event(.leftMouseDown))
        window.sendEvent(event(.leftMouseUp))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private static func drag(
        window: NSWindow,
        fromScreen start: CGPoint,
        toScreen end: CGPoint
    ) {
        let startPoint = window.convertPoint(fromScreen: start)
        let endPoint = window.convertPoint(fromScreen: end)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }
        window.sendEvent(event(.mouseMoved, startPoint))
        window.sendEvent(event(.leftMouseDown, startPoint))
        window.sendEvent(event(.leftMouseDragged, CGPoint(
            x: (startPoint.x + endPoint.x) / 2,
            y: (startPoint.y + endPoint.y) / 2
        )))
        window.sendEvent(event(.leftMouseDragged, endPoint))
        window.sendEvent(event(.leftMouseUp, endPoint))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.10, green: 0.16, blue: 0.28, alpha: 1),
                CGColor(red: 0.24, green: 0.40, blue: 0.64, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: width, y: height),
            options: []
        )
        return context.makeImage()!
    }

    /// Sends real AppKit mouse events to the key window. Coordinates are
    /// normalized inside the content view so the run is independent of the
    /// display size this Mac uses.
    private static func drag(in window: NSWindow, from: CGPoint, to: CGPoint) {
        guard let content = window.contentView else { return }
        let bounds = content.bounds
        let start = CGPoint(
            x: bounds.minX + bounds.width * from.x,
            y: bounds.minY + bounds.height * from.y
        )
        let end = CGPoint(
            x: bounds.minX + bounds.width * to.x,
            y: bounds.minY + bounds.height * to.y
        )
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }
        window.sendEvent(event(.leftMouseDown, start))
        window.sendEvent(event(.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)))
        window.sendEvent(event(.leftMouseDragged, end))
        window.sendEvent(event(.leftMouseUp, end))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private static func sendKey(
        to window: NSWindow,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        _ = window.performKeyEquivalent(with: event)
    }

    private static func capture(_ view: NSView?, name: String) {
        guard let view else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: outputDirectory.appendingPathComponent(name))
    }

    private static func record(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append((name, passed ? "通过" : "失败", detail))
        if !passed { failures.append("\(name): \(detail)") }
    }

    private static func recordBlocked(_ name: String, _ detail: String) {
        checks.append((name, "阻塞", detail))
    }

    private static func finish() {
        writeReport()
        let report = reportText()
        print(report)
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func reportText() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let commit: String = {
            if let index = CommandLine.arguments.firstIndex(of: "--acceptance-commit"),
               CommandLine.arguments.indices.contains(index + 1) {
                return CommandLine.arguments[index + 1]
            }
            return ProcessInfo.processInfo.environment["MACPILOT_ACCEPTANCE_COMMIT"] ?? "unknown"
        }()
        var lines: [String] = [
            "# 截图标注实机验收记录",
            "",
            "- 日期：\(ISO8601DateFormatter().string(from: Date()))",
            "- 系统：\(version)",
            "- 构建：\(commit)",
            "- 方式：debug `.app` 以 `--acceptance-annotation` 启动；真实 AppKit 窗口、真实 NSEvent 鼠标/键盘、真实 NSPasteboard；跳过 MacPilotAppServices，不触发全局快捷键、配置写入、屏幕采集或 TCC 授权",
            "- 会话状态：\(screenWasLocked ? "锁屏" : "已解锁")",
            "- 范围：全编辑器与 Inline 工具条的真实 UI 组件；区域截图裁剪本身由固定测试图像代替",
            "",
            "| 验收项 | 结果 | 证据 |",
            "|---|---|---|",
        ]
        for (name, status, detail) in checks {
            lines.append("| \(name) | \(status) | \(detail) |")
        }
        lines.append("")
        lines.append("## 截图")
        for name in [
            "01-full-editor-bottom-bar.png",
            "02-two-rectangles.png",
            "03-after-undo.png",
            "04-after-redo.png",
            "05-inline-toolbar.png",
            "06-copy-and-close-clipboard.png",
            "07-area-selection-copy.png",
            "08-after-move-resize-color-width.png",
            "09-toolbar-display-1.png",
            "09-toolbar-display-2.png",
        ] where FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent(name).path
        ) {
            lines.append("- \(name)")
        }
        lines.append("")
        let blockedCount = checks.filter { $0.1 == "阻塞" }.count
        if failures.isEmpty {
            lines.append(
                blockedCount == 0
                    ? "结果：全部通过。"
                    : "结果：可执行项全部通过；\(blockedCount) 项因锁屏会话无法执行（见上表“阻塞”行）。"
            )
        } else {
            lines.append("结果：失败 \(failures.count) 项。")
        }
        return lines.joined(separator: "\n")
    }

    private static func writeReport() {
        try? reportText().write(
            to: outputDirectory.appendingPathComponent("acceptance-record.md"),
            atomically: true,
            encoding: .utf8
        )
    }
}
#endif
