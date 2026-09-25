import Foundation
import Testing
@testable import MacPilot

@Suite @MainActor
struct ConfigStoreTests {
    @Test func legacyConfigurationMigratesAndShortcutEditTouchesOnlyItsFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        let original: [String: Any] = [
            "version": 25,
            "language": "system",
            "enabledFeatures": ["clipboard"],
            "clipboard": ["isEnabled": true, "hotkey": ["keyCode": 1]],
            "windowSwitcher": ["isEnabled": false]
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        try originalData.write(to: url)

        let store = ConfigStore(url: url)
        #expect(store.load() == originalData)
        store.markDirty(originalData)
        #expect(store.isDirty)
        store.finish()
        #expect(!store.isDirty)
        for name in ["config.json", "features.json", "shortcuts.json", "window.json"] {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
        let restored = try #require(store.load())
        let restoredObject = try #require(JSONSerialization.jsonObject(with: restored) as? [String: Any])
        let clipboard = try #require(restoredObject["clipboard"] as? [String: Any])
        #expect((clipboard["hotkey"] as? [String: Int])?["keyCode"] == 1)

        let coreBefore = try Data(contentsOf: url)
        let featuresURL = directory.appendingPathComponent("features.json")
        let windowURL = directory.appendingPathComponent("window.json")
        let shortcutsURL = directory.appendingPathComponent("shortcuts.json")
        let featuresBefore = try Data(contentsOf: featuresURL)
        let windowBefore = try Data(contentsOf: windowURL)
        let shortcutsBefore = try Data(contentsOf: shortcutsURL)

        var updated = original
        updated["clipboard"] = ["isEnabled": true, "hotkey": ["keyCode": 2]]
        store.markDirty(try JSONSerialization.data(withJSONObject: updated))
        store.finish()
        #expect(try Data(contentsOf: url) == coreBefore)
        #expect(try Data(contentsOf: featuresURL) == featuresBefore)
        #expect(try Data(contentsOf: windowURL) == windowBefore)
        #expect(try Data(contentsOf: shortcutsURL) != shortcutsBefore)

        try FileManager.default.removeItem(at: windowURL)
        let recovered = ConfigStore(url: url)
        let recoveredData = try #require(recovered.load())
        let recoveredObject = try #require(JSONSerialization.jsonObject(with: recoveredData) as? [String: Any])
        let recoveredClipboard = try #require(recoveredObject["clipboard"] as? [String: Any])
        #expect((recoveredClipboard["hotkey"] as? [String: Int])?["keyCode"] == 1)
    }
}
