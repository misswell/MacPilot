import Testing
@testable import MacPilot

struct RemoteControlAppStoreInfoTests {
    @Test @MainActor func appStoreQRCodeTargetsThePilotNestListing() throws {
        #expect(PilotNestAppStoreInfo.appStoreURL.absoluteString == "https://apps.apple.com/app/pilotnest/id6811335132")

        let qrCode = try #require(PilotNestAppStoreInfo.qrCode)
        #expect(qrCode.size.width > 0)
        #expect(qrCode.size.width == qrCode.size.height)
    }

    @Test func searchKeywordsMatchTheAppStoreMetadataInBothLanguages() {
        #expect(
            AppText.value("remoteMobileAppSearchTerms", language: .simplifiedChinese)
                == "Mac、锁屏、解锁、黑屏、远程、遥控、唤醒、电脑、专注、助手"
        )
        #expect(
            AppText.value("remoteMobileAppSearchTerms", language: .english)
                == "Mac, lock, unlock, remote, control, blank, wake, desktop, companion, focus"
        )
    }
}
