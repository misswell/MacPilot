import Testing

@testable import MacPilot

/// The GATT test card is the only way to start the reversed-role harness on a
/// beta build, so a missing translation makes the feature unusable rather than
/// merely untranslated.
@Suite("Proximity GATT localization")
struct ProximityGATTLocalizationTests {
    private static let keys = [
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
        "proximityGATTTitle",
        "proximityGATTSubtitle",
        "proximityGATTStart",
        "proximityGATTStop",
        "proximityGATTStatusIdle",
        "proximityGATTStatusStarting",
        "proximityGATTStatusAdvertising",
        "proximityGATTStatusConnected",
        "proximityGATTStatusFailed",
        "proximityGATTLog",
        "proximityGATTLastEcho",
        "proximityGATTNoEvents",
        "bleReverseGATT",
        "bleReverseGATTInfo",
        "bleReverseGATTStatus",
        "bleReverseGATTSource",
        "bleReverseGATTStatusOff",
        "bleReverseGATTStatusWaiting",
        "bleReverseGATTStatusActive",
        "bleReverseGATTSourceNone",
        "bleReverseGATTSourceLegacy",
        "bleReverseGATTSourceReverse",
    ]

    @Test("both languages define every key")
    func bothLanguagesDefineEveryKey() {
        for key in Self.keys {
            let chinese = AppText.value(key, language: .simplifiedChinese)
            let english = AppText.value(key, language: .english)
            #expect(chinese != key)
            #expect(english != key)
            #expect(!chinese.isEmpty)
            #expect(!english.isEmpty)
        }
    }

    @Test("the harness says it is experimental in both languages")
    func experimentalLabel() {
        #expect(AppText.value("proximityGATTTitle", language: .simplifiedChinese).contains("实验"))
        #expect(AppText.value("proximityGATTTitle", language: .english).lowercased().contains("experimental"))
    }

    @Test("the failure status keeps the technical reason visible")
    func failureStatusKeepsReason() {
        #expect(AppText.value("proximityGATTStatusFailed", language: .simplifiedChinese, "Bluetooth is off")
            == "失败：Bluetooth is off")
        #expect(AppText.value("proximityGATTStatusFailed", language: .english, "Bluetooth is off")
            == "Failed: Bluetooth is off")
    }
}
