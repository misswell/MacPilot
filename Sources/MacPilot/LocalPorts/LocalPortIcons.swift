// Portions adapted from LeftOpen:
// https://github.com/SonghaiFan/leftopen
//
// Copyright (c) 2026 Songhai Fan
// Licensed under the MIT License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation
import MacPilotLocalPortsCore
import SwiftUI

@MainActor
enum LocalPortIconResolver {
    static func applicationImage(for activity: LocalPortActivity, pointSize: CGFloat = 28) -> NSImage? {
        if let application = activity.application,
           let icon = NSWorkspace.shared.icon(forFile: application.path) as NSImage? {
            return thumbnail(icon, pointSize: pointSize)
        }
        return nil
    }

    static func fallbackSymbol(for activity: LocalPortActivity) -> String {
        switch activity.owner.category {
        case .application: return "macwindow"
        case .project: return "folder.fill"
        case .service:
            switch activity.owner.label.lowercased() {
            case "docker": return "shippingbox.fill"
            case "redis", "postgresql", "mysql", "mariadb", "mongodb", "valkey": return "cylinder"
            case "node", "bun", "deno", "vite", "next.js", "webpack": return "terminal"
            default: return "server.rack"
            }
        case .systemService: return "gearshape.2.fill"
        case .unknown: return "network"
        }
    }

    nonisolated static func localIconURLs(for activity: LocalPortActivity) -> [URL] {
        var candidates: [URL] = []
        if let project = activity.project {
            candidates.append(contentsOf: [
                URL(fileURLWithPath: project.root).appendingPathComponent("public/favicon.png"),
                URL(fileURLWithPath: project.root).appendingPathComponent("public/favicon.ico"),
                URL(fileURLWithPath: project.root).appendingPathComponent("public/apple-touch-icon.png"),
                URL(fileURLWithPath: project.root).appendingPathComponent("src-tauri/icons/icon.png"),
                URL(fileURLWithPath: project.root).appendingPathComponent("assets/icon.png"),
                URL(fileURLWithPath: project.root).appendingPathComponent("icon.png"),
                URL(fileURLWithPath: project.root).appendingPathComponent("icon.icns"),
            ])
            if let htmlIcon = indexHTMLIconURL(projectRoot: project.root) {
                candidates.insert(htmlIcon, at: 0)
            }
        }

        if case let .nodePackage(_, directory) = activity.owner.reason {
            candidates.append(contentsOf: [
                URL(fileURLWithPath: directory).appendingPathComponent("icon.png"),
                URL(fileURLWithPath: directory).appendingPathComponent("assets/icon.png"),
                URL(fileURLWithPath: directory).appendingPathComponent("logo.png"),
            ])
        }
        return candidates
    }

    nonisolated static func indexHTMLIconURL(projectRoot: String) -> URL? {
        let index = URL(fileURLWithPath: projectRoot).appendingPathComponent("index.html")
        guard let contents = try? String(contentsOf: index, encoding: .utf8) else { return nil }
        let patterns = [
            #"(?i)<link[^>]*rel\s*=\s*["'][^"']*icon[^"']*["'][^>]*href\s*=\s*["']([^"']+)["'][^>]*>"#,
            #"(?i)<link[^>]*href\s*=\s*["']([^"']+)["'][^>]*rel\s*=\s*["'][^"']*icon[^"']*["'][^>]*>"#,
        ]
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        var value: String?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: contents, range: range),
                  let matchRange = Range(match.range(at: 1), in: contents) else { continue }
            value = String(contents[matchRange])
            break
        }
        guard let value else { return nil }
        let templateMarkers = ["%PUBLIC_URL%", "{{", "}}", "${", "process.env."]
        guard !value.contains("<"),
              !value.hasPrefix("data:"),
              !templateMarkers.contains(where: value.contains) else { return nil }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: projectRoot)
                .appendingPathComponent(String(value.dropFirst()))
                .standardizedFileURL
        }
        guard let url = URL(string: value, relativeTo: index), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    nonisolated static func localIconData(for activity: LocalPortActivity) -> Data? {
        for url in localIconURLs(for: activity) {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private static func thumbnail(_ source: NSImage, pointSize: CGFloat) -> NSImage {
        let target = NSImage(size: NSSize(width: pointSize, height: pointSize))
        target.lockFocus()
        source.draw(
            in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        target.unlockFocus()
        return target
    }
}

/// Fetches only localhost favicons.  It deliberately never follows the
/// process owner's LAN address to the public internet.  A small actor cache
/// also caps concurrent requests at four.
actor LocalPortFaviconFetcher {
    static let shared = LocalPortFaviconFetcher()

    private var session: URLSession
    private var cache: [String: Data] = [:]
    private var activeRequests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        session = Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2.0
        return URLSession(
            configuration: configuration,
            delegate: LocalPortLoopbackTrustDelegate(),
            delegateQueue: nil
        )
    }

    func fetch(for activity: LocalPortActivity) async -> Data? {
        guard activity.scope == .local,
              let url = LocalPortURLResolver.url(
                port: activity.listener.port,
                addresses: activity.listener.addresses
              ),
              let host = url.host,
              LocalPortURLResolver.isLoopback(host) else { return nil }

        let key = "\(activity.process.pid):\(activity.process.startTime ?? activity.process.rawElapsedTime ?? "unknown"):\(activity.listener.port)"
        if let cached = cache[key] { return cached }
        await acquire()
        defer { release() }

        if let cached = cache[key] { return cached }
        var request = URLRequest(url: url.appendingPathComponent("favicon.ico"))
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode),
                  !data.isEmpty,
                  data.count <= 512_000 else { return nil }
            cache[key] = data
            return data
        } catch {
            return nil
        }
    }

    func clear() {
        session.invalidateAndCancel()
        session = Self.makeSession()
        cache.removeAll(keepingCapacity: false)
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    private func acquire() async {
        if activeRequests < 4 {
            activeRequests += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        activeRequests += 1
    }

    private func release() {
        activeRequests = max(0, activeRequests - 1)
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        }
    }
}

/// Self-signed certificates are accepted only for loopback favicon probes.
/// LAN addresses use the system's normal TLS validation because they are not
/// automatically trusted just because a process is listening on the Mac.
private final class LocalPortLoopbackTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let host = url.host,
              LocalPortURLResolver.isLoopback(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        guard protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              LocalPortURLResolver.isLoopback(protectionSpace.host),
              let trust = protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct LocalPortIconView: View {
    let activity: LocalPortActivity
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: LocalPortIconResolver.fallbackSymbol(for: activity))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: 30, height: 30)
        .task(id: activity.id) {
            if let local = LocalPortIconResolver.applicationImage(for: activity) {
                image = local
                return
            }
            let localData = await Task.detached(priority: .utility) {
                LocalPortIconResolver.localIconData(for: activity)
            }.value
            if let localData, let localImage = NSImage(data: localData) {
                image = LocalPortIconResolver.image(from: localImage)
                return
            }
            guard let data = await LocalPortFaviconFetcher.shared.fetch(for: activity),
                  let favicon = NSImage(data: data) else { return }
            image = LocalPortIconResolver.image(from: favicon)
        }
    }
}

private extension LocalPortIconResolver {
    static func image(from source: NSImage) -> NSImage {
        let targetSize: CGFloat = 28
        let target = NSImage(size: NSSize(width: targetSize, height: targetSize))
        target.lockFocus()
        source.draw(in: NSRect(x: 0, y: 0, width: targetSize, height: targetSize))
        target.unlockFocus()
        return target
    }
}
