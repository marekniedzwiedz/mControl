import Foundation

public enum BlockManagerError: Error, LocalizedError {
    case groupNotFound
    case intervalNotFound
    case invalidGroupName
    case emptyDomainList
    case invalidDuration
    case invalidIntervalRange
    case strictIntervalCannotStop
    case intervalNotActive

    public var errorDescription: String? {
        switch self {
        case .groupNotFound:
            return "The selected block group no longer exists."
        case .intervalNotFound:
            return "The selected block interval no longer exists."
        case .invalidGroupName:
            return "Group name cannot be empty."
        case .emptyDomainList:
            return "At least one valid domain is required."
        case .invalidDuration:
            return "Duration must be greater than zero minutes."
        case .invalidIntervalRange:
            return "Interval end time must be after its start time."
        case .strictIntervalCannotStop:
            return "Strict sessions cannot be stopped early."
        case .intervalNotActive:
            return "This interval is not currently active."
        }
    }
}

public final class BlockManager {
    private var state: AppState
    private let store: StateStore

    public init(store: StateStore) throws {
        self.store = store
        self.state = try store.load()
        self.state.groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func allGroups() -> [BlockGroup] {
        state.groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func snapshotState() -> AppState {
        state
    }

    public func restoreState(_ state: AppState) throws {
        var restoredState = state
        for index in restoredState.groups.indices {
            restoredState.groups[index].intervals.sort { $0.startDate < $1.startDate }
        }
        restoredState.groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.state = restoredState
        try store.save(restoredState)
    }

    @discardableResult
    public func addGroup(name: String, domains: [String], severity: BlockSeverity) throws -> BlockGroup {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw BlockManagerError.invalidGroupName
        }

        let normalizedDomains = DomainSanitizer.normalizeList(domains)
        guard !normalizedDomains.isEmpty else {
            throw BlockManagerError.emptyDomainList
        }

        let group = BlockGroup(
            name: normalizedName,
            domains: normalizedDomains,
            severity: severity,
            intervals: []
        )

        state.groups.append(group)
        state.groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try store.save(state)
        return group
    }

    public func updateGroup(id: UUID, name: String, domains: [String], severity: BlockSeverity) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw BlockManagerError.invalidGroupName
        }

        let normalizedDomains = DomainSanitizer.normalizeList(domains)
        guard !normalizedDomains.isEmpty else {
            throw BlockManagerError.emptyDomainList
        }

        guard let index = state.groups.firstIndex(where: { $0.id == id }) else {
            throw BlockManagerError.groupNotFound
        }

        state.groups[index].name = normalizedName
        state.groups[index].domains = normalizedDomains
        state.groups[index].severity = severity
        state.groups[index].intervals.sort { $0.startDate < $1.startDate }

        state.groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try store.save(state)
    }

    public func deleteGroup(id: UUID) throws {
        guard let index = state.groups.firstIndex(where: { $0.id == id }) else {
            throw BlockManagerError.groupNotFound
        }

        state.groups.remove(at: index)
        try store.save(state)
    }

    @discardableResult
    public func startNow(groupID: UUID, durationMinutes: Int, now: Date = Date()) throws -> BlockInterval {
        guard durationMinutes > 0 else {
            throw BlockManagerError.invalidDuration
        }

        guard let groupIndex = state.groups.firstIndex(where: { $0.id == groupID }) else {
            throw BlockManagerError.groupNotFound
        }

        // "Start now" intentionally overrides any currently active intervals for the same group.
        for intervalIndex in state.groups[groupIndex].intervals.indices
        where state.groups[groupIndex].intervals[intervalIndex].isActive(at: now) {
            state.groups[groupIndex].intervals[intervalIndex].endDate = now
        }

        let endDate = now.addingTimeInterval(Double(durationMinutes) * 60)
        return try scheduleInterval(groupID: groupID, startDate: now, endDate: endDate)
    }

    @discardableResult
    public func scheduleInterval(groupID: UUID, startDate: Date, endDate: Date) throws -> BlockInterval {
        guard endDate > startDate else {
            throw BlockManagerError.invalidIntervalRange
        }

        guard let groupIndex = state.groups.firstIndex(where: { $0.id == groupID }) else {
            throw BlockManagerError.groupNotFound
        }

        let group = state.groups[groupIndex]
        let lockedDomains = group.severity == .strict ? DomainSanitizer.normalizeList(group.domains) : nil
        let interval = BlockInterval(startDate: startDate, endDate: endDate, lockedDomains: lockedDomains)

        state.groups[groupIndex].intervals.append(interval)
        state.groups[groupIndex].intervals.sort { $0.startDate < $1.startDate }
        try store.save(state)

        return interval
    }

    public func stopIntervalEarly(groupID: UUID, intervalID: UUID, at date: Date = Date()) throws {
        guard let groupIndex = state.groups.firstIndex(where: { $0.id == groupID }) else {
            throw BlockManagerError.groupNotFound
        }

        guard let intervalIndex = state.groups[groupIndex].intervals.firstIndex(where: { $0.id == intervalID }) else {
            throw BlockManagerError.intervalNotFound
        }

        let interval = state.groups[groupIndex].intervals[intervalIndex]

        guard interval.isActive(at: date) else {
            throw BlockManagerError.intervalNotActive
        }

        if state.groups[groupIndex].severity == .strict {
            throw BlockManagerError.strictIntervalCannotStop
        }

        state.groups[groupIndex].intervals[intervalIndex].endDate = date
        try store.save(state)
    }

    public func pruneExpiredIntervals(referenceDate: Date = Date(), keepLatestPastIntervals: Int = 3) throws {
        var hasChanges = false

        for index in state.groups.indices {
            let sortedIntervals = state.groups[index].intervals.sorted { $0.startDate < $1.startDate }
            let activeOrFuture = sortedIntervals.filter { $0.endDate > referenceDate }
            let past = sortedIntervals.filter { $0.endDate <= referenceDate }
            let retainedPast = Array(past.suffix(max(0, keepLatestPastIntervals)))
            let merged = (retainedPast + activeOrFuture).sorted { $0.startDate < $1.startDate }

            if merged != state.groups[index].intervals {
                state.groups[index].intervals = merged
                hasChanges = true
            }
        }

        if hasChanges {
            try store.save(state)
        }
    }

    public func activeSnapshots(at date: Date = Date()) -> [ActiveGroupSnapshot] {
        BlockPlanner.activeSnapshots(in: state, at: date)
    }

    public func activeDomains(at date: Date = Date()) -> [String] {
        BlockPlanner.activeDomains(in: state, at: date)
    }

    public func nextStateChangeDate(at date: Date = Date()) -> Date? {
        BlockPlanner.nextStateChangeDate(in: state, at: date)
    }
}
