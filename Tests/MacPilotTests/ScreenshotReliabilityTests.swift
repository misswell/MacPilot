import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MacPilot

private func makeTestImage(width: Int = 12, height: Int = 8) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScreenshotReliabilityTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writer that records bytes without touching ImageIO.
private func byteWriter(format: ScreenCaptureImageFormat) -> CaptureArtifactStore.Encoder {
    { _, url, _, _ in
        (try? Data("image".utf8).write(to: url)) != nil
    }
}

private let acceptsAnySize: CaptureArtifactStore.Validator = { url, _, _ in
    FileManager.default.fileExists(atPath: url.path)
}

struct PostCaptureRoutingTests {
    private let legacy = PostCaptureActionSet(
        saveToDisk: true,
        copyToClipboard: true,
        showQuickAccess: true,
        pinToScreen: false
    )

    @Test func automaticCaptureFallsBackToTheLegacyGlobalSwitches() {
        let actions = PostCaptureActionSet.actions(
            intent: .automatic,
            mode: .area,
            global: legacy,
            perMode: [:]
        )
        #expect(actions == legacy)
    }

    @Test func automaticCaptureUsesTheConfiguredModeOverride() {
        let override = PostCaptureActionSet(
            saveToDisk: false,
            copyToClipboard: true,
            showQuickAccess: false,
            pinToScreen: true
        )
        let actions = PostCaptureActionSet.actions(
            intent: .automatic,
            mode: .applicationWindow,
            global: legacy,
            perMode: [CaptureMode.applicationWindow.rawValue: override]
        )
        #expect(actions == override)
    }

    @Test func explicitSaveAlwaysProducesAPermanentFile() {
        let actions = PostCaptureActionSet.actions(
            intent: .explicitSave,
            mode: .area,
            global: PostCaptureActionSet(
                saveToDisk: false,
                copyToClipboard: false,
                showQuickAccess: false,
                pinToScreen: false
            ),
            perMode: [:]
        )
        #expect(actions.saveToDisk)
        #expect(!actions.copyToClipboard)
        let plan = PostCaptureRouter.plan(
            request: CaptureRequest(mode: .area, trigger: .shortcut, intent: .explicitSave),
            global: legacy,
            perMode: [:]
        )
        #expect(plan.artifactIsPermanent)
        #expect(plan.needsArtifact)
    }

    @Test func explicitCopyOnlyNeedsABackingArtifact() {
        let plan = PostCaptureRouter.plan(
            request: CaptureRequest(mode: .area, trigger: .menu, intent: .explicitCopy),
            global: legacy,
            perMode: [:]
        )
        #expect(plan.actions.copyToClipboard)
        #expect(!plan.actions.saveToDisk)
        #expect(plan.needsArtifact)
        #expect(!plan.artifactIsPermanent)
    }

    @Test func explicitPinNeverWritesAPermanentFile() {
        let actions = PostCaptureActionSet.actions(
            intent: .explicitPin,
            mode: .area,
            global: legacy,
            perMode: [:]
        )
        #expect(actions.pinToScreen)
        #expect(!actions.saveToDisk)
    }

    @Test func missingPerModeConfigurationDecodesToLegacyBehaviour() throws {
        let configuration = try JSONDecoder().decode(
            PostCaptureConfiguration.self,
            from: Data("{}".utf8)
        )
        #expect(configuration.perModeActions.isEmpty)
        #expect(PostCaptureConfiguration().perModeActions.isEmpty)
    }

    @Test func unknownModeKeysAreSanitizedInsteadOfWipingTheSection() {
        let known = PostCaptureActionSet(
            saveToDisk: true,
            copyToClipboard: false,
            showQuickAccess: false,
            pinToScreen: false
        )
        let configuration = PostCaptureConfiguration(
            perModeActions: [
                CaptureMode.area.rawValue: known,
                "removedMode": known,
            ]
        )
        let sanitized = configuration.sanitized()
        #expect(sanitized.perModeActions.keys.sorted() == [CaptureMode.area.rawValue])
    }

