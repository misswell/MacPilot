//
//  RecordingDeviceDiscovery.swift
//  MacPilot
//
//  Stateless discovery of capture hardware: cameras, microphones, and
//  attached iPhone/iPad devices, plus the sample-rate query for the
//  selected microphone and the CoreMediaIO flag that allows mobile-device
//  screen capture.
//

import AVFoundation
import CoreAudio
import CoreMedia
import CoreMediaIO

enum ScreenRecordingDeviceDiscovery {
    nonisolated static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    nonisolated static func availableMicrophones() -> [AVCaptureDevice] {
        // .builtInMicrophone is deprecated (renamed .microphone) on macOS 15;
        // construct the legacy identifier from its raw value so the macOS 14
        // discovery path stays warning-free.
        let builtInMicrophone = AVCaptureDevice.DeviceType(rawValue: "builtinMicrophone")
        let discovery: AVCaptureDevice.DiscoverySession
        if #available(macOS 15.0, *) {
            discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [builtInMicrophone, .microphone],
                mediaType: .audio,
                position: .unspecified
            )
        } else {
            discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [builtInMicrophone, .external],
                mediaType: .audio,
                position: .unspecified
            )
        }
        return discovery.devices.filter { !$0.localizedName.contains("CADefaultDeviceAggregate") }
    }

    nonisolated static func availableMobileDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices
    }

    /// Active format sample rate of the named microphone, or of the system
    /// default input device when "default" is selected.
    nonisolated static func selectedMicrophoneSampleRate(deviceName: String) -> Int {
        if deviceName != "default",
           let device = availableMicrophones().first(where: { $0.localizedName == deviceName }),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee {
            return Int(asbd.mSampleRate)
        }
        return defaultInputSampleRate() ?? 48_000
    }

    private nonisolated static func defaultInputSampleRate() -> Int? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        guard status == noErr else { return nil }
        var sampleRate: Double = 0
        propertySize = UInt32(MemoryLayout<Double>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let rateStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &sampleRate)
        guard rateStatus == noErr else { return nil }
        return Int(sampleRate)
    }

    /// Allows screen capture of attached mobile devices (the CoreMediaIO
    /// flag that must be on before iPhone screens can be recorded).
    nonisolated static func enableMobileDeviceScreenCapture() {
        var allow: UInt32 = 1
        let dataSize: UInt32 = 4
        let zero: UInt32 = 0
        var property = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &property,
            zero,
            nil,
            dataSize,
            &allow
        )
    }
}
