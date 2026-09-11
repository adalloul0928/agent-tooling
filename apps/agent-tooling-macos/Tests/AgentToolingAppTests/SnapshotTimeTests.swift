import Foundation
import Testing

@testable import AgentToolingApp

/// Times on screen are snapshots of when something happened, in the words a
/// person would use, and never a running clock.
@Suite("Snapshot time")
struct SnapshotTimeTests {
    /// Noon UTC on a fixed day, on a calendar pinned to UTC, so "yesterday" and
    /// the weekday never depend on where or when the test runs.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }
    private let noon = Date(timeIntervalSince1970: 1789041600)

    @Test func momentsAgoAreSaidInTheSmallestUnitThatFits() {
        #expect(SnapshotTime.compact(noon.addingTimeInterval(-5), now: noon, calendar: calendar) == "just now")
        #expect(SnapshotTime.compact(noon.addingTimeInterval(-25 * 60), now: noon, calendar: calendar) == "25m ago")
        #expect(SnapshotTime.compact(noon.addingTimeInterval(-3 * 3_600), now: noon, calendar: calendar) == "3h ago")
        #expect(SnapshotTime.compact(noon.addingTimeInterval(-23 * 3_600), now: noon, calendar: calendar) == "23h ago")
    }

    @Test func olderMomentsAreNamedNotCounted() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
        #expect(SnapshotTime.compact(yesterday.addingTimeInterval(-3_600), now: noon, calendar: calendar) == "yesterday")
        let lastWeek = calendar.date(byAdding: .day, value: -4, to: noon)!
        #expect(
            SnapshotTime.compact(lastWeek, now: noon, calendar: calendar)
                == lastWeek.formatted(.dateTime.weekday(.abbreviated)))
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: noon)!
        #expect(
            SnapshotTime.compact(lastMonth, now: noon, calendar: calendar)
                == lastMonth.formatted(.dateTime.month(.abbreviated).day()))
        let lastYear = calendar.date(byAdding: .year, value: -1, to: noon)!
        #expect(
            SnapshotTime.compact(lastYear, now: noon, calendar: calendar)
                == lastYear.formatted(.dateTime.month(.abbreviated).day().year()))
    }

    @Test func aMomentInTheFutureIsJustNow() {
        #expect(SnapshotTime.compact(noon.addingTimeInterval(120), now: noon, calendar: calendar) == "just now")
    }

    @Test func standaloneFormStartsWithACapital() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
        #expect(SnapshotTime.standalone(yesterday, now: noon, calendar: calendar) == "Yesterday")
        #expect(SnapshotTime.standalone(noon.addingTimeInterval(-60 * 7), now: noon, calendar: calendar) == "7m ago")
    }
}