    @Test func legacySettingsMapOntoTheGlobalActionSetUnchanged() {
        var settings = ScreenCaptureSettings()
        settings.saveAfterCapture = true
        settings.copyAfterCapture = false
        settings.showQuickAccess = true
        settings.pinAfterCapture = true
        let set = PostCaptureActionSet(legacy: settings)
        #expect(set.saveToDisk)
        #expect(!set.copyToClipboard)
        #expect(set.showQuickAccess)
        #expect(set.pinToScreen)
    }

    @Test func perModeOverrideForOneModeLeavesTheOthersOnGlobal() {
        let override = PostCaptureActionSet(
            saveToDisk: false,
            copyToClipboard: false,
            showQuickAccess: false,
            pinToScreen: true
        )
        let perMode = [CaptureMode.area.rawValue: override]
        let area = PostCaptureActionSet.actions(
            intent: .automatic, mode: .area, global: legacy, perMode: perMode
        )
        let fullscreen = PostCaptureActionSet.actions(
            intent: .automatic, mode: .fullscreen, global: legacy, perMode: perMode
        )
        #expect(area == override)
        #expect(fullscreen == legacy)
    }

    @Test func removingAModeOverrideRestoresTheGlobalSwitches() {
        let override = PostCaptureActionSet(
            saveToDisk: true,
            copyToClipboard: false,
            showQuickAccess: false,
            pinToScreen: false
        )
        var perMode = [CaptureMode.area.rawValue: override]
        perMode.removeValue(forKey: CaptureMode.area.rawValue)
        let actions = PostCaptureActionSet.actions(
            intent: .automatic, mode: .area, global: legacy, perMode: perMode
        )
        #expect(actions == legacy)
    }

    @Test func screenCaptureSettingsRoundTripKeepsPerModeOverrides() throws {
        var settings = ScreenCaptureSettings()
        let custom = PostCaptureActionSet(
            saveToDisk: false,
            copyToClipboard: true,
            showQuickAccess: false,
            pinToScreen: false,
            openAnnotation: true
        )
        settings.postCaptureConfiguration.perModeActions[CaptureMode.scrolling.rawValue] = custom

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: data)
        #expect(decoded.postCaptureConfiguration == settings.postCaptureConfiguration)
        #expect(decoded.saveAfterCapture == settings.saveAfterCapture)
        #expect(decoded.copyAfterCapture == settings.copyAfterCapture)
    }

    @Test func legacySettingsWithoutThePerModeKeyKeepTheirGlobalSwitches() throws {
        let json = Data(#"{"saveAfterCapture": false, "copyAfterCapture": true, "showQuickAccess": false, "pinAfterCapture": true}"#.utf8)
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: json)
        #expect(decoded.postCaptureConfiguration.perModeActions.isEmpty)
        #expect(!PostCaptureActionSet(legacy: decoded).saveToDisk)
        #expect(PostCaptureActionSet(legacy: decoded).copyToClipboard)
        #expect(PostCaptureActionSet(legacy: decoded).pinToScreen)
        #expect(!PostCaptureActionSet(legacy: decoded).showQuickAccess)
    }

    @Test @MainActor func customizingOneModeNeverTouchesTheOtherModes() {
        let model = ScreenCaptureModel()
        var persisted = false
        model.persist = { persisted = true }
        let custom = PostCaptureActionSet(
            saveToDisk: false,
            copyToClipboard: false,
            showQuickAccess: false,
            pinToScreen: true
        )

        model.setPerModePostCaptureActions(custom, for: .area)
        #expect(model.settings.postCaptureConfiguration.perModeActions[CaptureMode.area.rawValue] == custom)
        #expect(model.settings.postCaptureConfiguration.perModeActions[CaptureMode.fullscreen.rawValue] == nil)
        #expect(persisted)

        model.setPerModePostCaptureActions(nil, for: .area)
        #expect(model.settings.postCaptureConfiguration.perModeActions.isEmpty)
    }
}

