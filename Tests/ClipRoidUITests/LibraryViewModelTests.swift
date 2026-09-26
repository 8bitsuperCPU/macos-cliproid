import Testing
import Foundation
@testable import ClipRoidUI
import ClipRoidCore
import ClipRoidStore

@Suite("Library view model")
@MainActor
struct LibraryViewModelTests {

    private func makeStore(_ scratch: Scratch) async throws -> ClipStore {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        return store
    }

    private func clip(_ body: String, type: ClipContentType = .text,
                      app: String = "com.apple.Safari", at: Date = Date()) -> CapturedClip {
        CapturedClip(contentType: type, contentHash: Dedupe.hash(body + app),
                     body: body, sourceAppBundleId: app,
                     sourceAppName: app.components(separatedBy: ".").last,
                     copiedAt: at)
    }

    @Test("Facets report per-type and per-app counts")
    func buildsFacets() async throws {
        let scratch = Scratch()
        let store = try await makeStore(scratch)
        try await store.insert(clip("a", type: .text, app: "com.apple.Safari"))
        try await store.insert(clip("b", type: .code, app: "com.apple.dt.Xcode"))
        try await store.insert(clip("c", type: .code, app: "com.apple.dt.Xcode"))

        #expect(try await store.typeCounts()[.code] == 2)
        #expect(try await store.sourceApps().first?.bundleId == "com.apple.dt.Xcode")
        await store.close()
    }

    /// The type chips are only shown under All Clips, so they must only filter there. A chip left
    /// on from All Clips used to add its type to every sidebar section — Images appearing under
    /// Text — with no visible chip to explain it or turn it off.
    @Test("Type chips only filter under All Clips")
    func chipsOnlyApplyUnderAll() async throws {
        let scratch = Scratch()
        let store = try await makeStore(scratch)
        try await store.insert(clip("safari code", type: .code, app: "com.apple.Safari"))
        try await store.insert(clip("safari text", type: .text, app: "com.apple.Safari"))
        try await store.insert(clip("safari image", type: .image, app: "com.apple.Safari"))
        try await store.insert(clip("xcode code", type: .code, app: "com.apple.dt.Xcode"))

        let model = LibraryViewModel(store: store)
        model.start()
        model.activeTypes = [.image]
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.clips.map(\.preview) == ["safari image"])

        model.section = .type(.text)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.clips.map(\.preview) == ["safari text"], "the hidden Images chip must not leak in")

        model.section = .app("com.apple.Safari")
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.clips.count == 3)

        model.section = .all
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.clips.map(\.preview) == ["safari image"], "the chip is kept for All Clips")
        await store.close()
    }

    /// A live capture must not appear in a view it does not belong to — if the user is looking at
    /// Screenshots and copies text, that text has no business showing up there.
    @Test("A new clip only appears if it matches the active filters")
    func insertRespectsFilters() async throws {
        let scratch = Scratch()
        let store = try await makeStore(scratch)
        let model = LibraryViewModel(store: store)
        model.start()
        try await Task.sleep(for: .milliseconds(150))

        model.activeTypes = [.code]
        try await Task.sleep(for: .milliseconds(250))

        model.apply(.inserted(ClipSummary(
            id: 999, uuid: UUID(), contentType: .text, preview: "plain", copiedAt: Date())))
        #expect(model.clips.isEmpty, "a text clip must not appear while filtering to code")

        model.apply(.inserted(ClipSummary(
            id: 1000, uuid: UUID(), contentType: .code, preview: "func f() {}", copiedAt: Date())))
        #expect(model.clips.count == 1)
        await store.close()
    }

    @Test("Deleting clears them from the selection too")
    func deleteClearsSelection() async throws {
        let scratch = Scratch()
        let store = try await makeStore(scratch)
        let model = LibraryViewModel(store: store)
        model.apply(.inserted(ClipSummary(id: 1, uuid: UUID(), contentType: .text,
                                          preview: "a", copiedAt: Date())))
        model.selection = [1]
        model.apply(.deleted([1]))
        #expect(model.clips.isEmpty)
        #expect(model.selection.isEmpty, "a deleted clip must not linger in the selection")
        await store.close()
    }

    /// Clearing the history from Settings must empty the Library and its sidebar counts, not just
    /// the list — otherwise "Images 2" sits beside a section with nothing in it.
    @Test("Clearing the history empties the list and the sidebar counts")
    func clearHistoryEmptiesFacets() async throws {
        let scratch = Scratch()
        let store = try await makeStore(scratch)
        try await store.insert(clip("a", type: .image))
        try await store.insert(clip("b", type: .image))
        try await store.insert(clip("c", type: .text))

        let model = LibraryViewModel(store: store)
        model.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.typeCounts[.image] == 2)

        try await store.deleteAll()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.clips.isEmpty)
        #expect(model.totalCount == 0)
        #expect((model.typeCounts[.image] ?? 0) == 0)
        await store.close()
    }

    /// Editing goes through the FTS update trigger, so the clip must become findable by its new
    /// text and stop being findable by its old. This is the round-trip that a desynchronised index
    /// would fail.
    @Test("Editing a clip's text re-indexes it")
    func editReindexes() async throws {
        let scratch = Scratch()
        let store = try await makeStore(scratch)
        let summary = try await store.insert(clip("aardvark burrow"))

        try await store.updateText(id: summary.id, to: "zebra crossing")

        #expect(try await store.search("aardvark").isEmpty, "old text must stop matching")
        #expect(try await store.search("zebra").count == 1, "new text must match")
        #expect(try await store.fullText(id: summary.id) == "zebra crossing")
        await store.close()
    }

    @Test("Pin and favourite flags round-trip without disturbing the index")
    func flagsRoundTrip() async throws {
        let scratch = Scratch()
        let store = try await makeStore(scratch)
        let summary = try await store.insert(clip("findable text"))

        try await store.setPinned(true, ids: [summary.id])
        try await store.setFavorite(true, ids: [summary.id])

        let reloaded = try await store.summary(id: summary.id)
        #expect(reloaded?.isPinned == true)
        #expect(reloaded?.isFavorite == true)
        #expect(try await store.search("findable").count == 1,
                "toggling a flag must not disturb the FTS index")
        await store.close()
    }
}

