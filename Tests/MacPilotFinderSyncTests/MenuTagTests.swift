import Testing
@testable import MacPilotFinderSync

struct MenuTagTests {
    @Test func tagsAreDeterministicAcrossInvocations() {
        #expect(MenuTag.forAction("copy-path") == MenuTag.forAction("copy-path"))
        #expect(MenuTag.forApp("com.apple.Terminal") == MenuTag.forApp("com.apple.Terminal"))
        #expect(MenuTag.forNewFile(".txt") == MenuTag.forNewFile(".txt"))
        #expect(MenuTag.forCommonDir("desktop") == MenuTag.forCommonDir("desktop"))
    }

    @Test func differentKindsNeverCollideForTheSameID() {
        // 同一 id 在四种前缀下必须得到不同 tag，避免跨分组串扰。
        let id = "sample"
        let tags: Set<Int> = [
            MenuTag.forAction(id),
            MenuTag.forApp(id),
            MenuTag.forNewFile(id),
            MenuTag.forCommonDir(id),
        ]
        #expect(tags.count == 4)
    }

    @Test func differentIDsProduceDifferentTags() {
        #expect(MenuTag.forAction("copy-path") != MenuTag.forAction("open-terminal"))
        #expect(MenuTag.forApp("com.apple.Terminal") != MenuTag.forApp("com.apple.Safari"))
    }
}