struct CaptureArtifactStoreTests {
    @Test func writeCommitsAReadyArtifact() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureArtifactStore(encoder: byteWriter(format: .png), validator: acceptsAnySize)
        let artifact = try store.write(.init(
            captureID: UUID(),
            image: SendableScreenCaptureImage(value: makeTestImage()),
            directory: directory,
            baseName: "capture",
            format: .png,
            quality: 1,
            isTemporary: true
        ))
        #expect(artifact.state == .ready)
        #expect(artifact.isTemporary)
        #expect(store.fileExists(at: artifact.url))
        #expect(artifact.pixelWidth == 12)
        #expect(artifact.byteCount > 0)
    }

    @Test func aFailedEncodeLeavesNoFileBehind() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureArtifactStore(encoder: { _, _, _, _ in false })
        #expect(throws: CaptureArtifactError.encodeFailed) {
            _ = try store.write(.init(
                captureID: UUID(),
                image: SendableScreenCaptureImage(value: makeTestImage()),
                directory: directory,
                baseName: "capture",
                format: .png,
                quality: 1,
                isTemporary: true
            ))
        }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(remaining.isEmpty)
    }

    @Test func aFailedValidationNeverCommitsTheStagingFile() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureArtifactStore(
            encoder: byteWriter(format: .png),
            validator: { _, _, _ in false }
        )
        #expect(throws: CaptureArtifactError.validationFailed) {
            _ = try store.write(.init(
                captureID: UUID(),
                image: SendableScreenCaptureImage(value: makeTestImage()),
                directory: directory,
                baseName: "capture",
                format: .png,
                quality: 1,
                isTemporary: true
            ))
        }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(remaining.isEmpty)
    }

    @Test func repeatedWritesNeverOverwriteAnExistingCapture() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureArtifactStore(encoder: byteWriter(format: .png), validator: acceptsAnySize)
        let first = try store.write(.init(
            captureID: UUID(),
            image: SendableScreenCaptureImage(value: makeTestImage()),
            directory: directory,
            baseName: "capture",
            format: .png,
            quality: 1,
            isTemporary: true
        ))
        let second = try store.write(.init(
            captureID: UUID(),
            image: SendableScreenCaptureImage(value: makeTestImage()),
            directory: directory,
            baseName: "capture",
            format: .png,
            quality: 1,
            isTemporary: true
        ))
        #expect(first.url != second.url)
        #expect(store.fileExists(at: first.url))
        #expect(store.fileExists(at: second.url))
    }

    @Test func promoteMovesTheTemporaryFileAndRemovesItsSource() throws {
        let temp = makeTemporaryDirectory()
        let export = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: export)
        }
        let store = CaptureArtifactStore(encoder: byteWriter(format: .png), validator: acceptsAnySize)
        let artifact = try store.write(.init(
            captureID: UUID(),
            image: SendableScreenCaptureImage(value: makeTestImage()),
            directory: temp,
            baseName: "capture",
            format: .png,
            quality: 1,
            isTemporary: true
        ))
        let promoted = try store.promote(artifact, to: export, baseName: "saved")
        #expect(!promoted.isTemporary)
        #expect(promoted.id == artifact.id)
        #expect(store.fileExists(at: promoted.url))
        #expect(!store.fileExists(at: artifact.url))
        #expect(promoted.url.deletingLastPathComponent().standardizedFileURL
            == export.standardizedFileURL)
    }

    @Test func promotingAPermanentArtifactIsANoOp() throws {
        let export = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: export) }
        let store = CaptureArtifactStore(encoder: byteWriter(format: .png), validator: acceptsAnySize)
        let permanent = try store.write(.init(
            captureID: UUID(),
            image: SendableScreenCaptureImage(value: makeTestImage()),
            directory: export,
            baseName: "capture",
            format: .png,
            quality: 1,
            isTemporary: false
        ))
        let promoted = try store.promote(permanent, to: export, baseName: "saved")
        #expect(promoted.url == permanent.url)
        #expect(!promoted.isTemporary)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: export.path)) ?? []
        #expect(files.count == 1)
    }

    @Test func anUnavailableDestinationIsReportedNotIgnored() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("not-a-directory")
        try? Data("x".utf8).write(to: blocker)
        let store = CaptureArtifactStore(encoder: byteWriter(format: .png), validator: acceptsAnySize)
        #expect(throws: CaptureArtifactError.destinationUnavailable) {
            _ = try store.write(.init(
                captureID: UUID(),
                image: SendableScreenCaptureImage(value: makeTestImage()),
                directory: blocker,
                baseName: "capture",
                format: .png,
                quality: 1,
                isTemporary: true
            ))
        }
    }
}

