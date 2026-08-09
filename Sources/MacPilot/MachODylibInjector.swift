// MachODylibInjector.swift
// Adds an LC_LOAD_DYLIB command without shifting Mach-O contents.

import Foundation

enum MachODylibInjector {
    static let loadCommandPath = "@loader_path/libMacPilotOcclusionPatch.dylib"

    static func containsLoadCommand(in data: Data, path: String = loadCommandPath) throws -> Bool {
        try slices(in: data).allSatisfy { try sliceContainsLoadCommand(data, slice: $0, path: path) }
    }

    static func injectingLoadCommand(into original: Data, path: String = loadCommandPath) throws -> Data {
        var result = original
        for slice in try slices(in: original) {
            try injectLoadCommand(into: &result, slice: slice, path: path)
        }
        return result
    }

    private struct Slice {
        let offset: Int
        let size: Int
    }

    private static func slices(in data: Data) throws -> [Slice] {
        guard data.count >= 4 else { throw MachOInjectionError.invalidFile }
        let magic = try readUInt32BE(data, at: 0)
        switch magic {
        case 0xcafebabe:
            let count = Int(try readUInt32BE(data, at: 4))
            guard count > 0, count <= 64 else { throw MachOInjectionError.invalidFile }
            return try (0..<count).map { index in
                let entry = 8 + index * 20
                let offset = Int(try readUInt32BE(data, at: entry + 8))
                let size = Int(try readUInt32BE(data, at: entry + 12))
                try validateSlice(offset: offset, size: size, in: data)
                return Slice(offset: offset, size: size)
            }
        case 0xcafebabf:
            let count = Int(try readUInt32BE(data, at: 4))
            guard count > 0, count <= 64 else { throw MachOInjectionError.invalidFile }
            return try (0..<count).map { index in
                let entry = 8 + index * 32
                let offset = Int(try readUInt64BE(data, at: entry + 8))
                let size = Int(try readUInt64BE(data, at: entry + 16))
                try validateSlice(offset: offset, size: size, in: data)
                return Slice(offset: offset, size: size)
            }
        default:
            try validateSlice(offset: 0, size: data.count, in: data)
            return [Slice(offset: 0, size: data.count)]
        }
    }

    private static func validateSlice(offset: Int, size: Int, in data: Data) throws {
        guard offset >= 0, size >= 32, offset <= data.count, size <= data.count - offset else {
            throw MachOInjectionError.invalidFile
        }
    }

    private static func sliceContainsLoadCommand(_ data: Data, slice: Slice, path: String) throws -> Bool {
        let header = try headerInfo(data, slice: slice)
        var cursor = slice.offset + header.headerSize
        for _ in 0..<header.commandCount {
            let command = try readUInt32LE(data, at: cursor)
            let commandSize = Int(try readUInt32LE(data, at: cursor + 4))
            try validateCommand(cursor: cursor, size: commandSize, header: header, slice: slice)
            if isDylibLoadCommand(command) {
                let nameOffset = Int(try readUInt32LE(data, at: cursor + 8))
                if nameOffset >= 24, nameOffset < commandSize,
                   readCString(data, at: cursor + nameOffset, limit: cursor + commandSize) == path {
                    return true
                }
            }
            cursor += commandSize
        }
        return false
    }

    private static func injectLoadCommand(into data: inout Data, slice: Slice, path: String) throws {
        if try sliceContainsLoadCommand(data, slice: slice, path: path) { return }
        let header = try headerInfo(data, slice: slice)
        let command = makeDylibCommand(path: path)
        let insertionOffset = slice.offset + header.headerSize + header.commandsSize
        let contentOffset = try firstContentOffset(data, slice: slice, header: header)
        guard insertionOffset + command.count <= contentOffset else {
            throw MachOInjectionError.insufficientHeaderPadding
        }
        guard data[insertionOffset..<(insertionOffset + command.count)].allSatisfy({ $0 == 0 }) else {
            throw MachOInjectionError.insufficientHeaderPadding
        }
        data.replaceSubrange(insertionOffset..<(insertionOffset + command.count), with: command)
        writeUInt32LE(UInt32(header.commandCount + 1), to: &data, at: slice.offset + 16)
        writeUInt32LE(UInt32(header.commandsSize + command.count), to: &data, at: slice.offset + 20)
    }

    private struct HeaderInfo {
        let headerSize: Int
        let commandCount: Int
        let commandsSize: Int
    }

