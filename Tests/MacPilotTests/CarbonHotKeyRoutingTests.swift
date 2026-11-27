import Carbon.HIToolbox
import Testing
@testable import MacPilot

@Suite(.serialized)
struct CarbonHotKeyRoutingTests {
    @Test @MainActor
    func windowSwitcherRoutesOwnDirectionsAndPassesForeignEvents() throws {
        var received: [WindowSwitcherShortcutDirection] = []
        let context = WindowSwitcherHotKeyContext { received.append($0) }
        context.activeDirections = Set(WindowSwitcherShortcutDirection.allCases)
        let pointer = Unmanaged.passUnretained(context).toOpaque()

        let downstream = DownstreamHotKeyProbe()
        var downstreamHandler: EventHandlerRef?
        var eventType = hotKeyEventType
        try #require(InstallEventHandler(GetApplicationEventTarget(), downstreamScreenshotHotKeyHandler, 1, &eventType, Unmanaged.passUnretained(downstream).toOpaque(), &downstreamHandler) == noErr)
        let installedDownstream = try #require(downstreamHandler)
        defer { RemoveEventHandler(installedDownstream) }

        var handler: EventHandlerRef?
        try #require(InstallEventHandler(GetApplicationEventTarget(), windowSwitcherHotKeyEventHandler, 1, &eventType, pointer, &handler) == noErr)
        let installed = try #require(handler)
        defer { RemoveEventHandler(installed) }

        for direction in WindowSwitcherShortcutDirection.allCases {
            let event = try makeHotKeyEvent(signature: WindowSwitcherHotKeys.signature, identifier: direction.rawValue)
            defer { ReleaseEvent(event) }
            #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        }
        #expect(received == [.forward, .reverse])
        #expect(!downstream.didReceiveEvent)

        for (signature, id) in [(OSType(0x4D504341), UInt32(1)), (WindowSwitcherHotKeys.signature, UInt32(99))] {
            let event = try makeHotKeyEvent(signature: signature, identifier: id)
            defer { ReleaseEvent(event) }
            downstream.didReceiveEvent = false
            #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
            #expect(downstream.didReceiveEvent)
        }
        #expect(received == [.forward, .reverse])

        var otherKind: EventRef?
        try #require(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyReleased), 0, 0, &otherKind) == noErr)
        let released = try #require(otherKind)
        defer { ReleaseEvent(released) }
        #expect(windowSwitcherHotKeyEventHandler(nil, released, pointer) == OSStatus(eventNotHandledErr))
        var otherClass: EventRef?
        try #require(CreateEvent(nil, OSType(kEventClassMouse), UInt32(kEventHotKeyPressed), 0, 0, &otherClass) == noErr)
        let mouse = try #require(otherClass)
        defer { ReleaseEvent(mouse) }
        #expect(windowSwitcherHotKeyEventHandler(nil, mouse, pointer) == OSStatus(eventNotHandledErr))

        context.onPress = nil
        let stopped = try makeHotKeyEvent(signature: WindowSwitcherHotKeys.signature, identifier: 1)
        defer { ReleaseEvent(stopped) }
        #expect(windowSwitcherHotKeyEventHandler(nil, stopped, pointer) == OSStatus(eventNotHandledErr))
        #expect(received == [.forward, .reverse])
    }

    @Test @MainActor
    func screenshotHotKeyPassesThroughClipboardHandler() throws {
        let event = try makeHotKeyEvent(
            signature: OSType(0x4D504341), // "MPCA"
            identifier: 1
        )
        defer { ReleaseEvent(event) }

        // Carbon calls the most recently installed handler first, so install
        // the fake screenshot receiver first and the real clipboard handler
        // last to put it at the head of the dispatch chain.
        let screenshotContext = DownstreamHotKeyProbe()
        var screenshotHandler: EventHandlerRef?
        var eventType = hotKeyEventType
        try #require(InstallEventHandler(
            GetApplicationEventTarget(),
            downstreamScreenshotHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(screenshotContext).toOpaque(),
            &screenshotHandler
        ) == noErr)
        let installedScreenshotHandler = try #require(screenshotHandler)
        defer { RemoveEventHandler(installedScreenshotHandler) }

        let clipboardContext = ClipboardHotKeyContext(onToggle: {})
        var clipboardHandler: EventHandlerRef?
        eventType = hotKeyEventType
        try #require(InstallEventHandler(
            GetApplicationEventTarget(),
            clipboardHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(clipboardContext).toOpaque(),
            &clipboardHandler
        ) == noErr)
        let installedClipboardHandler = try #require(clipboardHandler)
        defer { RemoveEventHandler(installedClipboardHandler) }

        #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        #expect(screenshotContext.didReceiveEvent)
    }

    @Test
    func screenRecordingHandlerPassesThroughForeignHotKeyWithoutContext() throws {
        let event = try makeHotKeyEvent(signature: OSType(0x4D504341), identifier: 1)
        defer { ReleaseEvent(event) }

        #expect(screenRecordingCarbonEventHandler(nil, event, nil) == OSStatus(eventNotHandledErr))
    }

    @Test @MainActor
    func clipboardHotKeyStillInvokesItsOwnHandler() async throws {
        let event = try makeHotKeyEvent(
            signature: ClipboardHotKeyCenter.hotKeySignature,
            identifier: ClipboardHotKeyCenter.hotKeyIdentifier
        )
        defer { ReleaseEvent(event) }

        let toggleProbe = ClipboardToggleProbe()
        let clipboardContext = ClipboardHotKeyContext {
            toggleProbe.invocationCount += 1
        }
        var eventType = hotKeyEventType
        var handler: EventHandlerRef?
        try #require(InstallEventHandler(
            GetApplicationEventTarget(),
            clipboardHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(clipboardContext).toOpaque(),
            &handler
        ) == noErr)
        let installedHandler = try #require(handler)
        defer { RemoveEventHandler(installedHandler) }

        #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        for _ in 0..<10 where toggleProbe.invocationCount == 0 {
            await Task.yield()
        }
        #expect(toggleProbe.invocationCount == 1)
    }
}

private let hotKeyEventType = EventTypeSpec(
    eventClass: OSType(kEventClassKeyboard),
    eventKind: UInt32(kEventHotKeyPressed)
)

private final class DownstreamHotKeyProbe: @unchecked Sendable {
    var didReceiveEvent = false
}

@MainActor
private final class ClipboardToggleProbe {
    var invocationCount = 0
}

private func makeHotKeyEvent(signature: OSType, identifier: UInt32) throws -> EventRef {
    var event: EventRef?
    try #require(CreateEvent(
        nil,
        OSType(kEventClassKeyboard),
        UInt32(kEventHotKeyPressed),
        0,
        EventAttributes(kEventAttributeUserEvent),
        &event
    ) == noErr)
    let createdEvent = try #require(event)

    var hotKeyID = EventHotKeyID(signature: signature, id: identifier)
    let setParameterStatus = withUnsafePointer(to: &hotKeyID) { pointer in
        SetEventParameter(
            createdEvent,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            UnsafeRawPointer(pointer)
        )
    }
    guard setParameterStatus == noErr else {
        ReleaseEvent(createdEvent)
        throw CarbonHotKeyRoutingError.eventParameterSetupFailed(setParameterStatus)
    }
    return createdEvent
}

private func downstreamScreenshotHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let probe = Unmanaged<DownstreamHotKeyProbe>
        .fromOpaque(userData)
        .takeUnretainedValue()
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    probe.didReceiveEvent = true
    return noErr
}

private enum CarbonHotKeyRoutingError: Error {
    case eventParameterSetupFailed(OSStatus)
}