@MainActor
struct ClipboardArtifactLeaseTests {
    @Test func aNewPasteboardGenerationReleasesTheOldLease() {
        let manager = ClipboardArtifactLeaseManager.shared
        manager.resetForTesting()
        defer { manager.resetForTesting() }
        let artifact = CaptureArtifact(
            captureID: UUID(),
            url: URL(fileURLWithPath: "/tmp/lease-test.png"),
            isTemporary: true,
            format: .png,
            pixelWidth: 10,
            pixelHeight: 10,
            byteCount: 10
        )
        manager.recordCopy(
            artifact: artifact,
            changeCount: 1,
            providedTypes: [.png]
        )
        #expect(manager.isReferencedByPasteboard(artifactID: artifact.id))
        #expect(!manager.canReclaim(artifactID: artifact.id))
        let released = manager.synchronize(changeCount: 2)
        #expect(released.count == 1)
        #expect(manager.canReclaim(artifactID: artifact.id))
    }

    @Test func aNamedConsumerKeepsTheFileAliveEvenAfterThePasteboardMovedOn() {
        let manager = ClipboardArtifactLeaseManager.shared
        manager.resetForTesting()
        defer { manager.resetForTesting() }
        let url = URL(fileURLWithPath: "/tmp/consumer-test.png")
        manager.retain(url: url, consumer: "annotation-editor")
        #expect(!manager.canReclaim(url: url))
        manager.release(url: url, consumer: "annotation-editor")
        #expect(manager.canReclaim(url: url))
    }

    @Test func copyingASecondCaptureDoesNotReleaseTheFirst() {
        let manager = ClipboardArtifactLeaseManager.shared
        manager.resetForTesting()
        defer { manager.resetForTesting() }
        let first = CaptureArtifact(
            captureID: UUID(),
            url: URL(fileURLWithPath: "/tmp/lease-first.png"),
            isTemporary: true,
            format: .png,
            pixelWidth: 10,
            pixelHeight: 10,
            byteCount: 10
        )
        let second = CaptureArtifact(
            captureID: UUID(),
            url: URL(fileURLWithPath: "/tmp/lease-second.png"),
            isTemporary: true,
            format: .png,
            pixelWidth: 10,
            pixelHeight: 10,
            byteCount: 10
        )
        manager.recordCopy(artifact: first, changeCount: 7, providedTypes: [.png])
        manager.recordCopy(artifact: second, changeCount: 7, providedTypes: [.png])
        #expect(manager.activeLeaseCount == 2)
        #expect(manager.isReferencedByPasteboard(artifactID: first.id))
        #expect(manager.isReferencedByPasteboard(artifactID: second.id))
    }
}

struct CaptureDisplayResolverTests {
    private let main = CaptureScreenInfo(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        backingScaleFactor: 2,
        pixelWidth: 3840,
        pixelHeight: 2160
    )
    private let secondary = CaptureScreenInfo(
        displayID: 2,
        frame: CGRect(x: 1920, y: 0, width: 1280, height: 800),
        backingScaleFactor: 1,
        pixelWidth: 1280,
        pixelHeight: 800
    )

