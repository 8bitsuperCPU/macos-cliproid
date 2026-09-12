import Testing
import Foundation
@testable import ClipRoidUI
import ClipRoidCore
import ClipRoidStore

/// Keyboard navigation and multi-select in the Library window.
@Suite("Library selection and keyboard")
@MainActor
struct LibrarySelectionTests {

    /// Six clips, newest first — so `clips[0]` is "f".
    private func makeModel(_ scratch: Scratch) async throws -> (LibraryViewModel, ClipStore) {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, body) in ["a", "b", "c", "d", "e", "f"].enumerated() {
            try await store.insert(CapturedClip(
                contentType: .text, contentHash: Dedupe.hash(body), body: body,
                copiedAt: start.addingTimeInterval(Double(i))))
        }
        let model = LibraryViewModel(store: store)
        model.start()
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.clips.count == 6)
        return (model, store)
    }

    private func bodies(_ model: LibraryViewModel) -> [String] {
        model.clips.filter { model.selection.contains($0.id) }.map(\.preview).sorted()
    }

    /// The first arrow key with nothing focused has to land somewhere, or the keyboard is unusable
    /// until the user reaches for the mouse.
    @Test("An arrow key with nothing focused starts at the first clip")
    func firstArrowFocuses() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        #expect(model.focusedId == nil)
        #expect(model.moveFocus(.down))
        #expect(model.focusedId == model.clips[0].id)
        await store.close()
    }

    @Test("Arrow keys move the cursor and carry a single selection with them")
    func arrowMovesSelection() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        model.selectOnly(model.clips[0])
        model.gridColumnCount = 3

        #expect(model.moveFocus(.right))
        #expect(model.focusedId == model.clips[1].id)
        #expect(model.selection == [model.clips[1].id])

        #expect(model.moveFocus(.down))
        #expect(model.focusedId == model.clips[4].id, "down moves by a row of three")
        await store.close()
    }

    /// Returning false leaves the key unhandled, so the press falls through instead of being
    /// silently swallowed at the edge of the grid.
    @Test("Moving past the edge reports that nothing happened")
    func edgeReportsUnhandled() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        model.selectOnly(model.clips[0])
        model.gridColumnCount = 3
        #expect(model.moveFocus(.up) == false)
        #expect(model.focusedId == model.clips[0].id, "a refused move must not shift the cursor")
        await store.close()
    }

    @Test("Shift-arrow extends the selection from a fixed anchor")
    func shiftArrowExtends() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        model.selectOnly(model.clips[1])
        model.gridColumnCount = 1

        model.moveFocus(.down, extending: true)
        model.moveFocus(.down, extending: true)
        #expect(model.selection.count == 3)
        #expect(model.focusedId == model.clips[3].id)

        // Back towards the anchor shrinks the range rather than leaving the far end selected.
        model.moveFocus(.up, extending: true)
        #expect(model.selection.count == 2)
        await store.close()
    }

    @Test("Shift-click selects the range in either direction")
    func shiftClickRange() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)

        model.selectOnly(model.clips[4])
        model.extendSelection(to: model.clips[1])
        #expect(model.selection.count == 4, "upwards from the anchor")

        model.selectOnly(model.clips[1])
        model.extendSelection(to: model.clips[4])
        #expect(model.selection.count == 4, "downwards from the anchor")
        await store.close()
    }

    @Test("Command-click adds and removes one clip at a time")
    func commandClickToggles() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        model.selectOnly(model.clips[0])
        model.toggleSelection(model.clips[2])
        model.toggleSelection(model.clips[4])
        #expect(model.selection.count == 3)

        model.toggleSelection(model.clips[2])
        #expect(model.selection.count == 2)
        #expect(!model.selection.contains(model.clips[2].id))
        await store.close()
    }

    /// Select All operates on what is listed, which is how "select all images" works: filter to
    /// Images first, then select all.
    @Test("Select All takes everything currently listed, not everything stored")
    func selectAllRespectsFilters() async throws {
        let scratch = Scratch()
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        try await store.insert(CapturedClip(
            contentType: .text, contentHash: Dedupe.hash("t"), body: "t"))
        for i in 0..<3 {
            try await store.insert(CapturedClip(
                contentType: .image, contentHash: Dedupe.hash("i\(i)"), body: "i\(i)"))
        }
        let model = LibraryViewModel(store: store)
        model.start()
        try await Task.sleep(for: .milliseconds(250))

        model.activeTypes = [.image]
        try await Task.sleep(for: .milliseconds(250))
        model.selectAll()
        #expect(model.selection.count == 3, "the text clip is filtered out, so it is not selected")
        await store.close()
    }

    /// Delete is not undoable, so the model must stage it rather than act immediately.
    @Test("Delete asks first and only removes once confirmed")
    func deleteConfirms() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        model.selectOnly(model.clips[0])
        model.toggleSelection(model.clips[1])

        model.requestDeleteSelection()
        #expect(model.pendingDelete?.count == 2)
        #expect(model.clips.count == 6, "nothing is deleted while the alert is up")

        model.cancelPendingDelete()
        #expect(model.pendingDelete == nil)
        #expect(model.clips.count == 6, "cancelling keeps every clip")

        model.selectOnly(model.clips[0])
        model.requestDeleteSelection()
        model.confirmPendingDelete()
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.clips.count == 5)
        await store.close()
    }

    @Test("An empty selection has nothing to confirm")
    func deleteNothingDoesNothing() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        model.requestDeleteSelection()
        #expect(model.pendingDelete == nil)
        await store.close()
    }

    /// Leaving the cursor on a deleted clip strands it: there is no index to move from, and the
    /// next arrow key appears to do nothing.
    @Test("Deleting the focused clip clears the cursor")
    func deleteClearsCursor() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        model.selectOnly(model.clips[2])
        model.requestDeleteSelection()
        model.confirmPendingDelete()
        try await Task.sleep(for: .milliseconds(250))

        #expect(model.focusedId == nil)
        #expect(model.moveFocus(.down), "the cursor recovers rather than staying stuck")
        await store.close()
    }

    /// Writing the hex to the pasteboard cannot produce a tile: ClipDroid suppresses its own
    /// writes, so a sampled colour has to be inserted directly.
    @Test("Sampling a colour files it as a colour clip carrying its hex")
    func sampledColourBecomesAClip() async throws {
        let scratch = Scratch()
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        let model = LibraryViewModel(store: store)
        model.start()
        try await Task.sleep(for: .milliseconds(200))

        model.saveSampledColour("#FF8800", sampledFrom: nil)
        try await Task.sleep(for: .milliseconds(300))

        let clip = try #require(model.clips.first)
        #expect(clip.contentType == .color)
        #expect(clip.colorHex == "#FF8800", "the hex is metadata, not just body text")
        #expect(clip.preview == "#FF8800")
        await store.close()
    }

    /// A colour clip must be reachable the same way any other colour is — through the Colours
    /// facet — or it is filed somewhere the user will not look.
    @Test("A sampled colour appears under the colour type filter")
    func sampledColourIsFilterable() async throws {
        let scratch = Scratch()
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        let model = LibraryViewModel(store: store)
        model.start()
        try await Task.sleep(for: .milliseconds(200))

        model.saveSampledColour("#123456", sampledFrom: nil)
        try await Task.sleep(for: .milliseconds(300))
        model.activeTypes = [.color]
        try await Task.sleep(for: .milliseconds(300))

        #expect(model.clips.count == 1)
        #expect(model.clips.first?.colorHex == "#123456")
        await store.close()
    }

    @Test("Clearing the selection also drops the cursor")
    func clearResets() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        model.selectAll()
        model.clearSelection()
        #expect(model.selection.isEmpty)
        #expect(model.focusedId == nil)
        await store.close()
    }
}
