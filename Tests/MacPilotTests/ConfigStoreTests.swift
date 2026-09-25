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
        for name in ["config.json", "features.json", "shortcuts.json", "window.json", "clipboard.json"] {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
        let restored = try #require(store.load())
        let restoredObject = try #require(JSONSerialization.jsonObject(with: restored) as? [String: Any])
        let clipboard = try #require(restoredObject["clipboard"] as? [String: Any])
        #expect((clipboard["hotkey"] as? [String: Int])?["keyCode"] == 1)

        let coreBefore = try Data(contentsOf: url)
        let featuresURL = directory.appendingPathComponent("features.json")
        let clipboardURL = directory.appendingPathComponent("clipboard.json")
        let windowURL = directory.appendingPathComponent("window.json")
        let shortcutsURL = directory.appendingPathComponent("shortcuts.json")
        let featuresBefore = try Data(contentsOf: featuresURL)
        let clipboardBefore = try Data(contentsOf: clipboardURL)
        let windowBefore = try Data(contentsOf: windowURL)
        let shortcutsBefore = try Data(contentsOf: shortcutsURL)

        var updated = original
        updated["clipboard"] = ["isEnabled": true, "hotkey": ["keyCode": 2]]
        store.markDirty(try JSONSerialization.data(withJSONObject: updated))
        store.finish()
        #expect(try Data(contentsOf: url) == coreBefore)
        #expect(try Data(contentsOf: featuresURL) == featuresBefore)
        #expect(try Data(contentsOf: clipboardURL) == clipboardBefore)
        #expect(try Data(contentsOf: windowURL) == windowBefore)
        #expect(try Data(contentsOf: shortcutsURL) != shortcutsBefore)

        let shortcutsAfter = try Data(contentsOf: shortcutsURL)
        updated["clipboard"] = ["isEnabled": true, "hotkey": ["keyCode": 2], "storageLimit": 100]
        store.markDirty(try JSONSerialization.data(withJSONObject: updated))
        store.finish()
        #expect(try Data(contentsOf: clipboardURL) != clipboardBefore)
        #expect(try Data(contentsOf: featuresURL) == featuresBefore)
        #expect(try Data(contentsOf: windowURL) == windowBefore)
        #expect(try Data(contentsOf: shortcutsURL) == shortcutsAfter)

        try FileManager.default.removeItem(at: windowURL)
        let recovered = ConfigStore(url: url)
        let recoveredData = try #require(recovered.load())
        let recoveredObject = try #require(JSONSerialization.jsonObject(with: recoveredData) as? [String: Any])
        let recoveredClipboard = try #require(recoveredObject["clipboard"] as? [String: Any])
        #expect((recoveredClipboard["hotkey"] as? [String: Int])?["keyCode"] == 1)
    }

    @Test func versionOneSplitMigratesClipboardWithoutLosingLegacyReadability() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-store-v1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ name: String, _ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(name))
        }
        try write("config.json", ["splitConfigurationVersion": 1, "version": 25])
        try write("features.json", ["clipboard": ["isEnabled": true, "storageLimit": 50]])
        try write("shortcuts.json", ["clipboard": ["hotkey": ["keyCode": 3]]])
        try write("window.json", [:])

        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(url: url)
        let loaded = try #require(store.load())
        store.markDirty(loaded)
        store.finish()

        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(manifest["splitConfigurationVersion"] as? Int == 2)
        let clipboardFile = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("clipboard.json"))) as? [String: Any])
        #expect(clipboardFile["storageLimit"] as? Int == 50)
        let restored = try #require(ConfigStore(url: url).load())
        let restoredObject = try #require(JSONSerialization.jsonObject(with: restored) as? [String: Any])
        let clipboard = try #require(restoredObject["clipboard"] as? [String: Any])
        #expect(clipboard["storageLimit"] as? Int == 50)
        #expect((clipboard["hotkey"] as? [String: Int])?["keyCode"] == 3)
    }
}
