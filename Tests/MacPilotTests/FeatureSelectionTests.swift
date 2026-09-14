import Foundation
import Testing
@testable import MacPilot

struct FeatureSelectionTests {
    @Test func homeListsEverySidebarFeature() {
        #expect(MainSection.featureSections.allSatisfy { $0.isFeature })
        #expect(!MainSection.featureSections.contains(.home))
        #expect(!MainSection.featureSections.contains(.settings))
        #expect(MainSection.featureSections.count == MainSection.allCases.count - 2)
    }

    @Test func featureSectionsRoundTripThroughCodable() throws {
        let data = try JSONEncoder().encode(MainSection.capture)
        let decoded = try JSONDecoder().decode(MainSection.self, from: data)

        #expect(decoded == .capture)
    }

    @Test func homeCopyStaysLocalized() {
        #expect(AppText.value("home", language: .simplifiedChinese) == "首页")
        #expect(AppText.value("home", language: .english) == "Home")
        #expect(AppText.value("homeFeatureHint", language: .simplifiedChinese).isEmpty == false)
        #expect(AppText.value("homeFeatureHint", language: .english).isEmpty == false)
    }
}
