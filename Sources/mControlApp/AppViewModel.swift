import BlockingCore
import Foundation
import SwiftUI

struct GroupDraft {
    var groupID: UUID?
    var name: String
    var domainsText: String
    var severity: BlockSeverity

    static func createDefault() -> GroupDraft {
        GroupDraft(groupID: nil, name: "", domainsText: "", severity: .strict)
    }

    static func from(group: BlockGroup) -> GroupDraft {
        GroupDraft(
            groupID: group.id,
            name: group.name,
            domainsText: group.domains.joined(separator: "\n"),
            severity: group.severity
        )
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var groups: [BlockGroup] = []
    @Published private(set) var activeSnapshots: [ActiveGroupSnapshot] = []
    @Published private(set) var activeDomains: [String] = []
    @Published private(set) var now: Date = Date()
    @Published private(set) var hostsStatusMessage: String = "System block sync pending"
    @Published private(set) var hasManagedHostsBlock: Bool = false

    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private let manager: BlockManager
    private let hostsUpdater: HostsUpdating
    private let hostsFileContentsProvider: () -> String?
    private let pfAnchorContentsProvider: () -> String?
    private let dateProvider: () -> Date
    private let periodicPFRefreshInterval: TimeInterval
    private let forcedPeriodicSyncEnabledProvider: () -> Bool
    private var refreshTimer: Timer?
    private var lastAppliedDomains: [String] = []
    private var lastHostsApplyFailureDate: Date?
    private var isSystemSyncInProgress: Bool = false
    private var lastSuccessfulSystemSyncDate: Date?
    private var lastPeriodicRefreshAttemptDate: Date?

    init(
        manager: BlockManager,
        hostsUpdater: HostsUpdating,
        hostsFileContentsProvider: @escaping () -> String? = AppViewModel.readSystemHostsFile,
        pfAnchorContentsProvider: @escaping () -> String? = AppViewModel.readSystemPFAnchorFile,
        dateProvider: @escaping () -> Date = Date.init,
        periodicPFRefreshInterval: TimeInterval = 3600,
        forcedPeriodicSyncEnabledProvider: @escaping () -> Bool = { true }
    ) {
        self.manager = manager
        self.hostsUpdater = hostsUpdater
        self.hostsFileContentsProvider = hostsFileContentsProvider
        self.pfAnchorContentsProvider = pfAnchorContentsProvider
        self.dateProvider = dateProvider
        self.periodicPFRefreshInterval = max(60, periodicPFRefreshInterval)
        self.forcedPeriodicSyncEnabledProvider = forcedPeriodicSyncEnabledProvider

        let launchDate = dateProvider()
        loadStateWithoutHostsWrite(currentDate: launchDate)
        synchronizeSystemStateOnLaunchIfNeeded(referenceDate: launchDate)
        startTimer()
    }

    static func live() throws -> AppViewModel {
        let stateStore = JSONStateStore(fileURL: try JSONStateStore.defaultFileURL())
        let manager = try BlockManager(store: stateStore)
        let daemonStateAtLaunch = PFRefreshDaemonManager.installationState()

        // If daemon files exist but are stale versus bundled resources, try one-shot repair.
        if daemonStateAtLaunch == .installedOutdated {
            try? PFRefreshDaemonManager.installOrUpdate()
        }

        let forcedPeriodicInterval: TimeInterval =
            daemonStateAtLaunch == .installedOutdated ? 60 : 3600

        return AppViewModel(
            manager: manager,
            hostsUpdater: ManagedHostsUpdater(),
            periodicPFRefreshInterval: forcedPeriodicInterval,
            forcedPeriodicSyncEnabledProvider: {
                !PFRefreshDaemonManager.installationState().isUpToDate
            }
        )
    }

    static func fallbackWithError(_ message: String) -> AppViewModel {
        let fallbackManager: BlockManager
        do {
            fallbackManager = try BlockManager(store: InMemoryStateStore())
        } catch {
            fatalError("Unable to create fallback manager: \(error.localizedDescription)")
        }
        let viewModel = AppViewModel(manager: fallbackManager, hostsUpdater: NoOpHostsUpdater())
        viewModel.errorMessage = message
        return viewModel
    }

    var menuBarSymbolName: String {
        activeSnapshots.isEmpty ? "shield" : "shield.fill"
    }

    var hasActiveSessions: Bool {
        !activeSnapshots.isEmpty
    }

    var menuBarIconColor: Color {
        activeSnapshots.isEmpty
            ? Color.secondary
            : Color(red: 0.18, green: 0.64, blue: 0.44)
    }

    var nextChangeSummary: String {
        guard let nextChange = manager.nextStateChangeDate(at: now) else {
            return "No active or scheduled sessions"
        }

        return "Next change \(Self.timeFormatter.string(from: nextChange))"
    }

    func activeSnapshots(for group: BlockGroup) -> [ActiveGroupSnapshot] {
        activeSnapshots
            .filter { $0.groupID == group.id }
            .sorted { $0.endsAt < $1.endsAt }
    }

    func saveGroup(_ draft: GroupDraft) {
        let successMessage = draft.groupID == nil ? "Group created" : "Group updated"
        performMutationWithSystemRollback(successMessage: successMessage) {
            let domains = parseDomainInput(draft.domainsText)

            if let groupID = draft.groupID {
                try manager.updateGroup(
                    id: groupID,
                    name: draft.name,
                    domains: domains,
                    severity: draft.severity
                )
            } else {
                _ = try manager.addGroup(
                    name: draft.name,
                    domains: domains,
                    severity: draft.severity
                )
            }
        }
    }

    func deleteGroup(_ group: BlockGroup) {
        performMutationWithSystemRollback(successMessage: "Group deleted") {
            try manager.deleteGroup(id: group.id)
        }
    }

    func startQuickInterval(group: BlockGroup, minutes: Int) {
        performMutationWithSystemRollback(
            successMessage: "Started \(group.name) for \(Self.durationLabel(forMinutes: minutes))"
        ) {
            _ = try manager.startNow(groupID: group.id, durationMinutes: minutes, now: now)
        }
    }

    func startAllGroups(minutes: Int) {
        let durationMinutes = max(1, minutes)
        let groupsToStart = groups

        guard !groupsToStart.isEmpty else {
            infoMessage = "No groups to start"
            return
        }

        let durationLabel = Self.durationLabel(forMinutes: durationMinutes)
        let successMessage = groupsToStart.count == 1
            ? "Started 1 group for \(durationLabel)"
            : "Started \(groupsToStart.count) groups for \(durationLabel)"

        performMutationWithSystemRollback(successMessage: successMessage) {
            for group in groupsToStart {
                _ = try manager.startNow(groupID: group.id, durationMinutes: durationMinutes, now: now)
            }
        }
    }

    func scheduleInterval(group: BlockGroup, startDate: Date, endDate: Date) {
        performMutationWithSystemRollback(successMessage: "Interval scheduled") {
            _ = try manager.scheduleInterval(groupID: group.id, startDate: startDate, endDate: endDate)
        }
    }

    func stopInterval(_ snapshot: ActiveGroupSnapshot) {
        performMutationWithSystemRollback(successMessage: "Interval stopped") {
            try manager.stopIntervalEarly(groupID: snapshot.groupID, intervalID: snapshot.intervalID, at: now)
        }
    }

    var stoppableActiveSnapshots: [ActiveGroupSnapshot] {
        activeSnapshots.filter { $0.severity == .flexible }
    }

    func stopAllStoppableSessions() {
        let snapshots = stoppableActiveSnapshots
        guard !snapshots.isEmpty else {
            return
        }

        let successMessage = snapshots.count == 1
            ? "Stopped 1 session"
            : "Stopped \(snapshots.count) sessions"

        performMutationWithSystemRollback(successMessage: successMessage) {
            for snapshot in snapshots {
                try manager.stopIntervalEarly(groupID: snapshot.groupID, intervalID: snapshot.intervalID, at: now)
            }
        }
    }

    func clearMessages() {
        errorMessage = nil
        infoMessage = nil
    }

    func formatRemaining(until date: Date) -> String {
        let interval = max(0, date.timeIntervalSince(now))

        if interval < 60 {
            return "<1m"
        }

        let minutes = Int(interval / 60)
        let hours = minutes / 60
        let remainder = minutes % 60

        if hours > 0 {
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }

        return "\(minutes)m"
    }

    func formatDateTime(_ date: Date) -> String {
        Self.dateTimeFormatter.string(from: date)
    }

    func isStoppable(_ snapshot: ActiveGroupSnapshot) -> Bool {
        snapshot.severity == .flexible
    }

    func processTick() {
        let tickDate = dateProvider()
        if shouldRunPeriodicPFRefresh(at: tickDate) {
            lastPeriodicRefreshAttemptDate = tickDate
            reloadStateAndApplyHosts(forceHostWrite: true, referenceDate: tickDate)
        } else {
            reloadStateAndApplyHosts(forceHostWrite: false, referenceDate: tickDate)
        }
    }

    private func performMutationWithSystemRollback(successMessage: String, mutation: () throws -> Void) {
        let previousState = manager.snapshotState()

        do {
            try mutation()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let operationDate = dateProvider()
        let domainsAfterMutation = manager.activeDomains(at: operationDate)
        let shouldApplySystemChanges = domainsAfterMutation != lastAppliedDomains

        if shouldApplySystemChanges {
            isSystemSyncInProgress = true
            defer { isSystemSyncInProgress = false }

            do {
                try hostsUpdater.apply(activeDomains: domainsAfterMutation)
                lastAppliedDomains = domainsAfterMutation
                lastHostsApplyFailureDate = nil
                lastSuccessfulSystemSyncDate = operationDate
                lastPeriodicRefreshAttemptDate = operationDate
            } catch {
                do {
                    try manager.restoreState(previousState)
                } catch {
                    errorMessage = "System block sync failed and rollback could not be saved: \(error.localizedDescription)"
                    refreshPublishedState(at: dateProvider(), updateLastAppliedDomains: false)
                    refreshHostsStatus(for: activeDomains)
                    return
                }

                lastHostsApplyFailureDate = dateProvider()
                infoMessage = nil
                errorMessage = syncFailureMessage(for: error)
                refreshPublishedState(at: dateProvider(), updateLastAppliedDomains: false)
                refreshHostsStatus(for: activeDomains)
                return
            }
        }

        infoMessage = successMessage
        reloadStateAndApplyHosts(forceHostWrite: false)
    }

    private func synchronizeSystemStateOnLaunchIfNeeded(referenceDate: Date) {
        if !activeDomains.isEmpty {
            // Ensure both /etc/hosts and PF anchor rules are re-applied after restart.
            lastPeriodicRefreshAttemptDate = referenceDate
            reloadStateAndApplyHosts(forceHostWrite: true, referenceDate: referenceDate)
            return
        }

        if hostsFileNeedsSync(for: activeDomains) || pfAnchorNeedsCleanupWhenIdle() {
            reloadStateAndApplyHosts(forceHostWrite: true, referenceDate: referenceDate)
        }
    }

    private func hostsFileNeedsSync(for domains: [String]) -> Bool {
        guard let hostsContent = hostsFileContentsProvider() else {
            return !domains.isEmpty
        }

        let expectedHosts = HostsSectionRenderer.render(
            originalHosts: hostsContent,
            activeDomains: domains
        )
        return expectedHosts != hostsContent
    }

    private func pfAnchorNeedsCleanupWhenIdle() -> Bool {
        guard activeDomains.isEmpty, let anchorContent = pfAnchorContentsProvider() else {
            return false
        }

        return anchorContent.contains("table <mcontrol_ipv4>")
            || anchorContent.contains("table <mcontrol_ipv6>")
            || anchorContent.contains("block drop out quick inet to <mcontrol_ipv4>")
            || anchorContent.contains("block drop out quick inet6 to <mcontrol_ipv6>")
    }

    private func syncFailureMessage(for error: Error) -> String {
        let message = error.localizedDescription
        let normalized = message.lowercased()
        if normalized.contains("user canceled") || normalized.contains("user cancelled") {
            return "Admin authorization was canceled. Changes were not applied."
        }
        return "System blocking update failed. Changes were not applied. \(message)"
    }

    private func refreshPublishedState(at date: Date, updateLastAppliedDomains: Bool) {
        now = date
        groups = manager.allGroups()
        activeSnapshots = manager.activeSnapshots(at: date)
        let domains = manager.activeDomains(at: date)
        activeDomains = domains
        if updateLastAppliedDomains {
            lastAppliedDomains = domains
        }
    }

    private func startTimer() {
        refreshTimer?.invalidate()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            Task { @MainActor in
                self.processTick()
            }
        }

        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func loadStateWithoutHostsWrite(currentDate: Date? = nil) {
        let refreshDate = currentDate ?? dateProvider()

        do {
            try manager.pruneExpiredIntervals(referenceDate: refreshDate)
        } catch {
            errorMessage = error.localizedDescription
        }

        refreshPublishedState(at: refreshDate, updateLastAppliedDomains: true)
        refreshHostsStatus(for: activeDomains)
    }

    private func reloadStateAndApplyHosts(forceHostWrite: Bool, referenceDate: Date? = nil) {
        let refreshDate = referenceDate ?? dateProvider()

        do {
            try manager.pruneExpiredIntervals(referenceDate: refreshDate)
        } catch {
            errorMessage = error.localizedDescription
        }

        refreshPublishedState(at: refreshDate, updateLastAppliedDomains: false)
        let domains = activeDomains

        let shouldWriteHosts = forceHostWrite || domains != lastAppliedDomains

        guard shouldWriteHosts else {
            refreshHostsStatus(for: domains)
            return
        }

        guard !isSystemSyncInProgress else {
            refreshHostsStatus(for: domains)
            return
        }

        if !forceHostWrite,
           let lastSuccessfulSystemSyncDate,
           refreshDate.timeIntervalSince(lastSuccessfulSystemSyncDate) < 2 {
            refreshHostsStatus(for: domains)
            return
        }

        guard forceHostWrite || canRetryAutomaticHostsApply(at: refreshDate) else {
            refreshHostsStatus(for: domains)
            return
        }

        isSystemSyncInProgress = true
        defer { isSystemSyncInProgress = false }

        do {
            try hostsUpdater.apply(activeDomains: domains)
            lastAppliedDomains = domains
            lastHostsApplyFailureDate = nil
            lastSuccessfulSystemSyncDate = refreshDate
            if domains.isEmpty {
                hostsStatusMessage = "System block sync OK: no active domains."
            } else {
                hostsStatusMessage = "System block sync OK: \(domains.count) domain(s) active."
            }
        } catch {
            lastHostsApplyFailureDate = refreshDate
            hostsStatusMessage = "System block sync failed. Waiting for next authorization prompt."
            errorMessage = error.localizedDescription
        }

        refreshHostsStatus(for: domains)
    }

    private func parseDomainInput(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: ",", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static func durationLabel(forMinutes minutes: Int) -> String {
        if minutes % (24 * 60) == 0 {
            return "\(minutes / (24 * 60))d"
        }

        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }

        return "\(minutes)m"
    }

    private func canRetryAutomaticHostsApply(at date: Date) -> Bool {
        guard let lastHostsApplyFailureDate else {
            return true
        }
        return date.timeIntervalSince(lastHostsApplyFailureDate) >= 30
    }

    private func shouldRunPeriodicPFRefresh(at date: Date) -> Bool {
        guard forcedPeriodicSyncEnabledProvider() else {
            lastPeriodicRefreshAttemptDate = nil
            return false
        }

        guard !activeDomains.isEmpty else {
            lastPeriodicRefreshAttemptDate = nil
            return false
        }

        guard !isSystemSyncInProgress else {
            return false
        }

        let referenceDate = lastPeriodicRefreshAttemptDate ?? lastSuccessfulSystemSyncDate
        guard let referenceDate else {
            return false
        }

        return date.timeIntervalSince(referenceDate) >= periodicPFRefreshInterval
    }

    private func refreshHostsStatus(for domains: [String]) {
        let hostsContent = hostsFileContentsProvider()
        hasManagedHostsBlock = hostsContent?.contains(HostsSectionRenderer.beginMarker) == true

        if domains.isEmpty {
            if hasManagedHostsBlock {
                hostsStatusMessage = "No sessions active but mControl hosts block is still present."
            } else if lastHostsApplyFailureDate == nil {
                hostsStatusMessage = "System block sync OK: no active domains."
            }
            return
        }

        if hasManagedHostsBlock {
            hostsStatusMessage = "mControl hosts block detected."
            return
        }

        if lastHostsApplyFailureDate != nil {
            hostsStatusMessage = "Pending admin authorization to update system blocking."
            return
        }

        hostsStatusMessage = "Waiting to apply system blocking."
    }

    private nonisolated static func readSystemHostsFile() -> String? {
        try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)
    }

    private nonisolated static func readSystemPFAnchorFile() -> String? {
        try? String(contentsOfFile: "/etc/pf.anchors/com.apple.mcontrol", encoding: .utf8)
    }
}

private final class NoOpHostsUpdater: HostsUpdating {
    @MainActor
    func apply(activeDomains: [String]) throws {
        _ = activeDomains
    }
}
