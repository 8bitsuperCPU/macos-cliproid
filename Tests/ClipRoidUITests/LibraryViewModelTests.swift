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

    /// The sidebar section, the chips and the search box all fold into one query, so a clip has to
    /// satisfy all three at once rather than whichever was applied last.
    @Test("Section and type chips compose")
    func sectionAndChipsCompose() async throws {
        let scratch = Scratch()
        let store = try await makeStore(scratch)
        try await store.insert(clip("safari code", type: .code, app: "com.apple.Safari"))
        try await store.insert(clip("safari text", type: .text, app: "com.apple.Safari"))
        try await store.insert(clip("xcode code", type: .code, app: "com.apple.dt.Xcode"))

        let model = LibraryViewModel(store: store)
        model.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.clips.count == 3)

        model.section = .app("com.apple.Safari")
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.clips.count == 2)

        model.activeTypes = [.code]
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.clips.count == 1, "app filter AND type chip, not either")
        #expect(model.clips.first?.preview == "safari code")
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
