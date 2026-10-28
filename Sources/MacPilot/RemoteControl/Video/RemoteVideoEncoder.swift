import CoreMedia
import Foundation
import MacPilotRemoteProtocol
import VideoToolbox

/// All session mutations run on the capture queue. Encoded callback buffers
/// are copied into Sendable Data before leaving VideoToolbox's callback.
final class RemoteVideoEncoder {
    private var session: VTCompressionSession?

    func configure(width: Int, height: Int, quality: RemoteVideoQuality) throws {
        stop()
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw RemoteVideoFailure.encoder }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_H264EntropyMode: kVTH264EntropyMode_CABAC,
            kVTCompressionPropertyKey_AverageBitRate: quality.bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: quality.fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: quality.fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0
        ]
        guard VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr,
              VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { throw RemoteVideoFailure.encoder }
    }

    func encode(_ pixel: CVPixelBuffer, time: CMTime, forceKeyFrame: Bool,
                output: @escaping @Sendable (RemoteVideoPacket?, Double) -> Void) {
        guard let session else { output(nil, 0); return }
        let started = ProcessInfo.processInfo.systemUptime
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixel,
            presentationTimeStamp: time, duration: .invalid,
            frameProperties: forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
            infoFlagsOut: nil) { status, _, sample in
                let duration = (ProcessInfo.processInfo.systemUptime - started) * 1000
                guard status == noErr, let sample, let packet = Self.packet(from: sample) else {
                    output(nil, duration); return
                }
                output(packet, duration)
            }
        if status != noErr { output(nil, (ProcessInfo.processInfo.systemUptime - started) * 1000) }
    }

    private static func packet(from sample: CMSampleBuffer) -> RemoteVideoPacket? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var sets: [Data] = []
        if key {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard status == noErr else { return nil }
        let frame = RemoteH264Frame(sps: sets.first ?? Data(), pps: sets.last ?? Data(), avcc: bytes)
        guard let payload = try? frame.encoded() else { return nil }
        return RemoteVideoPacket(frameType: key ? .keyFrame : .deltaFrame, payload: payload)
    }

    func stop() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }
    deinit { stop() }
}

enum RemoteVideoFailure: Error { case permission, capture, encoder, transport }
