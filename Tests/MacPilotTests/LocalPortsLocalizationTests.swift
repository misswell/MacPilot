import Testing
@testable import MacPilot

struct LocalPortsLocalizationTests {
    @Test func localPortsIsAHomeControlledFeature() {
        #expect(MainSection.utilitySections.contains(.localPorts))
        #expect(MainSection.localPorts.titleKey == "localPorts")
        #expect(MainSection.localPorts.systemImage == "network")
        #expect(MainSection.localPorts.isFeature)
    }

    @Test func localPortsCopyExistsInBothLanguages() {
        #expect(AppText.value("localPorts", language: .simplifiedChinese) == "本地端口")
        #expect(AppText.value("localPorts", language: .english) == "Local Ports")
        #expect(!AppText.value("localPortsSubtitle", language: .simplifiedChinese).isEmpty)
        #expect(!AppText.value("localPortsSubtitle", language: .english).isEmpty)
        #expect(!AppText.value("localPortsCloseHint", language: .simplifiedChinese).isEmpty)
        #expect(!AppText.value("localPortsCloseHint", language: .english).isEmpty)
        #expect(AppText.value("localPortsPort", language: .english, "3000") == "Port 3000")
        #expect(AppText.value("localPortsPID", language: .simplifiedChinese, "42") == "PID 42")
    }
}