    @Test func pointerScreenWinsEvenWhenSizesLookAlike() {
        let resolution = CaptureDisplayResolver.resolve(
            mouseLocation: CGPoint(x: 2500, y: 400),
            screens: [main, secondary],
            mainDisplayID: 1
        )
        #expect(resolution.displayID == 2)
        #expect(resolution.source == .pointer)
    }

    @Test func aMissingRequestedDisplayIsNeverReplacedByASimilarOne() {
        #expect(CaptureDisplayResolver.exactMatch(99, in: [1, 2]) == nil)
        #expect(CaptureDisplayResolver.exactMatch(2, in: [1, 2]) == 2)
    }

    @Test func outputPixelsFollowPointPixelScaleOverBackingScale() {
        #expect(CaptureDisplayResolver.outputScale(screenBackingScale: 2, pointPixelScale: 1.5) == 1.5)
        #expect(CaptureDisplayResolver.outputScale(screenBackingScale: 2, pointPixelScale: 0) == 2)
    }
}

struct CaptureWindowFocusResolverTests {
    private func candidate(
        id: CGWindowID,
        frame: CGRect,
        zIndex: Int,
        title: String? = "Document"
    ) -> CaptureWindowCandidate {
        CaptureWindowCandidate(
            windowID: id,
            processID: 42,
            title: title,
            frame: frame,
            layer: 0,
            isOnScreen: true,
            zIndex: zIndex
        )
    }

    @Test func accessibilityFocusedWindowBeatsTheLargestWindow() {
        let selection = CaptureWindowFocusResolver.select(
            probe: FocusedWindowProbe(
                accessibilityTrusted: true,
                windowID: 7,
                title: "Focused",
                frame: CGRect(x: 0, y: 0, width: 300, height: 200)
            ),
            candidates: [
                candidate(id: 9, frame: CGRect(x: 0, y: 0, width: 1600, height: 1200), zIndex: 1),
                candidate(id: 7, frame: CGRect(x: 0, y: 0, width: 300, height: 200), zIndex: 2),
            ],
            allowLargestFallback: false
        )
        #expect(selection.windowID == 7)
        #expect(selection.source == .accessibilityFocusedWindow)
    }

    @Test func withoutAccessibilityTheFrontMostWindowIsADefinedAnswer() {
        let selection = CaptureWindowFocusResolver.select(
            probe: FocusedWindowProbe(accessibilityTrusted: false),
            candidates: [
                candidate(id: 4, frame: CGRect(x: 0, y: 0, width: 800, height: 600), zIndex: 1),
                candidate(id: 5, frame: CGRect(x: 0, y: 0, width: 200, height: 200), zIndex: 0),
            ],
            allowLargestFallback: false
        )
        #expect(selection.windowID == 5)
        #expect(selection.source == .frontmostWindow)
    }

    @Test func noEligibleWindowIsReportedInsteadOfGuessed() {
        let selection = CaptureWindowFocusResolver.select(
            probe: FocusedWindowProbe(accessibilityTrusted: false),
            candidates: [],
            allowLargestFallback: false
        )
        #expect(selection.windowID == nil)
        #expect(selection.source == .none)
    }
}

struct CaptureCompositeValidatorTests {
    @Test func aMissingDisplayFailsTheWholeComposite() {
        #expect(throws: CaptureCompositeError.self) {
            try CaptureCompositeValidator.validateCoverage(requested: [1, 2], captured: [1])
        }
    }

    @Test func coveragePassesWhenEveryRequestedDisplayWasCaptured() throws {
        try CaptureCompositeValidator.validateCoverage(requested: [1], captured: [1, 2])
    }

    @Test func anEmptyCropIsAFailureNotASkip() {
        #expect(throws: CaptureCompositeError.self) {
            try CaptureCompositeValidator.validateCrop(displayID: 3, image: nil)
        }
    }

    @Test func anUnexpectedOutputSizeIsReported() {
        let image = makeTestImage(width: 10, height: 10)
        #expect(throws: CaptureCompositeError.self) {
            try CaptureCompositeValidator.validateOutput(
                image: image,
                expectedSize: CGSize(width: 20, height: 20)
            )
        }
    }
}

