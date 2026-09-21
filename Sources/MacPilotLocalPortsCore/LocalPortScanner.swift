// Portions adapted from LeftOpen:
// https://github.com/SonghaiFan/leftopen
//
// Copyright (c) 2026 Songhai Fan
// Licensed under the MIT License.
// See THIRD_PARTY_NOTICES.md.

import Foundation

public enum LocalPortScanner {
    public static func parseListeners(_ output: String) -> [LocalPortListener] {
        var pid: Int32?
        var command = "unknown"
        var uid: Int32?
        var user: String?
        var byKey: [String: LocalPortListener] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let field = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch field {
            case "p":
                pid = Int32(value)
                command = "unknown"
                uid = nil
                user = nil
            case "c":
                command = value.isEmpty ? "unknown" : value
            case "u":
                uid = Int32(value)
            case "L":
                user = value.isEmpty ? nil : value
            case "n":
                guard let pid, let endpoint = parseEndpoint(value) else { continue }
                let key = "\(pid):\(endpoint.port)"
                if var existing = byKey[key] {
                    if !existing.addresses.contains(endpoint.address) {
                        existing.addresses.append(endpoint.address)
                        byKey[key] = existing
                    }
                } else {
                    byKey[key] = LocalPortListener(
                        pid: pid,
                        command: command,
                        uid: uid,
                        user: user,
                        port: endpoint.port,
                        addresses: [endpoint.address]
                    )
                }
            default:
                break
            }
        }

        return byKey.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    public static func listenerScope(_ addresses: [String]) -> LocalPortScope {
        let loopback = !addresses.isEmpty && addresses.allSatisfy { address in
            let clean = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            return clean == "127.0.0.1" || clean == "::1" || clean == "localhost"
        }
        return loopback ? .local : .lan
    }

    public static func scanListeners() throws -> [LocalPortListener] {
        let output = try LocalPortCommandRunner.output(
            "/usr/sbin/lsof",
            ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-FpcLun"],
            allowEmptyLsof: true
        )
        return parseListeners(output)
    }

    public static func scan() throws -> LocalPortSnapshot {
        let listeners = try scanListeners()
        guard !listeners.isEmpty else { return .empty }

        let pids = Array(Set(listeners.map(\.pid))).sorted()
        var limitations: [LocalPortScanLimitation] = []

        let cwdByPID: [Int32: String]
        do {
            cwdByPID = try descriptorFacts(pids, descriptor: "cwd")
        } catch {
            cwdByPID = [:]
            limitations.append(.cwdUnavailable)
        }

        let executableByPID: [Int32: String]
        do {
            executableByPID = try descriptorFacts(pids, descriptor: "txt")
        } catch {
            executableByPID = [:]
            limitations.append(.executableUnavailable)
        }

        let argumentResult = commandArguments(pids)
        if argumentResult.failed { limitations.append(.argumentsUnavailable) }

        let processTable: [Int32: LocalPortProcess]
        do {
            let output = try LocalPortCommandRunner.output("/bin/ps", ["-axo", "pid=,ppid=,etime=,comm="])
            processTable = parseProcessTable(output)
        } catch {
            processTable = [:]
            limitations.append(.processTableUnavailable)
        }

        var projects: [String: LocalPortProject] = [:]
        for cwd in Set(cwdByPID.values) {
            if let project = LocalPortProjectLocator.locate(cwd: cwd) {
                projects[cwd] = project
            }
        }

        let activities = listeners.map { listener -> LocalPortActivity in
            let tableProcess = processTable[listener.pid]
            let process = LocalPortProcess(
                pid: listener.pid,
                ppid: tableProcess?.ppid,
                command: listener.command,
                executablePath: executableByPID[listener.pid] ?? tableProcess?.executablePath,
                uid: listener.uid,
                user: listener.user,
                cwd: cwdByPID[listener.pid],
                uptime: tableProcess?.uptime,
                rawElapsedTime: tableProcess?.rawElapsedTime,
                arguments: argumentResult.values[listener.pid]
            )
            let parents = parentChain(for: process, in: processTable)
            let project = process.cwd.flatMap { projects[$0] }
            let application = LocalPortOwnerInference.application(for: process, parents: parents)
            let owner = LocalPortOwnerInference.infer(
                process: process,
                project: project,
                application: application
            )
            return LocalPortActivity(
                listener: listener,
                process: process,
                parentChain: parents,
                project: project,
                application: application,
                scope: listenerScope(listener.addresses),
                owner: owner
            )
        }

        return LocalPortSnapshot(activities: activities, limitations: limitations)
    }

