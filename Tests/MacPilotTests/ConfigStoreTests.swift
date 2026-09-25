import Foundation
import Testing
@testable import MacPilot

@Suite @MainActor
struct ConfigStoreTests {
    @Test func unchangedSnapshotSkipsWriteAndChangedSnapshotFlushes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        let original = Data("original".utf8)
        try original.write(to: url)

        let store = ConfigStore(url: url)
        store.markDirty(original)
        #expect(!store.isDirty)

        let updated = Data("updated".utf8)
        store.markDirty(updated)
        #expect(store.isDirty)
        store.finish()
        #expect(!store.isDirty)
        #expect(try Data(contentsOf: url) == updated)
    }
}
