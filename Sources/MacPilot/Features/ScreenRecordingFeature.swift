import Foundation

/// Owns the recorder's hot keys, capture sessions, and auxiliary surfaces as
/// one lifecycle entry without conflating feature stop with stop recording.
@MainActor
final class ScreenRecordingFeature: ManagedFeature {
    let identifier = "screenRecording"
    var isRunning: Bool { recorder.isRuntimeActive }

    private let recorder: ScreenRecordingModel

    init(recorder: ScreenRecordingModel) {
        self.recorder = recorder
    }

    func start() { recorder.activateFromConfiguration() }
    func stop() { recorder.shutdown() }
}
