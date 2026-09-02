//
//  RecordingSampleBuffers.swift
//  MacPilot
//
//  CMSampleBuffer plumbing shared by the recording pipeline: pause-aware
//  timestamp shifting for stream samples and host-clock stamping that lets
//  AVAudioEngine's PCM buffers feed an AVAssetWriter audio input.
//

import AVFoundation
import CoreMedia

/// Re-stamps a sample buffer's timestamps back by `offset` so the written
/// file has no gaps for the time the recording spent paused.
func sampleBufferRetimed(_ sampleBuffer: CMSampleBuffer, shiftingBy offset: CMTime) -> CMSampleBuffer? {
    guard offset.isValid, CMTimeCompare(offset, .zero) != 0 else { return sampleBuffer }
    var entryCount = 0
    guard CMSampleBufferGetSampleTimingInfoArray(
        sampleBuffer,
        entryCount: 0,
        arrayToFill: nil,
        entriesNeededOut: &entryCount
    ) == noErr, entryCount > 0 else {
        return sampleBuffer
    }
    var timing = Array(
        repeating: CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        ),
        count: entryCount
    )
    let readStatus = timing.withUnsafeMutableBufferPointer { buffer in
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: entryCount,
            arrayToFill: buffer.baseAddress,
            entriesNeededOut: &entryCount
        )
    }
    guard readStatus == noErr else { return sampleBuffer }
    for index in timing.indices {
        if timing[index].presentationTimeStamp.isValid,
           !timing[index].presentationTimeStamp.isIndefinite {
            timing[index].presentationTimeStamp = CMTimeSubtract(
                timing[index].presentationTimeStamp,
                offset
            )
        }
        if timing[index].decodeTimeStamp.isValid,
           !timing[index].decodeTimeStamp.isIndefinite {
            timing[index].decodeTimeStamp = CMTimeSubtract(
                timing[index].decodeTimeStamp,
                offset
            )
        }
    }
    var retimed: CMSampleBuffer?
    let status = timing.withUnsafeBufferPointer { buffer in
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: buffer.baseAddress,
            sampleBufferOut: &retimed
        )
    }
    return status == noErr ? retimed : sampleBuffer
}

extension AVAudioPCMBuffer {
    /// Wraps the buffer's PCM payload in a CMSampleBuffer stamped with the
    /// host-time clock, so microphone samples can feed a writer audio input.
    var hostClockSampleBuffer: CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(format.sampleRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: mutableAudioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
