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
