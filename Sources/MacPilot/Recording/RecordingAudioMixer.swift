//
//  RecordingAudioMixer.swift
//  MacPilot
//
//  Post-recording audio assembly. When a recording captured both system
//  audio and the microphone with "mix microphone into main track" enabled,
//  the finished file's audio tracks are blended into one and re-muxed with
//  the original video. The mix requires a re-encode pass; the re-mux is a
//  passthrough so the video bitstream is untouched.
//

import AVFoundation
import Foundation

enum ScreenRecordingAudioMixer {
    /// Blends every audio track of the asset into one and re-muxes the
    /// result with the original video. On success the caller owns
    /// `videoURL`'s twin file (same name minus the extra container
    /// extension) and should delete `videoURL`.
    static func mixAndRemux(videoURL: URL, container: AVFileType) async -> Result<URL, Error> {
        let asset = AVURLAsset(url: videoURL)
        let audioOnlyURL = videoURL.deletingPathExtension()
        let remuxedURL = audioOnlyURL.deletingPathExtension()

        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard audioTracks.count > 1 else {
                return .failure(mixerError("Not enough audio tracks found."))
            }
            let duration = try await asset.load(.duration)

            // Pass 1: render all audio tracks into a single mixed track.
            let audioComposition = AVMutableComposition()
            for track in audioTracks {
                guard let compositionTrack = audioComposition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: track,
                    at: .zero
                )
            }
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioTracks.map {
                let parameters = AVMutableAudioMixInputParameters(track: $0)
                parameters.trackID = $0.trackID
                return parameters
            }
            guard let mixSession = AVAssetExportSession(
                asset: audioComposition,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                return .failure(mixerError("Failed to create the audio mix export session."))
            }
            mixSession.outputURL = audioOnlyURL
            mixSession.outputFileType = container
            mixSession.audioMix = audioMix
            await mixSession.export()
            guard mixSession.status == .completed else {
                return .failure(mixSession.error ?? mixerError("Audio mix export failed."))
            }

            // Pass 2: passthrough re-mux of the original video with the
            // mixed audio track.
            let mixedAsset = AVURLAsset(url: audioOnlyURL)
            let composition = AVMutableComposition()
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first,
                  let compositionVideoTrack = composition.addMutableTrack(
                      withMediaType: .video,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                return .failure(mixerError("Failed to load the video track."))
            }
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: .zero
            )
            for track in try await mixedAsset.loadTracks(withMediaType: .audio) {
                guard let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: track,
                    at: .zero
                )
            }
            guard let remuxSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                return .failure(mixerError("Failed to create the remux export session."))
            }
            remuxSession.outputURL = remuxedURL
            remuxSession.outputFileType = container
            remuxSession.audioMix = audioMix
            await remuxSession.export()
            guard remuxSession.status == .completed else {
                return .failure(remuxSession.error ?? mixerError("Remux export failed."))
            }

            try? FileManager.default.removeItem(at: audioOnlyURL)
            return .success(remuxedURL)
        } catch {
            return .failure(error)
        }
    }

    private static func mixerError(_ message: String) -> NSError {
        NSError(
            domain: "ScreenRecordingAudioMixer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
