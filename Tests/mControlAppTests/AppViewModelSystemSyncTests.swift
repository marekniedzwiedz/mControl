import BlockingCore
import Foundation
import Testing
@testable import mControlApp

@Suite("AppViewModel system sync rollback")
struct AppViewModelSystemSyncTests {
    @MainActor
    @Test("launch applies system sync when persisted sessions are active and hosts are out of sync")
    func launchAppliesSyncWhenHostsAreOutOfSync() async throws {
        let manager = try BlockManager(store: InMemoryStateStore())
        let group = try manager.addGroup(name: "Focus", domains: ["x.com"], severity: .flexible)
        _ = try manager.startNow(groupID: group.id, durationMinutes: 60, now: Date())

        let updater = RecordingHostsUpdater()
        let viewModel = AppViewModel(
            manager: manager,
            hostsUpdater: updater,
            hostsFileContentsProvider: { baseHostsContent() },
            pfAnchorContentsProvider: { cleanPFAnchorContent() }
        )

        #expect(updater.applyCallCount == 0)
        await viewModel.waitForPendingLaunchWorkForTests()

        #expect(updater.applyCallCount == 1)
        let appliedDomains = try #require(updater.appliedDomains.first)
        #expect(appliedDomains == ["x.com"])
    }

    @MainActor
    @Test("launch forces system sync when persisted sessions are active even if hosts already match")
    func launchForcesSyncWhenSessionsAreActiveAndHostsAlreadyMatch() async throws {
        let manager = try BlockManager(store: InMemoryStateStore())
        let group = try manager.addGroup(name: "Focus", domains: ["x.com"], severity: .flexible)
        _ = try manager.startNow(groupID: group.id, durationMinutes: 60, now: Date())

        let activeDomains = manager.activeDomains(at: Date())
        let syncedHosts = HostsSectionRenderer.render(
            originalHosts: baseHostsContent(),
            activeDomains: activeDomains
        )

        let updater = RecordingHostsUpdater()
        let viewModel = AppViewModel(
            manager: manager,
            hostsUpdater: updater,
            hostsFileContentsProvider: { syncedHosts },
            pfAnchorContentsProvider: { cleanPFAnchorContent() }
        )

        #expect(updater.applyCallCount == 0)
        await viewModel.waitForPendingLaunchWorkForTests()

        #expect(updater.applyCallCount == 1)
        let appliedDomains = try #require(updater.appliedDomains.first)
        #expect(appliedDomains == ["x.com"])
    }

    @MainActor
    @Test("launch skips sync when no sessions are active and hosts are already clean")
    func launchSkipsSyncWhenNoSessionsAndHostsClean() async throws {
        let manager = try BlockManager(store: InMemoryStateStore())
        let updater = RecordingHostsUpdater()

        let viewModel = AppViewModel(
            manager: manager,
            hostsUpdater: updater,
            hostsFileContentsProvider: { baseHostsContent() },
            pfAnchorContentsProvider: { cleanPFAnchorContent() }
        )

        await viewModel.waitForPendingLaunchWorkForTests()
        #expect(updater.applyCallCount == 0)
    }

    @MainActor
    @Test("launch flushes stale PF anchor when no sessions are active")
    func launchFlushesStalePFAnchorWhenNoSessionsAreActive() async throws {
        let manager = try BlockManager(store: InMemoryStateStore())
        let updater = RecordingHostsUpdater()

        let viewModel = AppViewModel(
            manager: manager,
            hostsUpdater: updater,
            hostsFileContentsProvider: { baseHostsContent() },
            pfAnchorContentsProvider: { stalePFAnchorContent() }
        )

        #expect(updater.applyCallCount == 0)
        await viewModel.waitForPendingLaunchWorkForTests()
        #expect(updater.applyCallCount == 1)
        let appliedDomains = try #require(updater.appliedDomains.first)
        #expect(appliedDomains.isEmpty)
    }

    @MainActor
    @Test("active sessions trigger periodic system sync once interval elapses")
    func activeSessionsTriggerPeriodicSystemSync() async throws {
        let manager = try BlockManager(store: InMemoryStateStore())
        let group = try manager.addGroup(name: "Focus", domains: ["x.com"], severity: .flexible)

        let launchDate = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try manager.startNow(groupID: group.id, durationMinutes: 180, now: launchDate)

        var currentDate = launchDate
        let updater = RecordingHostsUpdater()
        let viewModel = AppViewModel(
            manager: manager,
            hostsUpdater: updater,
            hostsFileContentsProvider: { baseHostsContent() },
            pfAnchorContentsProvider: { cleanPFAnchorContent() },
            dateProvider: { currentDate },
            periodicPFRefreshInterval: 3600
        )

        await viewModel.waitForPendingLaunchWorkForTests()
        #expect(updater.applyCallCount == 1)

        currentDate = launchDate.addingTimeInterval(3599)
        viewModel.processTick()
        #expect(updater.applyCallCount == 1)

        currentDate = launchDate.addingTimeInterval(3600)
        viewModel.processTick()
        #expect(updater.applyCallCount == 2)
    }

