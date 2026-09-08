import Foundation
import Testing
@testable import MacPilotRightClickKit

struct RightClickStoreMigrationTests {
    @Test func successfulMigrationClearsPendingState() throws {
        let suiteName = "MacPilotMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: destination) }

        let migrated = RightClickStoreMigration.prepare(
            destination: destination,
            sources: [URL(fileURLWithPath: "/legacy/store.sqlite")],
            defaults: defaults,
            migrate: { _, target in
                try Data("snapshot".utf8).write(to: target)
                return true
            }
        )

        #expect(migrated)
        #expect(!defaults.bool(forKey: RightClickStoreMigration.pendingKey))
        #expect(try String(contentsOf: destination) == "snapshot")
    }

    @Test func failedMigrationStaysPendingAndIsNotRetriedAutomatically() throws {
        let suiteName = "MacPilotMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: destination) }
        var attempts = 0
        let migrate: (URL, URL) throws -> Bool = { _, _ in
            attempts += 1
            throw CocoaError(.fileReadNoPermission)
        }

        #expect(!RightClickStoreMigration.prepare(destination: destination, sources: [URL(fileURLWithPath: "/legacy/store.sqlite")], defaults: defaults, migrate: migrate))
        #expect(defaults.bool(forKey: RightClickStoreMigration.pendingKey))
        #expect(!RightClickStoreMigration.prepare(destination: destination, sources: [URL(fileURLWithPath: "/legacy/store.sqlite")], defaults: defaults, migrate: migrate))
        #expect(attempts == 1)
    }
}
