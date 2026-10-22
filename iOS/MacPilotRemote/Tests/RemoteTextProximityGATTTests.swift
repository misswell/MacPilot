import Testing
@testable import PilotNest

/// The phase-one GATT harness is entirely driven by this screen, so a missing
/// string would hide the only way to run the test on a device.
struct RemoteTextProximityGATTTests {
    private let renderedKeys = [
        "proximityGATTAdvertising",
        "proximityGATTSubscribers",
        "proximityGATTYes",
        "proximityGATTNo",
        "proximityGATTLastReceived",
        "proximityGATTReceivedBytes",
        "proximityGATTSentBytes",
        "proximityGATTServiceUUID",
        "proximityGATTEchoUUID",
        "proximityGATTWriteUUID",
        "proximityGATTClearLog",
        "proximityGATTDiagnostics",
        "proximityGATTLink",
        "proximityGATTSubscription",
        "proximityGATTVerifiedCount",
        "proximityGATTLastSent",
        "proximityGATTLastVerified",
        "proximityGATTLastError",
        "proximityGATTSendAgain",
        "proximityGATTProtocol",
        "proximityGATTTitle", "proximityGATTSettingsHint", "proximityGATTSubtitle",
        "proximityGATTStart", "proximityGATTStop",
        "proximityGATTStatusIdle", "proximityGATTStatusStarting",
        "proximityGATTStatusScanning", "proximityGATTStatusConnecting",
        "proximityGATTStatusDiscovering", "proximityGATTStatusEchoing",
        "proximityGATTStatusVerified", "proximityGATTStatusFailed",
        "proximityGATTMacSection", "proximityGATTMacID", "proximityGATTMacUnset",
        "proximityGATTStages", "proximityGATTConnectStage",
        "proximityGATTDiscoverStage", "proximityGATTReadStage",
        "proximityGATTSubscribeStage", "proximityGATTEchoStage",
        "proximityGATTLog", "proximityGATTNoEvents", "proximityGATTShareLog"
    ]

    @Test func everyProximityStringIsWrittenInBothLocales() {
        for key in renderedKeys {
            let chinese = RemoteText.value(key, language: .simplifiedChinese)
            let english = RemoteText.value(key, language: .english)
            #expect(chinese != key, "\(key) is missing from every table")
            #expect(!english.isEmpty, "\(key) has no English wording")
            #expect(chinese != english, "\(key) has no Simplified Chinese wording")
        }
    }

    @Test func resultStringsKeepTheirMeasurementAndReason() {
        #expect(RemoteText.value("proximityGATTStatusVerified", language: .english, 12)
            == "Echo verified (12 ms)")
        #expect(RemoteText.value("proximityGATTStatusVerified", language: .simplifiedChinese, 12)
            == "回环成功（12 ms）")
        #expect(RemoteText.value("proximityGATTStatusFailed", language: .english, "Bluetooth is off")
            == "Failed: Bluetooth is off")
        #expect(RemoteText.value("proximityGATTStatusFailed", language: .simplifiedChinese, "Bluetooth is off")
            == "失败：Bluetooth is off")
    }
}
