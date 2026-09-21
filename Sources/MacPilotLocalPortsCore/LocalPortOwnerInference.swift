// Portions adapted from LeftOpen:
// https://github.com/SonghaiFan/leftopen
//
// Copyright (c) 2026 Songhai Fan
// Licensed under the MIT License.
// See THIRD_PARTY_NOTICES.md.

import Foundation

public enum LocalPortNodePackageLocator {
    public struct Package: Sendable, Equatable {
        public let name: String
        public let directory: String

        public init(name: String, directory: String) {
            self.name = name
            self.directory = directory
        }
    }

    public static func locate(inArguments arguments: String) -> Package? {
        for token in arguments.split(whereSeparator: \.isWhitespace) {
            if let package = locate(inPath: String(token)) { return package }
        }
        return nil
    }

    public static func locate(inPath path: String, resolvingSymlinks: Bool = true) -> Package? {
        var searchRange = path.startIndex..<path.endIndex
        var best: Package?

        while let range = path.range(of: "/node_modules/", range: searchRange) {
            let segments = path[range.upperBound...]
                .split(separator: "/", omittingEmptySubsequences: false)
            if let first = segments.first, !first.isEmpty, !first.hasPrefix(".") {
                var name = String(first)
                if first.hasPrefix("@"), segments.count > 1, !segments[1].isEmpty {
                    name += "/" + segments[1]
                }
                best = Package(name: name, directory: String(path[..<range.upperBound]) + name)
            }
            searchRange = range.upperBound..<path.endIndex
        }

        if best == nil,
           resolvingSymlinks,
           path.contains("/node_modules/.bin/"),
           path.hasPrefix("/") {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if resolved != path {
                return locate(inPath: resolved, resolvingSymlinks: false)
            }
        }
        return best
    }
}

public enum LocalPortOwnerInference {
    public static func application(
        for process: LocalPortProcess,
        parents: [LocalPortProcess]
    ) -> LocalPortApplication? {
        if let path = process.executablePath,
           let bundle = bundlePath(in: path) {
            return LocalPortApplication(
                name: bundle.name,
                path: bundle.path,
                sourcePID: process.pid,
                direct: true
            )
        }

        for parent in parents {
            if let path = parent.executablePath,
               let bundle = bundlePath(in: path) {
                return LocalPortApplication(
                    name: bundle.name,
                    path: bundle.path,
                    sourcePID: parent.pid,
                    direct: false
                )
            }
        }
        return nil
    }

    public static func infer(
        process: LocalPortProcess,
        project: LocalPortProject?,
        application: LocalPortApplication?
    ) -> LocalPortOwner {
        if let project {
            return LocalPortOwner(
                label: project.name,
                category: .project,
                confidence: .high,
                reason: .project(marker: project.marker, markerPath: project.markerPath)
            )
        }

        if let application {
            let reason: LocalPortOwnerReason = application.direct
                ? .directApplication(path: application.path)
                : .parentApplication(pid: application.sourcePID, path: application.path)
            return LocalPortOwner(
                label: application.name,
                category: .application,
                confidence: application.direct ? .high : .medium,
                reason: reason
            )
        }

        if let path = process.executablePath, isSystemExecutable(path) {
            // System executables remain in the system-service tier, while a
            // more specific `python -m` or Node package signal still gives
            // the user the useful service name required by the UI contract.
            if let interpreter = interpreterOwner(for: process) {
                return LocalPortOwner(
                    label: interpreter.label,
                    category: .systemService,
                    confidence: interpreter.confidence,
                    reason: interpreter.reason
                )
            }
            return LocalPortOwner(
                label: URL(fileURLWithPath: path).lastPathComponent,
                category: .systemService,
                confidence: .high,
                reason: .systemExecutable(path: path)
            )
        }

        if let interpreter = interpreterOwner(for: process) { return interpreter }

        if let service = standaloneService(for: process) { return service }

        if let path = process.executablePath, isUserInstalledExecutable(path) {
            let binary = URL(fileURLWithPath: path).lastPathComponent
            return LocalPortOwner(
                label: displayName(for: binary),
                category: .service,
                confidence: .medium,
                reason: .userInstalledExecutable(path: path)
            )
        }

        return LocalPortOwner(
            label: "Unknown",
            category: .unknown,
            confidence: .none,
            reason: .unknown
        )
    }

    public static func isSystemExecutable(_ path: String) -> Bool {
        ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/"]
            .contains { path.hasPrefix($0) }
    }

    public static func extractPythonModule(from arguments: String) -> String? {
        let pieces = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let index = pieces.firstIndex(of: "-m"), index + 1 < pieces.count else { return nil }
        return pieces[index + 1]
    }