    @MainActor
    @Test("no periodic sync runs when there are no active sessions")
    func noPeriodicSyncWhenNoActiveSessions() throws {
        let manager = try BlockManager(store: InMemoryStateStore())
        let launchDate = Date(timeIntervalSince1970: 1_700_000_000)
        var currentDate = launchDate

        let updater = RecordingHostsUpdater()
        let viewModel = AppViewModel(
            manager: manager,
            hostsUpdater: updater,
            hostsFileContentsProvider: { baseHostsContent() },
            pfAnchorContentsProvider: { cleanPFAnchorContent() },
            dateProvider: { currentDate },
            periodicPFRefreshInterval: 3600,
            scheduleLaunchWork: false
        )

        #expect(updater.applyCallCount == 0)

        currentDate = launchDate.addingTimeInterval(7200)
        viewModel.processTick()
        #expect(updater.applyCallCount == 0)
    }

    @MainActor
    @Test("start interval rolls back when admin authorization is canceled")
    func startIntervalRollsBackWhenAdminAuthorizationIsCanceled() throws {
        let manager = try BlockManager(store: InMemoryStateStore())
        let group = try manager.addGroup(name: "Focus", domains: ["x.com"], severity: .flexible)
        let failingUpdater = FailingHostsUpdater(
            error: HostsUpdaterError.privilegedCommandFailed("User canceled.")
        )
        let viewModel = AppViewModel(
            manager: manager,
            hostsUpdater: failingUpdater,
            hostsFileContentsProvider: { baseHostsContent() },
            pfAnchorContentsProvider: { cleanPFAnchorContent() },
            scheduleLaunchWork: false
        )

        viewModel.startQuickInterval(group: group, minutes: 60)

        #expect(viewModel.activeSnapshots.isEmpty)
        #expect(viewModel.activeDomains.isEmpty)
        #expect(manager.activeSnapshots(at: Date()).isEmpty)
        #expect(viewModel.errorMessage == "Admin authorization was canceled. Changes were not applied.")
    }

    @MainActor
    @Test("stop interval rolls back when admin authorization is canceled")
    func stopIntervalRollsBackWhenAdminAuthorizationIsCanceled() throws {
        let manager = try BlockManager(store: InMemoryStateStore())
        let group = try manager.addGroup(name: "Focus", domains: ["x.com"], severity: .flexible)
        _ = try manager.startNow(groupID: group.id, durationMinutes: 60, now: Date())

        let failingUpdater = FailingHostsUpdater(
            error: HostsUpdaterError.privilegedCommandFailed("User canceled.")
        )
        let syncedHosts = HostsSectionRenderer.render(
            originalHosts: baseHostsContent(),
            activeDomains: manager.activeDomains(at: Date())
        )
        let viewModel = AppViewModel(
            manager: manager,
            hostsUpdater: failingUpdater,
            hostsFileContentsProvider: { syncedHosts },
            pfAnchorContentsProvider: { cleanPFAnchorContent() },
            scheduleLaunchWork: false
        )
        let activeSnapshot = try #require(viewModel.activeSnapshots.first)

        viewModel.stopInterval(activeSnapshot)

        #expect(!viewModel.activeSnapshots.isEmpty)
        #expect(!viewModel.activeDomains.isEmpty)
        #expect(!manager.activeSnapshots(at: Date()).isEmpty)
        #expect(viewModel.errorMessage == "Admin authorization was canceled. Changes were not applied.")
    }

    @MainActor
    @Test("start all groups rolls back local mutations when one group cannot be replaced")
    func startAllGroupsRollsBackWhenAnyGroupFailsBeforeSystemSync() async throws {
        let manager = try BlockManager(store: InMemoryStateStore())
        let launchDate = Date(timeIntervalSince1970: 1_700_000_000)

        let flexibleGroup = try manager.addGroup(name: "A Flexible", domains: ["a.com"], severity: .flexible)
        let strictGroup = try manager.addGroup(name: "Z Strict", domains: ["z.com"], severity: .strict)
        _ = try manager.startNow(groupID: strictGroup.id, durationMinutes: 180, now: launchDate)

        let updater = RecordingHostsUpdater()
        let viewModel = AppViewModel(
            manager: manager,
            hostsUpdater: updater,
            hostsFileContentsProvider: { baseHostsContent() },
            pfAnchorContentsProvider: { cleanPFAnchorContent() },
            dateProvider: { launchDate }
        )

        await viewModel.waitForPendingLaunchWorkForTests()
        viewModel.startAllGroups(minutes: 60)

        let activeNames = Set(viewModel.activeSnapshots.map(\.groupName))
        #expect(activeNames == ["Z Strict"])
        #expect(viewModel.errorMessage == BlockManagerError.activeStrictIntervalCannotBeReplaced.localizedDescription)
        #expect(updater.applyCallCount == 1)
        _ = flexibleGroup
    }
}

private func baseHostsContent() -> String {
    "127.0.0.1 localhost\n"
}

private func cleanPFAnchorContent() -> String {
    """
    # mControl generated PF rules
    # no active domains
    """
}

private func stalePFAnchorContent() -> String {
    """
    # mControl generated PF rules
    table <mcontrol_ipv4> persist { 104.244.42.1 }
    block drop out quick inet to <mcontrol_ipv4>
    """
}

private final class FailingHostsUpdater: HostsUpdating, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func apply(activeDomains: [String]) throws {
        _ = activeDomains
        throw error
    }
}

private final class RecordingHostsUpdater: HostsUpdating, @unchecked Sendable {
    private(set) var applyCallCount: Int = 0
    private(set) var appliedDomains: [[String]] = []

    func apply(activeDomains: [String]) throws {
        applyCallCount += 1
        appliedDomains.append(activeDomains)
    }
}
