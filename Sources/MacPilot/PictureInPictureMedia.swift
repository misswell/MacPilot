// PictureInPictureMedia.swift
// System Now Playing integration for Picture-in-Picture media overlays.

import AppKit
import Darwin
import Foundation
import SwiftUI

struct PiPNowPlayingSnapshot: Equatable, Sendable {
    let isPlaying: Bool
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let parentBundleIdentifier: String?
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let timestamp: Date?
    let playbackRate: Double

    func belongs(to source: PiPSource) -> Bool {
        if processIdentifier > 0, processIdentifier == source.processID { return true }
        guard let sourceBundleIdentifier = source.bundleIdentifier else { return false }
        return bundleIdentifier == sourceBundleIdentifier || parentBundleIdentifier == sourceBundleIdentifier
    }

    func liveElapsedTime(at date: Date = Date()) -> Double? {
        guard let elapsedTime else { return nil }
        let advanced: Double
        if isPlaying, let timestamp {
            advanced = elapsedTime + max(0, date.timeIntervalSince(timestamp)) * max(0, playbackRate)
        } else {
            advanced = elapsedTime
        }
        if let duration { return min(duration, max(0, advanced)) }
        return max(0, advanced)
    }
}

private struct PiPMediaInfoFields: Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let timestamp: Date?
    let playbackRate: Double

    var hasContent: Bool {
        title != nil || artist != nil || duration != nil || elapsedTime != nil
    }
}

private typealias MRGetNowPlayingInfo = @convention(c) (
    DispatchQueue,
    @escaping @convention(block) (CFDictionary?) -> Void
) -> Void
private typealias MRGetNowPlayingClients = @convention(c) (
    DispatchQueue,
    @escaping @convention(block) (NSArray?) -> Void
) -> Void
private typealias MRGetNowPlayingInfoForClient = @convention(c) (
    AnyObject,
    DispatchQueue,
    @escaping @convention(block) (CFDictionary?) -> Void
) -> Void
private typealias MRGetNowPlayingPID = @convention(c) (
    DispatchQueue,
    @escaping @convention(block) (Int32) -> Void
) -> Void
private typealias MRGetLocalOrigin = @convention(c) () -> AnyObject?
private typealias MRClientGetString = @convention(c) (AnyObject) -> NSString?
private typealias MRClientGetPID = @convention(c) (AnyObject) -> Int32
private typealias MRSendCommand = @convention(c) (Int32, CFDictionary?) -> Bool
private typealias MRSendCommandToClient = @convention(c) (
    Int32,
    AnyObject?,
    NSDictionary?,
    AnyObject,
    Int32,
    Int32,
    AnyObject?
) -> AnyObject?
private typealias MRSetElapsedTime = @convention(c) (Double) -> Void

private final class PiPMediaSnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [PiPNowPlayingSnapshot] = []

    func append(_ snapshot: PiPNowPlayingSnapshot) {
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    func values() -> [PiPNowPlayingSnapshot] {
        lock.lock()
        let values = snapshots
        lock.unlock()
        return values
    }
}

final class PiPMediaRemoteBridge: @unchecked Sendable {
    private static let frameworkPaths = [
        "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/A/MediaRemote",
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    ]

    private let callbackQueue = DispatchQueue(label: "com.misswell.macpilot.pip.media-remote")
    private let clientLock = NSLock()
    private var clientsByProcessIdentifier: [pid_t: AnyObject] = [:]
    private let handle: UnsafeMutableRawPointer?
    private let getNowPlayingInfo: MRGetNowPlayingInfo?
    private let getNowPlayingClients: MRGetNowPlayingClients?
    private let getNowPlayingInfoForClient: MRGetNowPlayingInfoForClient?
    private let getNowPlayingPID: MRGetNowPlayingPID?
    private let getLocalOrigin: MRGetLocalOrigin?
    private let getClientBundleIdentifier: MRClientGetString?
    private let getClientParentBundleIdentifier: MRClientGetString?
    private let getClientPID: MRClientGetPID?
    private let sendCommand: MRSendCommand?
    private let sendCommandToClient: MRSendCommandToClient?
    private let setElapsedTime: MRSetElapsedTime?
    private let playbackPositionKey: String
    private let titleKey: String
    private let artistKey: String
    private let albumKey: String
    private let durationKey: String
    private let elapsedTimeKey: String
    private let playbackRateKey: String
    private let timestampKey: String

