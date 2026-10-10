import Foundation

public enum FinderSyncRegistrationError: Error, Equatable, LocalizedError {
    case journalTargetMismatch
    case restorationNotConfirmed

    public var errorDescription: String? {
        switch self {
        case .journalTargetMismatch:
            "FinderSync recovery marker targets a different application; recovery was refused."
        case .restorationNotConfirmed:
            "PlugInKit did not confirm FinderSync enabled for the target application."
        }
    }
}

public enum FinderSyncRegistration {
    public static let extensionBundleIdentifier = "com.misswell.macpilot.finder-sync"

    public static func withSuspendedElection(
        applicationURL: URL,
        journal: FinderSyncRecoveryJournal = .standard,
        execute: ([String]) throws -> Void,
        query: ([String]) throws -> String,
        restorationFailed: (Error) -> Void = { _ in },
        operation: () throws -> Void
    ) throws {
        try Task<Never, Never>.checkCancellation()
        try journal.withExclusiveLock { access in
            let initialQuery = try query(queryArguments())
            var elected = isElectedForUse(in: initialQuery)
            if let pendingIntent = try access.readIntent() {
                guard pendingIntent.matches(applicationURL: applicationURL) else {
                    throw FinderSyncRegistrationError.journalTargetMismatch
                }
                if isElectedForUse(in: initialQuery, for: applicationURL) {
                    try access.clearIntent()
                } else {
                    try refreshCurrentTargetAndRestore(
                        applicationURL: applicationURL,
                        electionWasEnabled: elected,
                        execute: execute,
                        query: query,
                        access: access
                    )
                    elected = true
                }
            }

            guard elected else {
                try operation()
                return
            }

            try Task<Never, Never>.checkCancellation()
            try access.writeIntent(for: applicationURL)
            do {
                try Task<Never, Never>.checkCancellation()
                try execute(["-e", "ignore", "-i", extensionBundleIdentifier])
            } catch {
                let suspensionError = error
                do {
                    try restoreElection(
                        applicationURL: applicationURL,
                        execute: execute,
                        query: query,
                        access: access
                    )
                } catch {
                    restorationFailed(error)
                }
                throw suspensionError
            }

            var operationError: Error?
            do {
                try operation()
            } catch {
                operationError = error
            }

            do {
                try restoreElection(
                    applicationURL: applicationURL,
                    execute: execute,
                    query: query,
                    access: access
                )
            } catch {
                restorationFailed(error)
                if let operationError { throw operationError }
                throw error
            }
            if let operationError { throw operationError }
        }
    }

    public static func queryArguments(includeAllVersions: Bool = false) -> [String] {
        var arguments = ["-m", "-v", "-p", "com.apple.FinderSync", "-i", extensionBundleIdentifier]
        if includeAllVersions { arguments += ["-A", "-D"] }
        return arguments
    }

    /// Recovers a previously journaled temporary disable. Without a valid,
    /// matching journal, a system-disabled extension remains disabled.
    public static func recoverIfEnabled(
        at applicationURL: URL,
        journal: FinderSyncRecoveryJournal = .standard,
        execute: ([String]) throws -> String
    ) throws -> Bool {
        try Task<Never, Never>.checkCancellation()
        return try journal.withExclusiveLock { access in
            let initialQuery = try execute(queryArguments())
            let elected = isElectedForUse(in: initialQuery)
            if let pendingIntent = try access.readIntent() {
                guard pendingIntent.matches(applicationURL: applicationURL) else {
                    throw FinderSyncRegistrationError.journalTargetMismatch
                }
                if isElectedForUse(in: initialQuery, for: applicationURL) {
                    try access.clearIntent()
                } else {
                    try refreshCurrentTargetAndRestore(
                        applicationURL: applicationURL,
                        electionWasEnabled: elected,
                        execute: { _ = try execute($0) },
                        query: execute,
                        access: access
                    )
                    return true
                }
            }

            guard elected else { return false }
            let inventory = try execute(queryArguments(includeAllVersions: true))
            try refreshRegistration(
                for: applicationURL,
                registeredExtensionPaths: registeredExtensionPaths(in: inventory),
                execute: execute,
                access: access
            )
            return true
        }
    }

    public static func registeredExtensionPaths(in plugInKitOutput: String) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        for rawLine in plugInKitOutput.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard exactBundleToken(in: line) else { continue }

