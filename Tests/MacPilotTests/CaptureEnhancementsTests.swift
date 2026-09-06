//
//  CaptureEnhancementsTests.swift
//  MacPilot
//
//  Tests for the delayed-capture entry point, the post-selection HUD
//  spotlight bridge, the live microphone level math, and the GIF export
//  options.
//

import AVFoundation
import Carbon.HIToolbox
import Foundation
import Testing
@testable import MacPilot

struct CaptureEnhancementsTests {
    // MARK: - Delayed capture shortcut

    @Test func delayedCaptureShortcutDefaultsToOptionCommandSeven() {
        let binding = ScreenCaptureShortcutKind.delayedArea.defaultBinding
        #expect(binding.keyCode == UInt16(kVK_ANSI_7))
        #expect(binding.modifiers == [.command, .option])
        #expect(binding.isValid)
        #expect(ScreenCaptureShortcutKind.delayedArea.titleKey == "scDelayedCaptureShortcut")
        #expect(ScreenCaptureShortcutKind.delayedArea.id == "delayedArea")
    }

    @Test func delayedCaptureShortcutRoundTripsThroughSettings() throws {
        var settings = ScreenCaptureSettings()
        #expect(settings.delayedAreaCaptureShortcut == ScreenCaptureShortcutKind.delayedArea.defaultBinding)
        #expect(settings.delayedCaptureSeconds == 5)

        let custom = SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .option])
        settings.delayedAreaCaptureShortcut = custom
        settings.delayedCaptureSeconds = 10
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: data)
        #expect(decoded.delayedAreaCaptureShortcut == custom)
        #expect(decoded.delayedCaptureSeconds == 10)
    }

    @Test func legacyCaptureConfigDecodesDelayedCaptureDefaults() throws {
        // A config written before the delayed-capture entry point has no
        // delayed keys at all; decoding must supply safe defaults.
        let json = #"{"screenshotEnabled": true}"#
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: Data(json.utf8))
        #expect(decoded.delayedAreaCaptureShortcut == ScreenCaptureShortcutKind.delayedArea.defaultBinding)
        #expect(decoded.delayedCaptureSeconds == 5)
    }

    @Test func delayedCaptureSecondsAreClamped() throws {
        #expect(ScreenCaptureSettings(delayedCaptureSeconds: 0).delayedCaptureSeconds == 1)
        #expect(ScreenCaptureSettings(delayedCaptureSeconds: 999).delayedCaptureSeconds == 60)
    }

    @Test @MainActor func delayedCaptureSecondsSetterClampsAndPersists() {
        let model = ScreenCaptureModel()
        defer { model.shutdown() }
        var persisted: ScreenCaptureSettings?
        model.persist = { persisted = model.settings }
        model.setDelayedCaptureSeconds(10_000)
        #expect(model.settings.delayedCaptureSeconds == 60)
        #expect(persisted?.delayedCaptureSeconds == 60)
        model.setDelayedCaptureSeconds(5)
        #expect(model.settings.delayedCaptureSeconds == 5)
    }

    // MARK: - Countdown arithmetic

    @Test func delayedCaptureCountdownAdvancesAndFinishes() {
        let countdown = DelayedCaptureCountdown(totalSeconds: 5)
        #expect(countdown.remainingSeconds == 5)
        #expect(countdown.progress == 0)
        #expect(!countdown.isFinished)

        let halfway = countdown.advanced(by: 3)
        #expect(halfway.remainingSeconds == 2)
        #expect(abs(halfway.progress - 0.6) < 0.0001)
        #expect(!halfway.isFinished)

        let finished = halfway.advanced(by: 2)
        #expect(finished.isFinished)
        #expect(finished.remainingSeconds == 0)
        #expect(finished.progress == 1)
        // Advancing past the end never wraps back into a pending state.
        #expect(finished.advanced(by: 4).isFinished)
    }

    @Test func delayedCaptureCountdownNormalizesUnsafeTotals() {
        let zero = DelayedCaptureCountdown(totalSeconds: 0)
        #expect(zero.totalSeconds == 1)
        #expect(DelayedCaptureCountdown(totalSeconds: -3).totalSeconds == 1)
    }

    // MARK: - Spotlight tool bridge

    @Test func hudSpotlightToolBridgesIntoTheAnnotationModel() {
        #expect(AreaSelectionAnnotationTool.spotlight.smartAnnotationTool == .spotlight)
        #expect(SmartAnnotationTool.spotlight.titleKey == "scAnnotationSpotlight")
        #expect(SmartAnnotationTool.spotlight.systemImage == "circle.dashed.inset.filled")
    }

    // MARK: - Microphone level

    @Test func microphoneRMSIsZeroForSilenceAndScalesWithAmplitude() {
        func makeBuffer(amplitude: Float, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            if let data = buffer.floatChannelData?[0] {
                for frame in 0..<Int(frameCount) {
                    data[frame] = amplitude
                }
            }
            return buffer
        }

        let silence = ScreenRecordingEngine.microphoneRMS(of: makeBuffer(amplitude: 0, frameCount: 1_024))
        #expect(silence == 0)

        let loud = ScreenRecordingEngine.microphoneRMS(of: makeBuffer(amplitude: 0.5, frameCount: 1_024))
        #expect(abs(loud - 0.5) < 0.001)

        let quiet = ScreenRecordingEngine.microphoneRMS(of: makeBuffer(amplitude: 0.1, frameCount: 1_024))
        #expect(quiet < loud)
    }

    // MARK: - GIF export options

    @Test func gifExportOptionsDefaultClampAndRoundTrip() throws {
        #expect(ScreenRecordingSettings().gifFramesPerSecond == 15)
        #expect(ScreenRecordingSettings().gifMaximumWidth == 960)
        #expect(ScreenRecordingSettings(gifFramesPerSecond: 500).gifFramesPerSecond == 30)
        #expect(ScreenRecordingSettings(gifFramesPerSecond: 1).gifFramesPerSecond == 5)
        #expect(ScreenRecordingSettings(gifMaximumWidth: 9_999).gifMaximumWidth == 2_000)
        #expect(ScreenRecordingSettings(gifMaximumWidth: 10).gifMaximumWidth == 200)

        var settings = ScreenRecordingSettings()
        settings.gifFramesPerSecond = 20
        settings.gifMaximumWidth = 720
        let decoded = try JSONDecoder().decode(ScreenRecordingSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.gifFramesPerSecond == 20)
        #expect(decoded.gifMaximumWidth == 720)
    }

    @Test func legacyRecordingConfigDecodesGIFDefaults() throws {
        let json = #"{"format": "mp4"}"#
        let decoded = try JSONDecoder().decode(ScreenRecordingSettings.self, from: Data(json.utf8))
        #expect(decoded.gifFramesPerSecond == 15)
        #expect(decoded.gifMaximumWidth == 960)
    }

    @Test @MainActor func recordingModelGIFSettersClampAndPersist() {
        let model = ScreenRecordingModel()
        defer { model.shutdown() }
        model.setGIFFramesPerSecond(20)
        model.setGIFMaximumWidth(720)
        #expect(model.settings.gifFramesPerSecond == 20)
        #expect(model.settings.gifMaximumWidth == 720)
        model.setGIFFramesPerSecond(120)
        model.setGIFMaximumWidth(4_000)
        #expect(model.settings.gifFramesPerSecond == 30)
        #expect(model.settings.gifMaximumWidth == 2_000)
    }
}
