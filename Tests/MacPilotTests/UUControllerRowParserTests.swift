import Foundation
import Testing
@testable import MacPilot

struct UUControllerRowParserTests {
    @Test func controlledSummaryDistinguishesAHiddenControllerRowFromADisconnection() {
        #expect(UUControllerRowParser.announcedControllerCount(in: [
            "本机被控中", "当前有", "1", "台设备正在控制此电脑"
        ]) == 1)
        #expect(UUControllerRowParser.announcedControllerCount(in: [
            "本机被控中 00:00:10 当前有 2 台设备正在控制此电脑"
        ]) == 2)
        #expect(UUControllerRowParser.announcedControllerCount(in: ["当前有 1 台设备正在控制此电脑"]) == nil)
        #expect(UUControllerRowParser.announcedControllerCount(in: ["本机被控中"]) == nil)
    }

    @Test func uu442CombinedAccessibilityRowReportsTheController() {
        // Shape observed in UU 4.42.0 (625), not separate AX text fields.
        #expect(UUControllerRowParser.controller(in: [
            "iPhone 15 Pro 远程控制 连接时长 00:01:25"
        ]) == "iPhone 15 Pro")
    }

    @Test func separateLegacyFieldsAndEnglishCombinedRowsRemainSupported() {
        #expect(UUControllerRowParser.controller(in: [
            "iPad Pro", "远程控制", "连接时长 00:02:10"
        ]) == "iPad Pro")
        #expect(UUControllerRowParser.controller(in: [
            "My iPhone Remote Control Duration 00:02:10"
        ]) == "My iPhone")
        #expect(UUControllerRowParser.controller(in: [
            "My iPhone", "Remote control", "Duration 00:02:10"
        ]) == "My iPhone")
    }

    @Test func multilineRowsAndChangingDurationsKeepTheSameSession() {
        var gate = UUSessionGate()
        var firstSession: String?
        let now = Date(timeIntervalSince1970: 1_000)
        for (offset, row) in [
            "  iPhone 15 Pro\n远程控制\n连接时长 00:01:25  ",
            "iPhone 15 Pro 远程控制 连接时长 00:01:26"
        ].enumerated() {
            let name = UUControllerRowParser.controller(in: [row])
            #expect(name == "iPhone 15 Pro")
            gate.update(.init(status: .connected, controllers: [name ?? ""]),
                        now: now.addingTimeInterval(Double(offset)))
            if offset == 0 { firstSession = gate.sessionID; #expect(firstSession != nil) }
            else { #expect(gate.sessionID == firstSession) }
        }
        let session = gate.sessionID
        gate.update(.init(status: .connected, controllers: ["iPhone 15 Pro"]),
                    now: now.addingTimeInterval(2))
        #expect(gate.sessionID == session)
    }

    @Test func labelsOtherModesAndIncompleteRowsDoNotAuthorizeScreenChanges() {
        for row in [
            "远程控制", "iPhone 15 Pro 远程控制", "当前有 1 台设备正在控制此电脑",
            "iPhone 15 Pro 文件传输 连接时长 00:01:25",
            "iPhone 15 Pro 观看模式 连接时长 00:01:25",
            "iPhone 15 Pro 远程控制 连接时长 unavailable", ""
        ] {
            #expect(UUControllerRowParser.controller(in: [row]) == nil)
        }
    }
}
