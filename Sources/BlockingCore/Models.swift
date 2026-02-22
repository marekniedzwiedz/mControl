import Foundation

public enum BlockSeverity: String, Codable, CaseIterable, Identifiable, Sendable {
    case strict
    case flexible

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .strict:
            return "Strict"
        case .flexible:
            return "Flexible"
        }
    }

    public var description: String {
        switch self {
        case .strict:
            return "Cannot be stopped early once started."
        case .flexible:
            return "Can be ended early from the app."
        }
    }
}

public struct BlockInterval: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    public var lockedDomains: [String]?

    public init(id: UUID = UUID(), startDate: Date, endDate: Date, lockedDomains: [String]? = nil) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.lockedDomains = lockedDomains
    }

    public var isValid: Bool {
        endDate > startDate
    }

    public func isActive(at date: Date) -> Bool {
        startDate <= date && date < endDate
    }

    public func remainingTime(at date: Date) -> TimeInterval {
        max(0, endDate.timeIntervalSince(date))
    }
}

public struct BlockGroup: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var domains: [String]
    public var severity: BlockSeverity
    public var intervals: [BlockInterval]

    public init(
        id: UUID = UUID(),
        name: String,
        domains: [String],
        severity: BlockSeverity,
        intervals: [BlockInterval] = []
    ) {
        self.id = id
        self.name = name
        self.domains = domains
        self.severity = severity
        self.intervals = intervals
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var groups: [BlockGroup]

    public init(groups: [BlockGroup] = []) {
        self.groups = groups
    }
}

public struct ActiveGroupSnapshot: Identifiable, Equatable, Sendable {
    public var groupID: UUID
    public var groupName: String
    public var severity: BlockSeverity
    public var intervalID: UUID
    public var endsAt: Date
    public var domains: [String]

    public var id: UUID { intervalID }

    public init(
        groupID: UUID,
        groupName: String,
        severity: BlockSeverity,
        intervalID: UUID,
        endsAt: Date,
        domains: [String]
    ) {
        self.groupID = groupID
        self.groupName = groupName
        self.severity = severity
        self.intervalID = intervalID
        self.endsAt = endsAt
        self.domains = domains
    }
}