    /// Parses the `ps -axo pid=,ppid=,etime=,comm=` table.  The elapsed-time
    /// column can be absent on older macOS output, so both forms are accepted.
    public static func parseProcessTable(_ output: String) -> [Int32: LocalPortProcess] {
        var table: [Int32: LocalPortProcess] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let pieces = line.split(whereSeparator: \.isWhitespace)
            guard pieces.count >= 3,
                  let pid = Int32(pieces[0]),
                  let ppid = Int32(pieces[1]) else { continue }

            let elapsed: String?
            let rawCommand: String
            if pieces.count >= 4, pieces[2].contains(":") || pieces[2].contains("-") {
                elapsed = String(pieces[2])
                rawCommand = pieces.dropFirst(3).joined(separator: " ")
            } else {
                elapsed = nil
                rawCommand = pieces.dropFirst(2).joined(separator: " ")
            }

            let executable = rawCommand.hasPrefix("/") ? rawCommand : nil
            let command = executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? rawCommand
            table[pid] = LocalPortProcess(
                pid: pid,
                ppid: ppid,
                command: command,
                executablePath: executable,
                uid: nil,
                user: nil,
                cwd: nil,
                uptime: elapsed.flatMap { LocalPortUptimeFormatter.format(etime: $0) },
                rawElapsedTime: elapsed
            )
        }
        return table
    }

    private static func parseEndpoint(_ endpoint: String) -> (address: String, port: Int)? {
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        let portString = endpoint[endpoint.index(after: colon)...]
        guard let port = Int(portString), (1...65535).contains(port) else { return nil }
        return (String(endpoint[..<colon]), port)
    }

    private static func parentChain(
        for process: LocalPortProcess,
        in table: [Int32: LocalPortProcess]
    ) -> [LocalPortProcess] {
        var result: [LocalPortProcess] = []
        var seen: Set<Int32> = [process.pid]
        var parentPID = process.ppid
        while let pid = parentPID, pid > 0, !seen.contains(pid), result.count < 16 {
            seen.insert(pid)
            guard let parent = table[pid] else { break }
            result.append(parent)
            parentPID = parent.ppid
        }
        return result
    }

    private static func commandArguments(_ pids: [Int32]) -> (values: [Int32: String], failed: Bool) {
        guard !pids.isEmpty else { return ([:], false) }
        var values: [Int32: String] = [:]
        var failed = false

        for start in stride(from: 0, to: pids.count, by: 100) {
            let end = min(start + 100, pids.count)
            let chunk = pids[start..<end]
            do {
                let output = try LocalPortCommandRunner.output(
                    "/bin/ps",
                    ["-ww", "-p", chunk.map(String.init).joined(separator: ","), "-o", "pid=,command="]
                )
                for line in output.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let firstSpace = trimmed.firstIndex(where: \.isWhitespace),
                          let pid = Int32(trimmed[..<firstSpace]) else { continue }
                    values[pid] = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
                }
            } catch {
                failed = true
            }
        }
        return (values, failed)
    }

    private static func descriptorFacts(
        _ pids: [Int32],
        descriptor: String
    ) throws -> [Int32: String] {
        var values: [Int32: String] = [:]
        for start in stride(from: 0, to: pids.count, by: 100) {
            let end = min(start + 100, pids.count)
            let chunk = pids[start..<end]
            let output = try LocalPortCommandRunner.output(
                "/usr/sbin/lsof",
                ["-a", "-p", chunk.map(String.init).joined(separator: ","), "-d", descriptor, "-Fpn"],
                allowEmptyLsof: true
            )
            var currentPID: Int32?
            for rawLine in output.split(whereSeparator: \.isNewline) {
                guard let field = rawLine.first else { continue }
                let value = String(rawLine.dropFirst())
                if field == "p" { currentPID = Int32(value) }
                if field == "n", let currentPID, values[currentPID] == nil {
                    values[currentPID] = value
                }
            }
        }
        return values
    }
}
