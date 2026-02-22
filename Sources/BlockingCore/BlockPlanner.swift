import Foundation

public enum BlockPlanner {
    public static func activeSnapshots(in state: AppState, at date: Date) -> [ActiveGroupSnapshot] {
        var snapshots: [ActiveGroupSnapshot] = []

        for group in state.groups {
            for interval in group.intervals where interval.isActive(at: date) {
                let domains = effectiveDomains(for: group, interval: interval)
                guard !domains.isEmpty else {
                    continue
                }

                snapshots.append(
                    ActiveGroupSnapshot(
                        groupID: group.id,
                        groupName: group.name,
                        severity: group.severity,
                        intervalID: interval.id,
                        endsAt: interval.endDate,
                        domains: domains
                    )
                )
            }
        }

        return snapshots.sorted {
            if $0.endsAt == $1.endsAt {
                return $0.groupName.localizedCaseInsensitiveCompare($1.groupName) == .orderedAscending
            }
            return $0.endsAt < $1.endsAt
        }
    }

    public static func activeDomains(in state: AppState, at date: Date) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for snapshot in activeSnapshots(in: state, at: date) {
            for domain in snapshot.domains where !seen.contains(domain) {
                seen.insert(domain)
                result.append(domain)
            }
        }

        return result
    }

    public static func nextStateChangeDate(in state: AppState, at date: Date) -> Date? {
        var candidates: [Date] = []

        for group in state.groups {
            for interval in group.intervals {
                if interval.startDate > date {
                    candidates.append(interval.startDate)
                }
                if interval.endDate > date {
                    candidates.append(interval.endDate)
                }
            }
        }

        return candidates.min()
    }

    public static func effectiveDomains(for group: BlockGroup, interval: BlockInterval) -> [String] {
        switch group.severity {
        case .strict:
            if let locked = interval.lockedDomains, !locked.isEmpty {
                return DomainSanitizer.normalizeList(locked)
            }
            return DomainSanitizer.normalizeList(group.domains)
        case .flexible:
            return DomainSanitizer.normalizeList(group.domains)
        }
    }
}
