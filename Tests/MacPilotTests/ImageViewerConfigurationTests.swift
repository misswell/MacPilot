import Foundation
import Testing
@testable import MacPilot

@MainActor
struct ImageViewerConfigurationTests {
    @Test func legacyMissingFeatureListDoesNotOptInToImageViewer() throws {
        let decoded = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: Data("{}".utf8))
        #expect(!decoded.enabledFeatures.contains(MainSection.imageViewer.rawValue))
        #expect(!decoded.enabledFeatures.contains(MainSection.displayControl.rawValue))
        #expect(decoded.enabledFeatures.contains(MainSection.capture.rawValue))
        #expect(MainSection.utilitySections.contains(.imageViewer))
    }

    @Test func onlyTheExistingFeatureListStoresTheExplicitOptIn() throws {
        let data = Data(#"{"enabledFeatures":["imageViewer","capture","settingsFromTheFuture"]}"#.utf8)
        let configured = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: data)
        let encoded = try JSONEncoder().encode(configured)
        let dictionary = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(dictionary["imageViewer"] == nil)
        #expect(dictionary["enabledFeatures"] as? [String] == ["imageViewer", "capture", "settingsFromTheFuture"])
    }
}
