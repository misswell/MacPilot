import Testing
@testable import MacPilot

struct ClipboardLocalizationTests {
    @Test func retentionHintExplainsNonExpiringHistoryInBothLanguages() {
        #expect(
            AppText.value("clipboardRetentionHint", language: .simplifiedChinese)
                == "相同内容合并为一条记录，不按时间自动过期。内容总量超过 2 GiB 时，优先清理最旧的未固定记录。"
        )
        #expect(
            AppText.value("clipboardRetentionHint", language: .english)
                == "Identical content is merged into one record, with no automatic expiry. Above 2 GiB of content, the oldest unpinned records are removed first."
        )
    }
}
