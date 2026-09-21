// Portions adapted from LeftOpen:
// https://github.com/SonghaiFan/leftopen
//
// Copyright (c) 2026 Songhai Fan
// Licensed under the MIT License.
// See THIRD_PARTY_NOTICES.md.

import Foundation

public enum LocalPortProjectLocator {
    private static let markers = [
        "package.json",
        "pyproject.toml",
        "Cargo.toml",
        "go.mod",
        ".git",
    ]

    /// Finds the nearest accepted project root above a process working
    /// directory.  System locations, app bundles, dependency trees and the
    /// user's Library are deliberately excluded from project inference.
    public static func locate(
        cwd: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> LocalPortProject? {
        guard cwd.hasPrefix("/"), cwd != "/" else { return nil }
        let standardizedCWD = URL(fileURLWithPath: cwd).standardizedFileURL.path
        // A process launched from a dependency tree or an app bundle can sit
        // below a real project root.  Treat the process location itself as
        // excluded so we do not accidentally walk back up and claim that
        // unrelated parent project.
        let cwdSegments = standardizedCWD.split(separator: "/").map { $0.lowercased() }
        if cwdSegments.contains(where: {
            $0.hasSuffix(".app") || ["node_modules", "cache", "caches", ".cache"].contains($0)
        }) {
            return nil
        }
        var directory = standardizedCWD

        while directory != "/" {
            if !isRejected(root: directory, cwd: standardizedCWD, homeDirectory: homeDirectory) {
                for marker in markers {
                    let markerURL = URL(fileURLWithPath: directory).appendingPathComponent(marker)
                    if FileManager.default.fileExists(atPath: markerURL.path) {
                        return LocalPortProject(
                            name: name(for: directory, marker: marker),
                            root: directory,
                            marker: marker,
                            markerPath: markerURL.path
                        )
                    }
                }
            }

            let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
            guard parent != directory else { break }
            directory = parent
        }
        return nil
    }

    public static func isRejectedProjectPath(
        _ root: String,
        cwd: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool {
        isRejected(root: root, cwd: cwd, homeDirectory: homeDirectory)
    }

    private static func isRejected(root: String, cwd: String, homeDirectory: String) -> Bool {
        let lowerSegments = root.split(separator: "/").map { $0.lowercased() }
        if lowerSegments.contains(where: {
            $0.hasSuffix(".app") || ["node_modules", "cache", "caches", ".cache"].contains($0)
        }) {
            return true
        }

        let managedRoots = [
            "/Applications", "/System", "/Library", "/usr", "/bin", "/sbin", "/opt", "/private/var",
        ]
        if managedRoots.contains(where: { isWithin(root, $0) }) { return true }
        if isWithin(root, homeDirectory + "/Library") || root == homeDirectory { return true }
        if isWithin(root, homeDirectory),
           let first = root.dropFirst(homeDirectory.count).split(separator: "/").first,
           first.hasPrefix(".") {
            return true
        }
        return !isWithin(cwd, root)
    }

    private static func isWithin(_ candidate: String, _ parent: String) -> Bool {
        candidate == parent || candidate.hasPrefix(parent + "/")
    }

    private static func name(for directory: String, marker: String) -> String {
        let markerURL = URL(fileURLWithPath: directory).appendingPathComponent(marker)
        if marker == "package.json",
           let data = try? Data(contentsOf: markerURL),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any],
           let packageName = dictionary["name"] as? String,
           !packageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if marker == "pyproject.toml",
           let data = try? Data(contentsOf: markerURL),
           let contents = String(data: data, encoding: .utf8),
           let projectName = pyprojectName(in: contents) {
            return projectName
        }

        return URL(fileURLWithPath: directory).lastPathComponent
    }

    private static func pyprojectName(in contents: String) -> String? {
        var inProjectSection = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inProjectSection = line == "[project]"
                continue
            }
            guard inProjectSection,
                  line.hasPrefix("name"),
                  let equal = line.firstIndex(of: "=") else { continue }
            let candidate = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            guard candidate.count >= 2,
                  (candidate.first == "\"" && candidate.last == "\""
                   || candidate.first == "'" && candidate.last == "'") else { continue }
            return String(candidate.dropFirst().dropLast())
        }
        return nil
    }
}
