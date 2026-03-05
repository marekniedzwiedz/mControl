import BlockingCore
import Foundation
import Testing

@Suite("BlockManager")
struct BlockManagerTests {
    @Test("strict intervals cannot stop early")
    func strictIntervalsCannotStopEarly() throws {
        let store = InMemoryStateStore()
        let manager = try BlockManager(store: store)
        let now = Date(timeIntervalSince1970: 1_730_000_000)

        let group = try manager.addGroup(
            name: "Deep work",
            domains: ["x.com"],
            severity: .strict
        )

        let interval = try manager.scheduleInterval(
            groupID: group.id,
            startDate: now.addingTimeInterval(-300),
            endDate: now.addingTimeInterval(1_800)
        )

        #expect(throws: BlockManagerError.strictIntervalCannotStop) {
            try manager.stopIntervalEarly(groupID: group.id, intervalID: interval.id, at: now)
        }
    }

    @Test("flexible intervals can stop early")
    func flexibleIntervalsCanStopEarly() throws {
        let store = InMemoryStateStore()
        let manager = try BlockManager(store: store)
        let now = Date(timeIntervalSince1970: 1_730_000_000)

        let group = try manager.addGroup(
            name: "Social",
            domains: ["reddit.com"],
            severity: .flexible
        )

        let interval = try manager.scheduleInterval(
            groupID: group.id,
            startDate: now.addingTimeInterval(-120),
            endDate: now.addingTimeInterval(2_000)
        )

        try manager.stopIntervalEarly(groupID: group.id, intervalID: interval.id, at: now)

        let activeDomainsAfterStop = manager.activeDomains(at: now.addingTimeInterval(1))
        #expect(activeDomainsAfterStop.isEmpty)
    }

    @Test("strict active interval keeps locked domains even after group edits")
    func strictIntervalKeepsLockedDomains() throws {
        let store = InMemoryStateStore()
        let manager = try BlockManager(store: store)
        let now = Date(timeIntervalSince1970: 1_730_000_000)

        let group = try manager.addGroup(
            name: "Strict block",
            domains: ["youtube.com"],
            severity: .strict
        )

        _ = try manager.scheduleInterval(
            groupID: group.id,
            startDate: now.addingTimeInterval(-10),
            endDate: now.addingTimeInterval(3_600)
        )

        try manager.updateGroup(
            id: group.id,
            name: "Strict block",
            domains: ["news.ycombinator.com"],
            severity: .flexible
        )

        let snapshot = try #require(manager.activeSnapshots(at: now).first)
        let domains = manager.activeDomains(at: now)
        #expect(domains.contains("youtube.com"))
        #expect(!domains.contains("news.ycombinator.com"))
        #expect(snapshot.severity == .strict)
        #expect(throws: BlockManagerError.strictIntervalCannotStop) {
            try manager.stopIntervalEarly(groupID: group.id, intervalID: snapshot.intervalID, at: now)
        }
    }

    @Test("flexible active interval reflects edited domains immediately")
    func flexibleIntervalReflectsUpdatedDomains() throws {
        let store = InMemoryStateStore()
        let manager = try BlockManager(store: store)
        let now = Date(timeIntervalSince1970: 1_730_000_000)

        let group = try manager.addGroup(
            name: "Flexible block",
            domains: ["facebook.com"],
            severity: .flexible
        )

        _ = try manager.scheduleInterval(
            groupID: group.id,
            startDate: now.addingTimeInterval(-20),
            endDate: now.addingTimeInterval(3_600)
        )

        try manager.updateGroup(
            id: group.id,
            name: "Flexible block",
            domains: ["instagram.com"],
            severity: .flexible
        )

        let domains = manager.activeDomains(at: now)
        #expect(!domains.contains("facebook.com"))
        #expect(domains.contains("instagram.com"))
    }

    @Test("multiple groups can run in different intervals")
    func multipleGroupsWithDifferentIntervals() throws {
        let store = InMemoryStateStore()
        let manager = try BlockManager(store: store)
        let now = Date(timeIntervalSince1970: 1_730_000_000)

        let strictGroup = try manager.addGroup(
            name: "Work lock",
            domains: ["x.com"],
            severity: .strict
        )

        let flexibleGroup = try manager.addGroup(
            name: "Video lock",
            domains: ["youtube.com"],
            severity: .flexible
        )

        _ = try manager.scheduleInterval(
            groupID: strictGroup.id,
            startDate: now.addingTimeInterval(-30),
            endDate: now.addingTimeInterval(30 * 60)
        )

        _ = try manager.scheduleInterval(
            groupID: flexibleGroup.id,
            startDate: now.addingTimeInterval(-30),
            endDate: now.addingTimeInterval(90 * 60)
        )

        let snapshots = manager.activeSnapshots(at: now)
        #expect(snapshots.count == 2)
        #expect(snapshots.map(\.groupName).contains("Work lock"))
        #expect(snapshots.map(\.groupName).contains("Video lock"))
    }

    @Test("starting now overrides current active interval for that group")
    func startNowOverridesActiveIntervalForGroup() throws {
        let store = InMemoryStateStore()
        let manager = try BlockManager(store: store)
        let now = Date(timeIntervalSince1970: 1_730_000_000)

        let group = try manager.addGroup(
            name: "Focus",
            domains: ["x.com"],
            severity: .flexible
        )

        _ = try manager.scheduleInterval(
            groupID: group.id,
            startDate: now.addingTimeInterval(-300),
            endDate: now.addingTimeInterval(3_600)
        )

        let replacement = try manager.startNow(
            groupID: group.id,
            durationMinutes: 120,
            now: now
        )

        let snapshots = manager.activeSnapshots(at: now)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.intervalID == replacement.id)
        #expect(snapshots.first?.endsAt == now.addingTimeInterval(120 * 60))
    }

    @Test("starting now cannot replace an active strict interval")
    func startNowCannotReplaceActiveStrictInterval() throws {
        let store = InMemoryStateStore()
        let manager = try BlockManager(store: store)
        let now = Date(timeIntervalSince1970: 1_730_000_000)

        let group = try manager.addGroup(
            name: "Strict focus",
            domains: ["x.com"],
            severity: .strict
        )

        let original = try manager.scheduleInterval(
            groupID: group.id,
            startDate: now.addingTimeInterval(-300),
            endDate: now.addingTimeInterval(3_600)
        )

        #expect(throws: BlockManagerError.activeStrictIntervalCannotBeReplaced) {
            try manager.startNow(groupID: group.id, durationMinutes: 120, now: now)
        }

        let snapshot = try #require(manager.activeSnapshots(at: now).first)
        #expect(snapshot.intervalID == original.id)
        #expect(snapshot.endsAt == original.endDate)
    }

    @Test("group with active strict interval cannot be deleted")
    func activeStrictGroupCannotBeDeleted() throws {
        let store = InMemoryStateStore()
        let manager = try BlockManager(store: store)
        let now = Date(timeIntervalSince1970: 1_730_000_000)

        let group = try manager.addGroup(
            name: "Strict focus",
            domains: ["x.com"],
            severity: .strict
        )

        _ = try manager.scheduleInterval(
            groupID: group.id,
            startDate: now.addingTimeInterval(-300),
            endDate: now.addingTimeInterval(3_600)
        )

        #expect(throws: BlockManagerError.activeStrictIntervalPreventsDeletion) {
            try manager.deleteGroup(id: group.id, at: now)
        }

        #expect(manager.allGroups().count == 1)
    }
}
