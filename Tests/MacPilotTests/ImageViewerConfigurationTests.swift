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
        let section = try #require(dictionary["imageViewer"] as? [String: Any])
        #expect(section["scrollBehavior"] as? String == ImageViewerScrollBehavior.optionScrollNavigates.rawValue)
        #expect(dictionary["enabledFeatures"] as? [String] == ["imageViewer", "capture", "settingsFromTheFuture"])
    }

    @Test func imageViewerSettingsFallBackPerKeyAndRoundTrip() throws {
        let missing = try JSONDecoder().decode(ImageViewerSettings.self, from: Data("{}".utf8))
        #expect(missing == ImageViewerSettings())
        #expect(missing.scrollBehavior == .optionScrollNavigates)

        let unknown = try JSONDecoder().decode(
            ImageViewerSettings.self,
            from: Data(#"{"scrollBehavior":"scrollFromTheFuture"}"#.utf8)
        )
        #expect(unknown.scrollBehavior == .optionScrollNavigates)

        let selected = ImageViewerSettings(scrollBehavior: .scrollNavigates)
        let encoded = try JSONEncoder().encode(selected)
        #expect(try JSONDecoder().decode(ImageViewerSettings.self, from: encoded) == selected)
    }

    @Test func storedConfigurationDecodesTheViewerSectionAndIsolatesABrokenOne() throws {
        let configured = try JSONDecoder().decode(
            MacPilotModel.StoredConfiguration.self,
            from: Data(#"{"imageViewer":{"scrollBehavior":"scrollNavigates"}}"#.utf8)
        )
        #expect(configured.imageViewer.scrollBehavior == .scrollNavigates)
        #expect(configured.unreadableSections.isEmpty)

        let broken = try JSONDecoder().decode(
            MacPilotModel.StoredConfiguration.self,
            from: Data(#"{"imageViewer":"not-an-object","rules":[]}"#.utf8)
        )
        #expect(broken.imageViewer == ImageViewerSettings())
        #expect(broken.unreadableSections == ["imageViewer"])
    }

    @Test func imageViewerSettingsLandInFeaturesJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-viewer-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        let object: [String: Any] = [
            "version": 26,
            "enabledFeatures": ["imageViewer"],
            "imageViewer": ["scrollBehavior": "scrollNavigates"]
        ]
        let store = ConfigStore(url: url)
        store.markDirty(try JSONSerialization.data(withJSONObject: object))
        store.finish()

        let features = try #require(
            JSONSerialization.jsonObject(
                with: try Data(contentsOf: directory.appendingPathComponent("features.json"))
            ) as? [String: Any]
        )
        #expect((features["imageViewer"] as? [String: Any])?["scrollBehavior"] as? String == "scrollNavigates")
        let core = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(core["imageViewer"] == nil)

        let merged = try #require(store.load())
        let restored = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: merged)
        #expect(restored.imageViewer.scrollBehavior == .scrollNavigates)
    }
}