struct RefreshHideLedgerTests {
    @Test func theFirstTokenHidesAndTheLastOneReveals() {
        var ledger = RefreshHideLedger()
        let session = UUID()
        let first = ledger.begin(sessionID: session)
        #expect(first.hide)
        #expect(ledger.end(token: first.token, sessionID: session) == .reveal)
        #expect(!ledger.isHolding(sessionID: session))
    }

    @Test func overlappingRefreshesHideOnlyOnceAndRevealAfterTheLast() {
        var ledger = RefreshHideLedger()
        let session = UUID()
        let first = ledger.begin(sessionID: session)
        let second = ledger.begin(sessionID: session)
        #expect(first.hide)
        #expect(!second.hide)
        #expect(ledger.end(token: first.token, sessionID: session) == .stillHidden)
        #expect(ledger.isHolding(sessionID: session))
        #expect(ledger.end(token: second.token, sessionID: session) == .reveal)
    }

    @Test func aCancelledSessionsTokenCannotReleaseANewerSession() {
        var ledger = RefreshHideLedger()
        let oldSession = UUID()
        let newSession = UUID()
        let oldToken = ledger.begin(sessionID: oldSession)
        let newToken = ledger.begin(sessionID: newSession)
        #expect(ledger.end(token: oldToken.token, sessionID: oldSession) == .reveal)
        #expect(ledger.isHolding(sessionID: newSession))
        #expect(ledger.end(token: newToken.token, sessionID: newSession) == .reveal)
    }

    @Test func releasingAnUnknownOrAlreadyReleasedTokenDoesNothing() {
        var ledger = RefreshHideLedger()
        let session = UUID()
        let token = ledger.begin(sessionID: session)
        #expect(ledger.end(token: UUID(), sessionID: session) == .untouched)
        _ = ledger.end(token: token.token, sessionID: session)
        #expect(ledger.end(token: token.token, sessionID: session) == .untouched)
    }

    @Test func endAllReleasesEveryOutstandingTokenForThatSession() {
        var ledger = RefreshHideLedger()
        let session = UUID()
        _ = ledger.begin(sessionID: session)
        _ = ledger.begin(sessionID: session)
        #expect(ledger.endAll(sessionID: session) == .reveal)
        #expect(!ledger.isHolding(sessionID: session))
        #expect(ledger.endAll(sessionID: session) == .untouched)
    }
}

struct WindowSelectionLoadingStateTests {
    @Test func anEmptyReadySnapshotMeansNothingSelectableNotAFailure() {
        let snapshot = WindowSelectionSnapshot(orderedCandidates: [])
        #expect(snapshot.isEmpty)
        #expect(snapshot.hitTest(at: .zero) == nil)
    }

    @Test func loadingReadyAndFailedAreDistinctStates() {
        #expect(WindowSelectionLoadState.loading != .ready)
        #expect(WindowSelectionLoadState.ready != .failed)
        #expect(WindowSelectionLoadState.failed != .loading)
    }
}

struct CapturePixelSizeTests {
    private func makeSnapshot(
        displayID: CGDirectDisplayID,
        frame: CGRect,
        pixelScale: CGFloat
    ) -> FrozenDisplaySnapshot {
        FrozenDisplaySnapshot(
            displayID: displayID,
            screenFrame: frame,
            scaleFactor: pixelScale,
            colorSpaceName: nil,
            image: makeTestImage(
                width: Int(frame.width * pixelScale),
                height: Int(frame.height * pixelScale)
            )
        )
    }