    init() {
        let handle = Self.frameworkPaths.lazy.compactMap { dlopen($0, RTLD_NOW) }.first
        self.handle = handle
        getNowPlayingInfo = Self.function(handle, named: "MRMediaRemoteGetNowPlayingInfo", as: MRGetNowPlayingInfo.self)
        getNowPlayingClients = Self.function(handle, named: "MRMediaRemoteGetNowPlayingClients", as: MRGetNowPlayingClients.self)
        getNowPlayingInfoForClient = Self.function(handle, named: "MRMediaRemoteGetNowPlayingInfoForClient", as: MRGetNowPlayingInfoForClient.self)
        getNowPlayingPID = Self.function(handle, named: "MRMediaRemoteGetNowPlayingApplicationPID", as: MRGetNowPlayingPID.self)
        getLocalOrigin = Self.function(handle, named: "MRMediaRemoteGetLocalOrigin", as: MRGetLocalOrigin.self)
        getClientBundleIdentifier = Self.function(handle, named: "MRNowPlayingClientGetBundleIdentifier", as: MRClientGetString.self)
        getClientParentBundleIdentifier = Self.function(handle, named: "MRNowPlayingClientGetParentAppBundleIdentifier", as: MRClientGetString.self)
        getClientPID = Self.function(handle, named: "MRNowPlayingClientGetProcessIdentifier", as: MRClientGetPID.self)
        sendCommand = Self.function(handle, named: "MRMediaRemoteSendCommand", as: MRSendCommand.self)
        sendCommandToClient = Self.function(handle, named: "MRMediaRemoteSendCommandToClient", as: MRSendCommandToClient.self)
        setElapsedTime = Self.function(handle, named: "MRMediaRemoteSetElapsedTime", as: MRSetElapsedTime.self)
        playbackPositionKey = Self.string(handle, named: "kMRMediaRemoteOptionPlaybackPosition") ?? "kMRMediaRemoteOptionPlaybackPosition"
        titleKey = Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoTitle") ?? "kMRMediaRemoteNowPlayingInfoTitle"
        artistKey = Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoArtist") ?? "kMRMediaRemoteNowPlayingInfoArtist"
        albumKey = Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoAlbum") ?? "kMRMediaRemoteNowPlayingInfoAlbum"
        durationKey = Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoDuration") ?? "kMRMediaRemoteNowPlayingInfoDuration"
        elapsedTimeKey = Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoElapsedTime") ?? "kMRMediaRemoteNowPlayingInfoElapsedTime"
        playbackRateKey = Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoPlaybackRate") ?? "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        timestampKey = Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoTimestamp") ?? "kMRMediaRemoteNowPlayingInfoTimestamp"
    }

    var isAvailable: Bool { getNowPlayingInfo != nil }

    func snapshots() async -> [PiPNowPlayingSnapshot] {
        guard isAvailable else { return [] }
        return await withCheckedContinuation { continuation in
            fetchSnapshots { snapshots in
                continuation.resume(returning: snapshots)
            }
        }
    }

    @discardableResult
    func togglePlayPause(for processIdentifier: pid_t) -> Bool {
        send(command: 2, to: processIdentifier, position: nil)
    }

    @discardableResult
    func seek(to position: Double, for processIdentifier: pid_t) -> Bool {
        send(command: 24, to: processIdentifier, position: max(0, position))
    }

    private func fetchSnapshots(completion: @escaping @Sendable ([PiPNowPlayingSnapshot]) -> Void) {
        guard let getNowPlayingClients, let getNowPlayingInfoForClient, let getClientPID else {
            fetchGlobalSnapshot(completion: completion)
            return
        }

        getNowPlayingClients(callbackQueue) { [weak self] array in
            guard let self else {
                completion([])
                return
            }
            let clients = (array as? [AnyObject]) ?? []
            guard !clients.isEmpty else {
                self.fetchGlobalSnapshot(completion: completion)
                return
            }

            let group = DispatchGroup()
            let collector = PiPMediaSnapshotCollector()
            var clientMap: [pid_t: AnyObject] = [:]
            for client in clients {
                let processIdentifier = pid_t(getClientPID(client))
                if processIdentifier > 0 { clientMap[processIdentifier] = client }
                let bundleIdentifier = self.getClientBundleIdentifier?(client) as String?
                let parentBundleIdentifier = self.getClientParentBundleIdentifier?(client) as String?
                group.enter()
                getNowPlayingInfoForClient(client, self.callbackQueue) { [weak self] dictionary in
                    defer { group.leave() }
                    guard let self,
                          let fields = self.fields(from: dictionary),
                          fields.hasContent else { return }
                    collector.append(PiPNowPlayingSnapshot(
                        isPlaying: fields.playbackRate > 0.001,
                        processIdentifier: processIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        parentBundleIdentifier: parentBundleIdentifier,
                        title: fields.title,
                        artist: fields.artist,
                        album: fields.album,
                        duration: fields.duration,
                        elapsedTime: fields.elapsedTime,
                        timestamp: fields.timestamp,
                        playbackRate: fields.playbackRate
                    ))
                }
            }
            self.clientLock.lock()
            self.clientsByProcessIdentifier = clientMap
            self.clientLock.unlock()
            group.notify(queue: self.callbackQueue) {
                completion(collector.values())
            }
        }
    }