    private static func headerInfo(_ data: Data, slice: Slice) throws -> HeaderInfo {
        let magic = try readUInt32LE(data, at: slice.offset)
        let headerSize: Int
        switch magic {
        case 0xfeedfacf: headerSize = 32
        case 0xfeedface: headerSize = 28
        default: throw MachOInjectionError.unsupportedMachO
        }
        let commandCount = Int(try readUInt32LE(data, at: slice.offset + 16))
        let commandsSize = Int(try readUInt32LE(data, at: slice.offset + 20))
        guard commandCount >= 0, commandCount <= 4_096,
              commandsSize >= 0,
              headerSize + commandsSize <= slice.size else {
            throw MachOInjectionError.invalidFile
        }
        return HeaderInfo(headerSize: headerSize, commandCount: commandCount, commandsSize: commandsSize)
    }

    private static func firstContentOffset(_ data: Data, slice: Slice, header: HeaderInfo) throws -> Int {
        var firstOffset = slice.offset + slice.size
        var cursor = slice.offset + header.headerSize
        for _ in 0..<header.commandCount {
            let command = try readUInt32LE(data, at: cursor)
            let commandSize = Int(try readUInt32LE(data, at: cursor + 4))
            try validateCommand(cursor: cursor, size: commandSize, header: header, slice: slice)
            if command == 0x19, commandSize >= 72 {
                let fileOffset = Int(try readUInt64LE(data, at: cursor + 40))
                if fileOffset > 0 { firstOffset = min(firstOffset, slice.offset + fileOffset) }
                let sectionCount = Int(try readUInt32LE(data, at: cursor + 64))
                guard sectionCount >= 0, 72 + sectionCount * 80 <= commandSize else {
                    throw MachOInjectionError.invalidFile
                }
                for section in 0..<sectionCount {
                    let offset = Int(try readUInt32LE(data, at: cursor + 72 + section * 80 + 48))
                    if offset > 0 { firstOffset = min(firstOffset, slice.offset + offset) }
                }
            } else if command == 0x1, commandSize >= 56 {
                let fileOffset = Int(try readUInt32LE(data, at: cursor + 32))
                if fileOffset > 0 { firstOffset = min(firstOffset, slice.offset + fileOffset) }
            }
            cursor += commandSize
        }
        return firstOffset
    }

    private static func validateCommand(cursor: Int, size: Int, header: HeaderInfo, slice: Slice) throws {
        let commandsEnd = slice.offset + header.headerSize + header.commandsSize
        guard size >= 8, size % 4 == 0, cursor >= slice.offset,
              cursor <= commandsEnd, size <= commandsEnd - cursor else {
            throw MachOInjectionError.invalidFile
        }
    }

    private static func isDylibLoadCommand(_ command: UInt32) -> Bool {
        switch command & 0x7fff_ffff {
        case 0xc, 0x18, 0x1f, 0x20, 0x23: true
        default: false
        }
    }

    private static func makeDylibCommand(path: String) -> Data {
        let pathBytes = Array(path.utf8) + [0]
        let commandSize = ((24 + pathBytes.count + 7) / 8) * 8
        var data = Data(repeating: 0, count: commandSize)
        writeUInt32LE(0xc, to: &data, at: 0)
        writeUInt32LE(UInt32(commandSize), to: &data, at: 4)
        writeUInt32LE(24, to: &data, at: 8)
        writeUInt32LE(2, to: &data, at: 16)
        data.replaceSubrange(24..<(24 + pathBytes.count), with: pathBytes)
        return data
    }

    private static func readCString(_ data: Data, at offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < limit, limit <= data.count else { return nil }
        let end = data[offset..<limit].firstIndex(of: 0) ?? limit
        return String(data: data[offset..<end], encoding: .utf8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw MachOInjectionError.invalidFile }
        return (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw MachOInjectionError.invalidFile }
        return (0..<4).reduce(0) { ($0 << 8) | UInt32(data[offset + $1]) }
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else { throw MachOInjectionError.invalidFile }
        return (0..<8).reduce(0) { $0 | UInt64(data[offset + $1]) << UInt64($1 * 8) }
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else { throw MachOInjectionError.invalidFile }
        return (0..<8).reduce(0) { ($0 << 8) | UInt64(data[offset + $1]) }
    }

    private static func writeUInt32LE(_ value: UInt32, to data: inout Data, at offset: Int) {
        for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt32(byte * 8)) }
    }
}

enum MachOInjectionError: LocalizedError {
    case invalidFile
    case unsupportedMachO
    case insufficientHeaderPadding

    var errorDescription: String? {
        switch self {
        case .invalidFile: "The application's executable is not a valid Mach-O file."
        case .unsupportedMachO: "The application's executable uses an unsupported Mach-O format."
        case .insufficientHeaderPadding: "The application's executable has no room for the patch load command."
        }
    }
}