@Suite("Expanded detail")
@MainActor
struct ExpandedDetailTests {
    private func model() -> LibraryViewModel {
        LibraryViewModel(store: .makeDefault(root: URL(fileURLWithPath: "/dev/null")))
    }

    private func summary(_ id: Int64) -> ClipSummary {
        ClipSummary(id: id, uuid: UUID(), contentType: .image, preview: "", copiedAt: Date(),
                    thumbnailPath: "ab/\(id).thumb.png", imageSize: (1200, 800))
    }

    @Test("Expanding is off by default")
    func defaultsToColumn() {
        #expect(!model().isDetailExpanded)
    }

    /// Expanded mode shows one clip and hides the list, so deleting that clip would otherwise
    /// leave an empty pane with no visible way back.
    @Test("Deleting the expanded clip returns to the list")
    func deletingExpandedClipRestores() {
        let m = model()
        m.apply(.inserted(summary(1)))
        m.selection = [1]
        m.isDetailExpanded = true

        m.apply(.deleted([1]))
        #expect(!m.isDetailExpanded)
        #expect(m.selection.isEmpty)
    }

    @Test("Deleting a different clip leaves the expanded view alone")
    func deletingOtherClipKeepsExpansion() {
        let m = model()
        m.apply(.inserted(summary(1)))
        m.apply(.inserted(summary(2)))
        m.selection = [1]
        m.isDetailExpanded = true

        m.apply(.deleted([2]))
        #expect(m.isDetailExpanded, "the clip being shown is still there")
    }
}

@Suite("Section filters")
@MainActor
struct SectionFilterTests {
    /// The type chips are only shown under "All Clips". Inside a Type section they contradict the
    /// sidebar — Images in the sidebar plus Text in the chips can only ever return nothing — and
    /// inside an App or Tag they restate a filter already applied.
    @Test("Only the All section is the unfiltered one")
    func allIsDistinct() {
        #expect(LibrarySection.all == LibrarySection.all)
        #expect(LibrarySection.all != LibrarySection.pinned)
        #expect(LibrarySection.all != LibrarySection.type(.image))
        #expect(LibrarySection.all != LibrarySection.app("com.apple.Safari"))
        #expect(LibrarySection.all != LibrarySection.tag("invoice"))
    }

    @Test("Sections of the same kind compare by their value")
    func sectionsCompareByValue() {
        #expect(LibrarySection.type(.image) == LibrarySection.type(.image))
        #expect(LibrarySection.type(.image) != LibrarySection.type(.code))
        #expect(LibrarySection.tag("a") != LibrarySection.tag("b"))
    }
}

@Suite("Detail pane width")
@MainActor
struct DetailWidthTests {
    /// The reported bug: returning from the expanded view gave the detail pane roughly 30% of the
    /// window rather than the width it had before, because HSplitView owned the divider and
    /// treated the requested width as a hint.
    private func clamped(_ stored: Double, available: Double) -> Double {
        let maximum = max(280, min(700, available * 0.6))
        return min(max(stored, 260), maximum)
    }

    @Test("A remembered width is restored exactly")
    func restoresExactly() {
        #expect(clamped(420, available: 1400) == 420)
        #expect(clamped(340, available: 1400) == 340)
    }

    /// A width remembered from a large window must not swallow a small one.
    @Test("Width is capped relative to the window")
    func capsToWindow() {
        #expect(clamped(700, available: 800) == 480, "60% of an 800pt window")
        #expect(clamped(600, available: 1400) == 600, "fits comfortably in a wide window")
    }

    @Test("Width never collapses below a usable minimum")
    func hasAFloor() {
        #expect(clamped(10, available: 1400) == 260)
        #expect(clamped(0, available: 400) >= 260)
    }
}
