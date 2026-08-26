import Foundation
import Testing
@testable import MacPilot

struct ScreenLockHistoryTests {
    @Test func lockAndUnlockEventsArePairedWithDurationAndSources() throws {
        var history = ScreenLockHistory()
        let lockedAt = Date(timeIntervalSince1970: 1_000)
        let unlockedAt = Date(timeIntervalSince1970: 1_012)

        let didRecordLock = history.recordLock(at: lockedAt, source: .automatic)
        let didRecordUnlock = history.recordUnlock(at: unlockedAt, source: .manual)
        #expect(didRecordLock)
        #expect(didRecordUnlock)

        let entry = try #require(history.entries.first)
        #expect(entry.lockedAt == lockedAt)
        #expect(entry.unlockedAt == unlockedAt)
        #expect(entry.lockSource == .automatic)
        #expect(entry.unlockSource == .manual)
        #expect(entry.unlockDuration == 12)
        #expect(!entry.isStillLocked)
    }

    @Test func duplicateLockAndUnlockNotificationsDoNotCreateDuplicateRecords() {
        var history = ScreenLockHistory()
        let lockedAt = Date(timeIntervalSince1970: 2_000)
        let unlockedAt = Date(timeIntervalSince1970: 2_010)

        let firstLock = history.recordLock(at: lockedAt, source: .manual)
        let duplicateLock = history.recordLock(at: lockedAt.addingTimeInterval(0.25), source: .manual)
        let firstUnlock = history.recordUnlock(at: unlockedAt, source: .automatic)
        let duplicateUnlock = history.recordUnlock(at: unlockedAt.addingTimeInterval(0.25), source: .automatic)
        #expect(firstLock)
        #expect(!duplicateLock)
        #expect(firstUnlock)
        #expect(!duplicateUnlock)
        let delayedDuplicateLock = history.recordLock(at: unlockedAt.addingTimeInterval(0.5), source: .manual)
        #expect(!delayedDuplicateLock)
        #expect(history.entries.count == 1)
    }

    @Test func anUnmatchedLockRemainsVisibleAsCurrentlyLocked() throws {
        var history = ScreenLockHistory()
        let lockedAt = Date(timeIntervalSince1970: 3_000)

        let didRecordLock = history.recordLock(at: lockedAt, source: .manual)
        let entry = try #require(history.entries.first)

        #expect(didRecordLock)
        #expect(entry.isStillLocked)
        #expect(entry.unlockedAt == nil)
        #expect(entry.unlockDuration == nil)
    }

    @Test func historyKeepsTheMostRecentThirtyCompletedRecords() throws {
        var history = ScreenLockHistory()

        for index in 0..<35 {
            let lockedAt = Date(timeIntervalSince1970: Double(index * 4))
            let didRecordLock = history.recordLock(at: lockedAt, source: .automatic)
            let didRecordUnlock = history.recordUnlock(at: lockedAt.addingTimeInterval(1), source: .automatic)
            #expect(didRecordLock)
            #expect(didRecordUnlock)
        }

        let newest = try #require(history.entries.first)
        let oldest = try #require(history.entries.last)
        #expect(history.entries.count == 30)
        #expect(newest.lockedAt == Date(timeIntervalSince1970: 136))
        #expect(oldest.lockedAt == Date(timeIntervalSince1970: 20))
    }

    @Test func oldBLESettingsDecodeWithEmptyScreenLockHistory() throws {
        let data = Data(#"""
        {
          "isEnabled": true,
          "monitoredDeviceUUID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        }
        """#.utf8)

        let settings = try JSONDecoder().decode(BLEUnlockSettings.self, from: data)

        #expect(settings.screenLockHistory.entries.isEmpty)
    }
}
