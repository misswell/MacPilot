//
//  MacOutputLevel.swift
//  MacPilot
//
//  The two output levels the iPhone remote shows and drives: display
//  brightness and the default output device's volume.
//
//  It lives next to the screen control code because it is the other half of
//  "what the remote panel reports": `MacScreenControlService.currentState()`
//  composes both into every `MacRemoteState` it returns, so the phone reads the
//  levels from the same response it already uses for lock state.
//
//  A snapshot never fabricates a value. A Mac whose panel backlight cannot be
//  driven (clamshell with a third party monitor, for instance) reports no
//  brightness, and a Mac with no output device reports no volume; the phone
//  hides that slider instead of showing one that cannot work.
//

import CoreAudio
import Foundation
import MacPilotRemoteProtocol

/// Snapshot of both levels, in `0...1`, with `nil` for "not available here".
enum MacOutputLevel {
    struct Snapshot: Equatable {
        var brightness: Double?
        var volume: Double?
        var muted: Bool?
    }

    @MainActor
    static func snapshot() -> Snapshot {
        let output = SystemVolume.state()
        return Snapshot(
            brightness: DisplayPower.brightness(),
            volume: output.volume,
            muted: output.muted
        )
    }

    /// - Returns: false when no online display has a drivable backlight.
    @MainActor
    @discardableResult
    static func setBrightness(_ value: Double) -> Bool {
        DisplayPower.setBrightness(value)
    }

    /// - Parameter muted: `nil` leaves the mute state untouched.
    /// - Returns: false when the default output device exposes no volume control.
    @discardableResult
    static func setVolume(_ value: Double, muted: Bool?) -> Bool {
        SystemVolume.setVolume(value, muted: muted)
    }
}

/// Volume and mute of the default output device, through CoreAudio.
///
/// CoreAudio rather than `osascript`: reading the system volume through
/// AppleScript needs Automation permission and spawns a process per poll, while
/// this is a property read on the device the system already routes audio to.
enum SystemVolume {
    struct State: Equatable {
        var volume: Double?
        var muted: Bool?
    }

    static func state() -> State {
        guard let device = defaultOutputDevice() else { return State(volume: nil, muted: nil) }
        return State(volume: volume(of: device), muted: isMuted(device))
    }

    /// - Parameter muted: `nil` leaves the mute state untouched.
    /// - Returns: false when no volume control could be written.
    @discardableResult
    static func setVolume(_ value: Double, muted: Bool?) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let target = Float(min(max(value, 0), 1))

        var applied = false
        // Most devices expose a single scalar for the whole device; some only
        // have per-channel controls, so both channels are written in that case
        // rather than leaving the slider visibly out of sync with the right
        // channel.
        if isSettable(volumeAddress(element: kAudioObjectPropertyElementMain), on: device) {
            applied = write(target, to: volumeAddress(element: kAudioObjectPropertyElementMain), on: device)
        } else {
            for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            where isSettable(volumeAddress(element: element), on: device) {
                applied = write(target, to: volumeAddress(element: element), on: device) || applied
            }
        }

        if let muted {
            let flag = UInt32(muted ? 1 : 0)
            write(flag, to: muteAddress(element: kAudioObjectPropertyElementMain), on: device)
        }
        return applied
    }

    // MARK: - CoreAudio plumbing

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    private static func muteAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    /// Averages the channel controls when the device has no single scalar, so a
    /// stereo pair that drifted apart still reports one believable number.
    private static func volume(of device: AudioDeviceID) -> Double? {
        if let scalar = readScalar(from: volumeAddress(element: kAudioObjectPropertyElementMain), on: device) {
            return Double(scalar)
        }
        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .compactMap { readScalar(from: volumeAddress(element: $0), on: device) }
        guard !channels.isEmpty else { return nil }
        return Double(channels.reduce(0, +) / Float(channels.count))
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        readFlag(from: muteAddress(element: kAudioObjectPropertyElementMain), on: device)
            .map { $0 != 0 }
    }

    private static func isSettable(_ address: AudioObjectPropertyAddress, on device: AudioDeviceID) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func readScalar(
        from address: AudioObjectPropertyAddress,
        on device: AudioDeviceID
    ) -> Float? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func readFlag(
        from address: AudioObjectPropertyAddress,
        on device: AudioDeviceID
    ) -> UInt32? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func write(
        _ value: Float,
        to address: AudioObjectPropertyAddress,
        on device: AudioDeviceID
    ) -> Bool {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    @discardableResult
    private static func write(
        _ value: UInt32,
        to address: AudioObjectPropertyAddress,
        on device: AudioDeviceID
    ) -> Bool {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