    private func fetchGlobalSnapshot(completion: @escaping @Sendable ([PiPNowPlayingSnapshot]) -> Void) {
        guard let getNowPlayingInfo else {
            completion([])
            return
        }
        getNowPlayingInfo(callbackQueue) { [weak self] dictionary in
            guard let self,
                  let fields = self.fields(from: dictionary),
                  fields.hasContent else {
                completion([])
                return
            }
            guard let getNowPlayingPID = self.getNowPlayingPID else {
                completion([self.snapshot(from: fields, processIdentifier: 0)])
                return
            }
            getNowPlayingPID(self.callbackQueue) { [weak self] processIdentifier in
                guard let self else {
                    completion([])
                    return
                }
                completion([self.snapshot(from: fields, processIdentifier: pid_t(processIdentifier))])
            }
        }
    }

    private func snapshot(from fields: PiPMediaInfoFields, processIdentifier: pid_t) -> PiPNowPlayingSnapshot {
        let runningApplication = processIdentifier > 0 ? NSRunningApplication(processIdentifier: processIdentifier) : nil
        return PiPNowPlayingSnapshot(
            isPlaying: fields.playbackRate > 0.001,
            processIdentifier: processIdentifier,
            bundleIdentifier: runningApplication?.bundleIdentifier,
            parentBundleIdentifier: nil,
            title: fields.title,
            artist: fields.artist,
            album: fields.album,
            duration: fields.duration,
            elapsedTime: fields.elapsedTime,
            timestamp: fields.timestamp,
            playbackRate: fields.playbackRate
        )
    }

    private func fields(from dictionary: CFDictionary?) -> PiPMediaInfoFields? {
        guard let dictionary = dictionary as NSDictionary? else { return nil }
        let timestamp: Date?
        if let date = dictionary[timestampKey] as? Date {
            timestamp = date
        } else {
            timestamp = nil
        }
        return PiPMediaInfoFields(
            title: dictionary[titleKey] as? String,
            artist: dictionary[artistKey] as? String,
            album: dictionary[albumKey] as? String,
            duration: (dictionary[durationKey] as? NSNumber)?.doubleValue,
            elapsedTime: (dictionary[elapsedTimeKey] as? NSNumber)?.doubleValue,
            timestamp: timestamp,
            playbackRate: (dictionary[playbackRateKey] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private func send(command: Int32, to processIdentifier: pid_t, position: Double?) -> Bool {
        let options: NSDictionary? = position.map { [playbackPositionKey: $0] as NSDictionary }
        clientLock.lock()
        let client = clientsByProcessIdentifier[processIdentifier]
        clientLock.unlock()
        if let client, let sendCommandToClient {
            let localOrigin = getLocalOrigin?()
            _ = sendCommandToClient(command, localOrigin, options, client, 0, 0, nil)
            return true
        }
        if command == 24, let position, let setElapsedTime {
            setElapsedTime(position)
            return true
        }
        return sendCommand?(command, options as CFDictionary?) ?? false
    }

    private static func function<T>(_ handle: UnsafeMutableRawPointer?, named name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static func string(_ handle: UnsafeMutableRawPointer?, named name: String) -> String? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return symbol.assumingMemoryBound(to: CFString?.self).pointee as String?
    }
}

struct PiPMediaTransportControls: View {
    @ObservedObject var session: PiPSession
    @State private var seekPosition = 0.0
    @State private var isSeeking = false

    var body: some View {
        if let snapshot = session.mediaSnapshot {
            VStack(spacing: 7) {
                if let title = snapshot.title, !title.isEmpty {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        if let artist = snapshot.artist, !artist.isEmpty {
                            Text("· \(artist)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if session.presentationSettings.seekBar,
                   let duration = snapshot.duration,
                   duration > 0 {
                    Slider(value: $seekPosition, in: 0...duration) { editing in
                        isSeeking = editing
                        if !editing { session.seekMedia(to: seekPosition) }
                    }
                    .controlSize(.mini)
                    HStack {
                        Text(formatTime(seekPosition))
                        Spacer()
                        Text(formatTime(duration))
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                }

                HStack(spacing: 15) {
                    if session.presentationSettings.seekBar {
                        Button { session.seekMedia(by: -5) } label: {
                            Image(systemName: "gobackward.5")
                        }
                        .help(AppText.value("pipBack5Seconds", language: .system))
                    }
                    Button { session.toggleMediaPlayback() } label: {
                        Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 16)
                    }
                    .help(AppText.value(snapshot.isPlaying ? "pipPause" : "pipPlay", language: .system))
                    if session.presentationSettings.seekBar {
                        Button { session.seekMedia(by: 5) } label: {
                            Image(systemName: "goforward.5")
                        }
                        .help(AppText.value("pipForward5Seconds", language: .system))
                    }
                    if session.presentationSettings.youtubeCaptions && session.isYouTubeSource {
                        Button { session.toggleYouTubeCaptions() } label: {
                            Image(systemName: "captions.bubble")
                        }
                        .help(AppText.value("pipToggleCaptions", language: .system))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.16))
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
            .onAppear { updateSeekPosition(from: snapshot) }
            .onChange(of: snapshot) { _, newValue in
                updateSeekPosition(from: newValue)
            }
        }
    }

    private func updateSeekPosition(from snapshot: PiPNowPlayingSnapshot) {
        guard !isSeeking, let elapsed = snapshot.liveElapsedTime() else { return }
        seekPosition = elapsed
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
