import Testing
import Foundation
@testable import ClipRoidUI
import ClipRoidCore

@Suite("Timeline view model")
@MainActor
struct TimelineViewModelTests {

    private func summary(id: Int64, preview: String, at date: Date = Date()) -> ClipSummary {
        ClipSummary(id: id, uuid: UUID(), contentType: .text, preview: preview, copiedAt: date)
    }

    /// The view model is driven entirely by deltas, so these exercise `apply` directly rather than
    /// standing up a database.
    @Test("An insert lands at the top of the timeline")
    func appliesInsert() {
        let model = TimelineViewModel(store: .makeDefault(root: URL(fileURLWithPath: "/dev/null")))
        model.apply(.inserted(summary(id: 1, preview: "first")))
        model.apply(.inserted(summary(id: 2, preview: "second")))
        #expect(model.clips.map(\.preview) == ["second", "first"])
    }

    @Test("A promotion moves an existing clip to the top without duplicating it")
    func appliesPromotion() {
        let model = TimelineViewModel(store: .makeDefault(root: URL(fileURLWithPath: "/dev/null")))
        let first = summary(id: 1, preview: "first")
        model.apply(.inserted(first))
        model.apply(.inserted(summary(id: 2, preview: "second")))
        model.apply(.promoted(first))
        #expect(model.clips.map(\.id) == [1, 2])
        #expect(model.clips.count == 2, "a promotion must not add a row")
    }

    @Test("A delete removes exactly the named rows")
    func appliesDelete() {
        let model = TimelineViewModel(store: .makeDefault(root: URL(fileURLWithPath: "/dev/null")))
        model.apply(.inserted(summary(id: 1, preview: "a")))
        model.apply(.inserted(summary(id: 2, preview: "b")))
        model.apply(.deleted([1]))
        #expect(model.clips.map(\.id) == [2])
    }

    @Test("An update replaces a row in place")
    func appliesUpdate() {
        let model = TimelineViewModel(store: .makeDefault(root: URL(fileURLWithPath: "/dev/null")))
        var s = summary(id: 1, preview: "before")
        model.apply(.inserted(s))
        s.preview = "after"
        model.apply(.updated(s))
        #expect(model.clips.map(\.preview) == ["after"])
    }
}

@Suite("Clip timestamps")
struct ClipTimestampTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func settled(secondsAgo: TimeInterval) -> String {
        ClipTimestamp.settled(now.addingTimeInterval(-secondsAgo), now: now)
    }

    /// Seconds are only shown for the first minute; past that they are noise and cause a re-render
    /// of every visible row once a second.
    @Test("Seconds stop being counted after a minute", arguments: [
        (5.0, "5s ago"),
        (59.0, "59s ago"),
        (60.0, "1m ago"),
        (90.0, "1m ago"),
        (3_599.0, "59m ago"),
        (3_600.0, "1h ago"),
        (86_399.0, "23h ago"),
        (86_400.0, "1d ago"),
    ])
    func formatsByAge(secondsAgo: TimeInterval, expected: String) {
        #expect(settled(secondsAgo: secondsAgo) == expected)
    }

    @Test("Beyond a week it becomes a date rather than a growing day count")
    func fallsBackToDate() {
        let result = settled(secondsAgo: 86_400 * 30)
        #expect(!result.hasSuffix("ago"))
        #expect(!result.isEmpty)
    }

    /// Clock skew, or an iCloud sync from a device a few seconds ahead, must not render as a
    /// negative interval.
    @Test("A timestamp slightly in the future reads as now")
    func handlesFutureDates() {
        #expect(ClipTimestamp.settled(now.addingTimeInterval(30), now: now) == "now")
    }
}