            let path: String
            if let separator = line.lastIndex(of: "\t") {
                path = String(line[line.index(after: separator)...])
            } else if let slash = line.firstIndex(of: "/") {
                path = String(line[slash...])
            } else {
                continue
            }

            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPath.hasSuffix(".appex"), seen.insert(trimmedPath).inserted else { continue }
            paths.append(trimmedPath)
        }

        return paths
    }

    public static func isElectedForUse(in plugInKitOutput: String) -> Bool {
        plugInKitOutput.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("+") else { return false }
            return exactBundleToken(in: String(line))
        }
    }

    public static func extensionPath(in plugInKitLine: String) -> String? {
        if let separator = plugInKitLine.lastIndex(of: "\t") {
            let path = String(plugInKitLine[plugInKitLine.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.hasSuffix(".appex") ? path : nil
        }
        guard let slash = plugInKitLine.firstIndex(of: "/") else { return nil }
        let path = String(plugInKitLine[slash...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasSuffix(".appex") ? path : nil
    }

    public static func isElectedForUse(in plugInKitOutput: String, for applicationURL: URL) -> Bool {
        let expectedPath = applicationURL
            .standardizedFileURL
            .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
            .path
        return plugInKitOutput.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("+"), exactBundleToken(in: line) else { return false }
            return extensionPath(in: line) == expectedPath
        }
    }

    public static func registrationArguments(
        for applicationURL: URL,
        registeredExtensionPaths: [String] = [],
        restoreEnabledElection: Bool
    ) -> [[String]] {
        let extensionPath = applicationURL
            .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
            .path

        var pathsToRemove: [String] = []
        var seen = Set<String>()
        for path in registeredExtensionPaths {
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            pathsToRemove.append(path)
        }

        var arguments = pathsToRemove.map { ["-r", $0] }
        arguments.append(["-a", extensionPath])
        if restoreEnabledElection {
            arguments.append(["-e", "use", "-i", extensionBundleIdentifier])
        }
        return arguments
    }

    private static func exactBundleToken(in line: String) -> Bool {
        var tokens = line.split(whereSeparator: \.isWhitespace)
        if tokens.first?.hasPrefix("+") == true { tokens.removeFirst() }
        return tokens.contains { token in
            let field = String(token)
            return field == extensionBundleIdentifier
                || field.hasPrefix(extensionBundleIdentifier + "(")
        }
    }

    private static func refreshCurrentTargetAndRestore(
        applicationURL: URL,
        electionWasEnabled: Bool,
        execute: ([String]) throws -> Void,
        query: ([String]) throws -> String,
        access: FinderSyncRecoveryJournal.Access
    ) throws {
        let inventory = try query(queryArguments(includeAllVersions: true))
        if electionWasEnabled {
            do {
                try Task<Never, Never>.checkCancellation()
                try execute(["-e", "ignore", "-i", extensionBundleIdentifier])
            } catch {
                let suspensionError = error
                do {
                    try restoreElection(
                        applicationURL: applicationURL,
                        execute: execute,
                        query: query,
                        access: access
                    )
                } catch {
                    throw suspensionError
                }
                throw suspensionError
            }
        }

        var operationError: Error?
        do {
            for arguments in registrationArguments(
                for: applicationURL,
                registeredExtensionPaths: registeredExtensionPaths(in: inventory),
                restoreEnabledElection: false
            ) {
                try Task<Never, Never>.checkCancellation()
                try execute(arguments)
            }
        } catch {
            operationError = error
        }

        do {
            try restoreElection(
                applicationURL: applicationURL,
                execute: execute,
                query: query,
                access: access
            )
        } catch {
            if let operationError { throw operationError }
            throw error
        }
        if let operationError { throw operationError }
    }

    private static func restoreElection(
        applicationURL: URL,
        execute: ([String]) throws -> Void,
        query: ([String]) throws -> String,
        access: FinderSyncRecoveryJournal.Access
    ) throws {
        do {
            try execute(["-e", "use", "-i", extensionBundleIdentifier])
        } catch {
            let useError = error
            if try isElectedForUse(in: query(queryArguments()), for: applicationURL) {
                try access.clearIntent()
                return
            }
            throw useError
        }

        guard try isElectedForUse(in: query(queryArguments()), for: applicationURL) else {
            throw FinderSyncRegistrationError.restorationNotConfirmed
        }
        try access.clearIntent()
    }

    private static func refreshRegistration(
        for applicationURL: URL,
        registeredExtensionPaths: [String],
        execute: ([String]) throws -> String,
        access: FinderSyncRecoveryJournal.Access
    ) throws {
        try access.writeIntent(for: applicationURL)
        do {
            try Task<Never, Never>.checkCancellation()
            _ = try execute(["-e", "ignore", "-i", extensionBundleIdentifier])
        } catch {
            let suspensionError = error
            do {
                try restoreElection(
                    applicationURL: applicationURL,
                    execute: { _ = try execute($0) },
                    query: { _ in try execute(queryArguments()) },
                    access: access
                )
            } catch {
                throw suspensionError
            }
            throw suspensionError
        }

        var operationError: Error?
        do {
            for arguments in registrationArguments(
                for: applicationURL,
                registeredExtensionPaths: registeredExtensionPaths,
                restoreEnabledElection: false
            ) {
                try Task<Never, Never>.checkCancellation()
                _ = try execute(arguments)
            }
        } catch {
            operationError = error
        }

        do {
            try restoreElection(
                applicationURL: applicationURL,
                execute: { _ = try execute($0) },
                query: execute,
                access: access
            )
        } catch {
            if let operationError { throw operationError }
            throw error
        }
        if let operationError { throw operationError }
    }
}