    public static func displayName(for rawName: String) -> String {
        let lowercased = rawName.lowercased()
        let known: [String: String] = [
            "openclaw": "OpenClaw",
            "syncthing": "Syncthing",
            "ollama": "Ollama",
            "redis-server": "Redis",
            "redis": "Redis",
            "valkey-server": "Valkey",
            "postgres": "PostgreSQL",
            "pg_ctl": "PostgreSQL",
            "mysqld": "MySQL",
            "mariadbd": "MariaDB",
            "mongod": "MongoDB",
            "nginx": "Nginx",
            "caddy": "Caddy",
            "traefik": "Traefik",
            "docker": "Docker",
            "dockerd": "Docker",
            "docker-proxy": "Docker",
            "uvicorn": "Uvicorn",
            "gunicorn": "Gunicorn",
            "fastapi": "FastAPI",
            "http.server": "HTTP Server",
            "vite": "Vite",
            "next": "Next.js",
            "webpack": "Webpack",
            "parcel": "Parcel",
            "bun": "Bun",
            "deno": "Deno",
        ]
        if let knownName = known[lowercased] { return knownName }
        if rawName.count <= 3 { return rawName.uppercased() }
        return rawName.prefix(1).uppercased() + rawName.dropFirst()
    }

    private static func interpreterOwner(for process: LocalPortProcess) -> LocalPortOwner? {
        let command = process.command.lowercased()
        let genericInterpreters = ["node", "bun", "deno", "ts-node", "ruby", "perl"]
        guard genericInterpreters.contains(command) || command.hasPrefix("python") else { return nil }

        if let arguments = process.arguments {
            if let package = LocalPortNodePackageLocator.locate(inArguments: arguments) {
                return LocalPortOwner(
                    label: displayName(for: package.name),
                    category: .service,
                    confidence: .high,
                    reason: .nodePackage(name: package.name, directory: package.directory)
                )
            }
            if command.contains("python"), let module = extractPythonModule(from: arguments) {
                return LocalPortOwner(
                    label: displayName(for: module),
                    category: .service,
                    confidence: .high,
                    reason: .pythonModule(name: module)
                )
            }
        }

        // A daemon in its own dot-directory is often the tool's name. Avoid
        // reporting runtime managers and editor caches as the owner.
        if let cwd = process.cwd {
            let home = NSHomeDirectory()
            if cwd.hasPrefix(home + "/.") {
                let rest = cwd.dropFirst((home + "/.").count)
                let toolDirectory = String(rest.split(separator: "/").first ?? "")
                let ignored: Set<String> = [
                    "cache", "local", "config", "trash", "npm", "nvm", "bun", "pnpm", "yarn", "volta", "deno",
                    "cargo", "rustup", "pyenv", "venv", "virtualenvs", "gem", "rbenv", "asdf", "m2", "gradle",
                    "docker", "ssh", "vscode", "vscode-server", "cursor", "tmp",
                ]
                if !toolDirectory.isEmpty, !ignored.contains(toolDirectory.lowercased()) {
                    return LocalPortOwner(
                        label: displayName(for: toolDirectory),
                        category: .service,
                        confidence: .medium,
                        reason: .knownService(name: toolDirectory)
                    )
                }
            }
        }
        return nil
    }

    private static func standaloneService(for process: LocalPortProcess) -> LocalPortOwner? {
        let binary = (process.executablePath as NSString?)?.lastPathComponent.lowercased()
            ?? process.command.lowercased()
        let knownServices = Set([
            "syncthing", "ollama", "redis-server", "redis", "valkey-server", "postgres", "pg_ctl",
            "mysqld", "mariadbd", "mongod", "dockerd", "docker-proxy", "caddy", "nginx", "httpd",
            "traefik", "minio", "rabbitmq-server", "uvicorn", "gunicorn", "fastapi", "vite", "next",
            "webpack", "parcel", "bun", "deno",
        ])
        guard knownServices.contains(binary) else { return nil }
        return LocalPortOwner(
            label: displayName(for: binary),
            category: .service,
            confidence: .high,
            reason: .knownService(name: binary)
        )
    }

    private static func isUserInstalledExecutable(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let roots = [
            "/opt/homebrew/", "/usr/local/", "/opt/local/", "/nix/",
            home + "/.cargo/", home + "/go/", home + "/.local/", home + "/.nvm/",
            home + "/.volta/", home + "/.bun/", home + "/.deno/", home + "/.npm-global/",
            home + "/.pyenv/", home + "/.rbenv/", home + "/.asdf/",
        ]
        return roots.contains { path.hasPrefix($0) }
    }

    private static func bundlePath(in path: String) -> (name: String, path: String)? {
        guard path.hasPrefix("/") else { return nil }
        var components: [String] = []
        for component in path.split(separator: "/") {
            let value = String(component)
            components.append(value)
            if value.lowercased().hasSuffix(".app") {
                let name = String(value.dropLast(4))
                return name.isEmpty ? nil : (name, "/" + components.joined(separator: "/"))
            }
        }
        return nil
    }
}