    @Test func retinaSelectionPredictsTheExactPixelsTheCropProduces() throws {
        let snapshot = makeSnapshot(displayID: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 150), pixelScale: 2)
        let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)
        let selection = AreaSelectionResult(
            target: .rect(CGRect(x: 10.3, y: 20.7, width: 100.25, height: 50.1)),
            displayID: 1,
            mode: .screenshot
        )

        let expected = try #require(session.expectedOutputPixelSize(for: selection))
        let cropped = try session.cropImage(for: selection)

        #expect(expected == CGSize(width: cropped.image.width, height: cropped.image.height))
        #expect(expected == CGSize(width: 202, height: 101))
    }

    @Test func aOneXDisplayPromotedToTwoXStillPredictsTheRealSize() throws {
        let snapshot = makeSnapshot(displayID: 4, frame: CGRect(x: 0, y: 0, width: 200, height: 150), pixelScale: 1)
        let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)
        let selection = AreaSelectionResult(
            target: .rect(CGRect(x: 10, y: 20, width: 100, height: 50)),
            displayID: 4,
            mode: .screenshot
        )

        let expected = try #require(session.expectedOutputPixelSize(for: selection, minimumOutputScaleFactor: 2))
        let cropped = try session.cropImage(for: selection, minimumOutputScaleFactor: 2)

        #expect(expected == CGSize(width: cropped.image.width, height: cropped.image.height))
        #expect(expected == CGSize(width: 200, height: 100))
    }

    @Test func aMixedDPISelectionReportsTheCompositeOutputSizeNotThePointSize() throws {
        let retina = makeSnapshot(displayID: 7, frame: CGRect(x: 0, y: 0, width: 100, height: 100), pixelScale: 2)
        let standard = makeSnapshot(displayID: 8, frame: CGRect(x: 100, y: 0, width: 150, height: 100), pixelScale: 1)
        let session = FrozenAreaCaptureSession.fromSnapshots([retina, standard])
        let selection = AreaSelectionResult(
            target: .rect(CGRect(x: -10, y: -5, width: 260, height: 110)),
            displayID: 7,
            mode: .screenshot,
            displayIDs: [7, 8]
        )

        let expected = try #require(session.expectedOutputPixelSize(for: selection))
        let cropped = try session.cropCompositeImage(for: selection)

        #expect(expected == CGSize(width: cropped.image.width, height: cropped.image.height))
        #expect(expected == CGSize(width: 500, height: 200))
        #expect(expected != selection.rect.size)
    }
}

struct CaptureHistoryServiceTests {
    @MainActor private func makeHistoryStore() throws -> (CaptureHistoryStore, UserDefaults, String) {
        let suite = "CaptureHistoryServiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (CaptureHistoryStore(defaults: defaults), defaults, suite)
    }

