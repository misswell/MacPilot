import Foundation
import MacPilotLocalPortsCore
import Testing
@testable import MacPilot

/// The menu-bar submenu lists the same processes the page shows, so its
/// grouping and truncation are pinned here rather than left to the view.
struct LocalPortsMenuTests {
    @Test func oneProcessWithSeveralPortsBecomesOneRowListingEveryPort() {
        let snapshot = LocalPortSnapshot(activities: [
            activity(pid: 42, port: 5173, label: "OctoPilot", category: .project),
            activity(pid: 42, port: 3000, label: "OctoPilot", category: .project),
        ])
        let rows = LocalPortsMenuPresentation.rows(from: snapshot)

        #expect(rows.count == 1)
        #expect(rows[0].ports == [3000, 5173])
        #expect(rows[0].portList == "3000, 5173")
    }

    @Test func theSamePortOnTwoAddressesStillTakesOneSlotInTheRow() {
        let snapshot = LocalPortSnapshot(activities: [
            activity(pid: 42, port: 8080, label: "api", category: .service, scope: .local),
            activity(pid: 42, port: 8080, label: "api", category: .service, scope: .lan),
        ])
        let rows = LocalPortsMenuPresentation.rows(from: snapshot)

        #expect(rows.count == 1)
        #expect(rows[0].ports == [8080])
        #expect(rows[0].isLAN)
    }

    @Test func rowsFollowThePagesOwnerOrderSoTruncationKeepsProjects() {
        let snapshot = LocalPortSnapshot(activities: [
            activity(pid: 11, port: 9000, label: "Zebra", category: .service),
            activity(pid: 22, port: 4000, label: "Alpha", category: .project),
            activity(pid: 33, port: 1000, label: "Safari", category: .application),
            activity(pid: 44, port: 123, label: "launchd", category: .systemService),
        ])
        let rows = LocalPortsMenuPresentation.rows(from: snapshot)

        // Ports alone would put launchd and Safari first; the page's category
        // order must win, or the menu's ten rows fill up with daemons.
        #expect(rows.map(\.pid) == [22, 11, 33, 44])
        #expect(rows.map(\.isProject) == [true, false, false, false])
    }

    @Test func theMenuShowsOnlyItsCapAndSaysHowManyItLeftOut() {
        let activities = (0..<12).map {
            activity(pid: Int32(100 + $0), port: 2000 + $0, label: "svc\($0)", category: .service)
        }
        let snapshot = LocalPortSnapshot(activities: activities)
        let rows = LocalPortsMenuPresentation.rows(from: snapshot)

        #expect(rows.count == 12)
        #expect(Array(rows.prefix(LocalPortsMenuPresentation.maximumRows)).count == 10)
        #expect(LocalPortsMenuPresentation.hiddenRowCount(from: snapshot) == 2)
    }

    @Test func aRowReadsAsPortsThenOwnerThenPID() {
        let row = LocalPortsMenuPresentation.Row(
            pid: 4242,
            ports: [3000, 5173],
            ownerLabel: "OctoPilot",
            category: .project,
            isLAN: false
        )
        #expect(row.title(lanLabel: "LAN") == "3000, 5173 — OctoPilot · PID 4242")

        let exposed = LocalPortsMenuPresentation.Row(
            pid: 4242,
            ports: [8080],
            ownerLabel: "api",
            category: .service,
            isLAN: true
        )
        #expect(exposed.title(lanLabel: "局域网") == "8080 — api · PID 4242 · 局域网")
    }

    @Test func anEmptySnapshotHasNothingToHide() {
        #expect(LocalPortsMenuPresentation.rows(from: .empty).isEmpty)
        #expect(LocalPortsMenuPresentation.hiddenRowCount(from: .empty) == 0)
    }

    @Test func theMenuOnlyClaimsNoServicesAfterAScanActuallyFoundNone() {
        // Before the first scan lands, or while one is running, an empty list is
        // a promise; after a failure it is not a finding either.
        #expect(LocalPortsMenuPresentation.emptyStateKey(
            isRefreshing: false, hasLoadedOnce: false, scanFailed: false
        ) == "localPortsRefreshing")
        #expect(LocalPortsMenuPresentation.emptyStateKey(
            isRefreshing: true, hasLoadedOnce: true, scanFailed: false
        ) == "localPortsRefreshing")
        #expect(LocalPortsMenuPresentation.emptyStateKey(
            isRefreshing: false, hasLoadedOnce: true, scanFailed: false
        ) == "localPortsNoServices")
        #expect(LocalPortsMenuPresentation.emptyStateKey(
            isRefreshing: false, hasLoadedOnce: true, scanFailed: true
        ) == "localPortsScanFailed")
        #expect(LocalPortsMenuPresentation.emptyStateKey(
            isRefreshing: true, hasLoadedOnce: false, scanFailed: true
        ) == "localPortsScanFailed")
    }

    private func activity(
        pid: Int32,
        port: Int,
        label: String,
        category: LocalPortOwnerCategory,
        scope: LocalPortScope = .local
    ) -> LocalPortActivity {
        LocalPortActivity(
            listener: LocalPortListener(
                pid: pid,
                command: "node",
                uid: 501,
                user: "me",
                port: port,
                addresses: scope == .lan ? ["0.0.0.0"] : ["127.0.0.1"]
            ),
            process: LocalPortProcess(
                pid: pid,
                ppid: 1,
                command: "node",
                executablePath: "/usr/local/bin/node",
                uid: 501,
                user: "me",
                cwd: "/tmp/project"
            ),
            parentChain: [],
            project: nil,
            application: nil,
            scope: scope,
            owner: LocalPortOwner(
                label: label,
                category: category,
                confidence: .high,
                reason: .unknown
            )
        )
    }
}
