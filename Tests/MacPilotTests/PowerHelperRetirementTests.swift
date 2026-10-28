import Testing
@testable import MacPilot

@MainActor
struct PowerHelperRetirementTests {
    @Test func oldJobIsRemovedOnlyAfterReleaseAndVerifiedReadback() async throws {
        var events: [String] = []
        try await PowerHelperJobRetirement.run(
            release: { events.append("release"); return .success(true) },
            read: { events.append("read"); return .success(false) },
            invalidate: { events.append("invalidate") },
            unregister: { events.append("unregister") }
        )
        #expect(events == ["release", "read", "invalidate", "unregister"])
    }
    @Test func failedReleaseNeverUnregistersTheRecoveryJob() async {
        var touched = false
        do {
            try await PowerHelperJobRetirement.run(
                release: { .failure(.requestFailed("mock failure")) },
                read: { touched = true; return .success(false) },
                invalidate: { touched = true }, unregister: { touched = true }
            )
            Issue.record("A failed release must fail retirement")
        } catch {}
        #expect(!touched)
    }
    @Test func trueAndUnknownReadbacksKeepTheRecoveryJobInstalled() async {
        for result in [Result<Bool, ClosedLidSleepFailure>.success(true), .failure(.requestFailed("unknown"))] {
            var removed = false
            do {
                try await PowerHelperJobRetirement.run(
                    release: { .success(true) }, read: { result },
                    invalidate: { removed = true }, unregister: { removed = true }
                )
                Issue.record("Unverified power state must fail retirement")
            } catch {}
            #expect(!removed)
        }
    }
    @Test func cancelledCleanupCallerStillFinishesBeforeTheNextEnable() async throws {
        let barrier = PowerHelperLifecycleBarrier()
        let (began, begin) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        var events: [String] = []
        let cleanup = Task { @MainActor in
            try await barrier.run {
                events.append("cleanup")
                begin.yield(())
                for await _ in release { break }
                events.append("retired")
            }
        }
        for await _ in began { break }
        cleanup.cancel()
        let enable = Task { @MainActor in
            try await barrier.run { events.append("enable") }
        }
        await Task.yield()
        #expect(events == ["cleanup"])
        resume.yield(())
        resume.finish()
        begin.finish()
        try await cleanup.value
        try await enable.value
        #expect(events == ["cleanup", "retired", "enable"])
    }

}