    @Test @MainActor func aPromotedManualSaveLeavesOnePermanentRecord() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, defaults, suite) = try makeHistoryStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let temporary = directory.appendingPathComponent("Capture-\(UUID().uuidString).png")
        try Data([0]).write(to: temporary)
        SmartCaptureHistoryStore.record(url: temporary, width: 10, height: 8, byteCount: 1, defaults: defaults)

        let permanent = directory.appendingPathComponent("Saved Capture.png")
        try Data([1, 2, 3]).write(to: permanent)
        store.recordSavedCapture(
            url: permanent,
            width: 20,
            height: 8,
            byteCount: 3,
            previousPath: temporary.path,
            isVideo: false
        )

        let items = SmartCaptureHistoryStore.load(defaults: defaults)
        #expect(items.count == 1)
        #expect(URL(fileURLWithPath: items[0].path).standardizedFileURL == permanent.standardizedFileURL)
        #expect(store.hasRecord(forFilePath: permanent.path))
        #expect(!store.hasRecord(forFilePath: temporary.path))
    }

    @Test @MainActor func deletingACaptureLeavesNoStaleHistory() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, defaults, suite) = try makeHistoryStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let url = directory.appendingPathComponent("Deleted.png")
        try Data([4]).write(to: url)
        store.recordSavedCapture(url: url, width: 4, height: 4, byteCount: 1, previousPath: nil, isVideo: false)

        store.removeByFilePath(url.path)

        #expect(!store.hasRecord(forFilePath: url.path))
        #expect(SmartCaptureHistoryStore.load(defaults: defaults).isEmpty)
    }

    @Test @MainActor func quickAccessWritesNotifyTheLiveHistoryModel() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, defaults, suite) = try makeHistoryStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let url = directory.appendingPathComponent("Notified.png")
        try Data([5]).write(to: url)

        await confirmation("history change posted once", expectedCount: 1) { confirm in
            let token = NotificationCenter.default.addObserver(
                forName: SmartCaptureHistoryStore.externalChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(token) }
            store.recordSavedCapture(url: url, width: 4, height: 4, byteCount: 1, previousPath: nil, isVideo: false)
        }
    }

    @Test @MainActor func aVideoRecordingKeepsItsMediaKindInHistory() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, defaults, suite) = try makeHistoryStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let url = directory.appendingPathComponent("Recording.mov")
        try Data([6]).write(to: url)
        store.recordSavedCapture(url: url, width: 640, height: 360, byteCount: 1, previousPath: nil, isVideo: true)

        #expect(SmartCaptureHistoryStore.load(defaults: defaults).first?.kind == .video)
    }

    @Test func anAnnotationWriteReplacesTheCaptureOnlyWithDecodableBytes() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Annotated.png")
        try Data([9, 9]).write(to: url)

        try QuickAccessManager.writeAnnotatedImage(makeTestImage(width: 40, height: 30), to: url)

        let data = try Data(contentsOf: url)
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 40)
        #expect(image.height == 30)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["Annotated.png"])
    }

    @Test func aFailedAnnotationWriteLeavesTheOriginalBytesUntouched() throws {
        let directory = makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("Original.png")
        let original = Data([1, 2, 3, 4])
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        #expect(throws: (any Error).self) {
            try QuickAccessManager.writeAnnotatedImage(makeTestImage(), to: url)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(try Data(contentsOf: url) == original)
    }
}

struct CaptureImageWorkGateTests {
    @Test func theGateNeverRunsMoreThanItsLimitAtOnce() async {
        let gate = CaptureImageWorkGate(limit: 2)
        let tracker = GateConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    await gate.withPermit {
                        tracker.enter(index)
                        usleep(20_000)
                        tracker.leave()
                    }
                }
            }
        }

        #expect(tracker.maximumConcurrent <= 2)
        #expect(tracker.total == 6)
    }

    @Test func aReleasedPermitIsHandedToTheNextWaiter() async {
        let gate = CaptureImageWorkGate(limit: 1)
        let entered = GateFlag()

        await gate.acquire()
        let waiter = Task {
            await gate.acquire()
            entered.set()
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(entered.value == false)

        gate.release()
        await waiter.value
        #expect(entered.value == true)
        gate.release()
    }

    @Test func aSnapshotCopyCropsOffTheMainActor() async throws {
        let snapshot = FrozenDisplaySnapshot(
            displayID: 9,
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scaleFactor: 2,
            colorSpaceName: nil,
            image: makeTestImage(width: 200, height: 200)
        )
        let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)
        let snapshots = session.allSnapshots()
        let selection = AreaSelectionResult(
            target: .rect(CGRect(x: 10, y: 10, width: 50, height: 40)),
            displayID: 9,
            mode: .screenshot
        )

        let crop = try await Task.detached {
            try await CaptureImageWorkGate.shared.withPermit {
                try FrozenAreaCaptureSession.cropImage(snapshots: snapshots, for: selection)
            }
        }.value

        #expect(crop.image.width == 100)
        #expect(crop.image.height == 80)
    }
}

private final class GateConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var count = 0

    var maximumConcurrent: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func enter(_: Int) {
        lock.lock()
        active += 1
        peak = max(peak, active)
        count += 1
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

private final class GateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}
