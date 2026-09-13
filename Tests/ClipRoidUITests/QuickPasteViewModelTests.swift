import Testing
import Foundation
@testable import ClipRoidUI
import ClipRoidCore
import ClipRoidKit
import ClipRoidStore
import ClipRoidPlatform
import ClipRoidKit

final class Scratch {
    let url: URL
    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClipRoidQP-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("Quick Paste view model")
@MainActor
struct QuickPasteViewModelTests {

    private func makeModel(_ scratch: Scratch) async throws -> (QuickPasteViewModel, ClipStore) {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        let coordinator = PasteCoordinator(
            store: store, pasteboard: await SystemPasteboard(),
            deliverer: PasteDeliverer(),
            frontmost: WorkspaceFrontmostAppProvider())
        return (QuickPasteViewModel(store: store, coordinator: coordinator), store)
    }

    private func clip(_ body: String, app: String = "com.apple.Safari") -> CapturedClip {
        CapturedClip(contentType: .text, contentHash: Dedupe.hash(body + app),
                     body: body, sourceAppBundleId: app, sourceAppName: "Safari")
    }

    @Test("Selection is clamped to the result bounds")
    func clampsSelection() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        for i in 1...3 { try await store.insert(clip("clip \(i)")) }
        model.prepare()
        try await Task.sleep(for: .milliseconds(120))

        model.moveSelection(by: -5)
        #expect(model.selectedIndex == 0, "cannot move above the first result")
        model.moveSelection(by: 99)
        #expect(model.selectedIndex == model.results.count - 1, "cannot move past the last")
        await store.close()
    }

    @Test("Moving the selection with no results does not crash or go negative")
    func emptySelectionIsSafe() async throws {
        let scratch = Scratch()
        let (model, _) = try await makeModel(scratch)
        model.moveSelection(by: 1)
        model.moveSelection(by: -1)
        #expect(model.selectedIndex == 0)
        #expect(model.selectedClip == nil)
    }

    /// A stale query from ten minutes ago is never what the user wants to see when the panel opens.
    @Test("Opening the panel resets the query")
    func prepareResetsState() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        try await store.insert(clip("something"))
        model.queryText = "leftover search"
        model.selectedIndex = 3

        model.prepare()
        #expect(model.queryText.isEmpty)
        #expect(model.selectedIndex == 0)
        await store.close()
    }

    /// The clipboard-only path is not an error state — it is the zero-permission path that always
    /// works, so its message has to tell the user what to do next.
    @Test("Clipboard-only outcomes explain the next step", arguments: [
        ClipboardOnlyReason.accessibilityNotGranted,
        .keyboardLayoutUnresolvable,
        .appOnDenyList,
    ])
    func clipboardOnlyMessaging(reason: ClipboardOnlyReason) {
        #expect(QuickPasteViewModel.message(for: reason).contains("⌘V"))
    }

    @Test("Searching narrows the results, and clearing restores them")
    func searchNarrowsAndRestores() async throws {
        let scratch = Scratch()
        let (model, store) = try await makeModel(scratch)
        try await store.insert(clip("the quarterly dashboard"))
        try await store.insert(clip("unrelated note"))

        model.prepare()
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.results.count == 2)

        model.queryText = "dashboard"
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.results.count == 1)

        model.queryText = ""
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.results.count == 2)
        await store.close()
    }
}

@Suite("Shelf view model")
@MainActor
struct ShelfViewModelTests {
    private func make(_ scratch: Scratch) async throws -> (ShelfViewModel, ClipStore) {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        let coordinator = PasteCoordinator(
            store: store, pasteboard: await SystemPasteboard(),
            deliverer: PasteDeliverer(), frontmost: WorkspaceFrontmostAppProvider())
        // An isolated defaults suite, so tests never touch the developer's real preferences.
        let defaults = UserDefaults(suiteName: "ClipRoidTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        return (ShelfViewModel(store: store, coordinator: coordinator, settings: settings), store)
    }

    private func clip(_ body: String, sensitivity: Sensitivity = .none) -> CapturedClip {
        CapturedClip(contentType: .text, contentHash: Dedupe.hash(body), body: body,
                     sensitivity: sensitivity)
    }

    /// The shelf is on screen all the time, which makes it exactly the wrong place for a copied
    /// password — anyone walking past sees it. Spec §4.7 keeps secrets off it by default.
    @Test("Secrets never reach the shelf")
    func excludesSecrets() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        try await store.insert(clip("ordinary text"))
        try await store.insert(clip("AKIAIOSFODNN7EXAMPLE", sensitivity: .secret))
        try await store.insert(clip("more ordinary text"))

        model.start()
        try await Task.sleep(for: .milliseconds(250))

        #expect(model.clips.count == 2)
        #expect(!model.clips.contains { $0.sensitivity == .secret })
        await store.close()
    }

    /// `itemCount` is how many cards the shelf is *sized* to show, not how many the strip holds:
    /// it deliberately keeps more so a trackpad swipe has somewhere to go.
    @Test("The shelf shows at most the configured number of items")
    func respectsItemCount() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        for i in 1...20 { try await store.insert(clip("clip \(i)")) }

        model.itemCount = 5
        model.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.visibleCardCount == 5, "the shelf is only ever as wide as itemCount cards")
        await store.close()
    }

    /// Without spare clips beyond the visible ones the scroll view has no overflow, and swiping
    /// the shelf does nothing at all — which is exactly how this started.
    @Test("The strip holds more clips than it shows, so it can be scrolled")
    func keepsScrollableDepth() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        for i in 1...40 { try await store.insert(clip("clip \(i)")) }

        model.itemCount = 5
        model.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.clips.count > model.visibleCardCount)
        #expect(model.clips.count == model.scrollDepth)
        await store.close()
    }

    /// Moving between shelf cards showed the new clip and then reverted to the previous one —
    /// but only when moving left. Each card owned its own `showPreview` flag, and the close delay
    /// left the card just vacated still presented while the card arrived at presented too. With
    /// two popovers presented at once the later one in the view tree wins, and cards run
    /// newest-first left to right, so moving right happened to land on the winner.
    @Test("Only one clip's preview can be open at a time")
    func previewHasOneOwner() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        try await store.insert(clip("left"))
        try await store.insert(clip("right"))
        model.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.clips.count == 2)

        let newer = model.clips[0].id
        let older = model.clips[1].id

        model.openPreview(for: older)
        #expect(model.previewClipId == older)

        // Moving to the other card takes ownership in one assignment; there is no moment where
        // both are open for the view tree to arbitrate.
        model.openPreview(for: newer)
        #expect(model.previewClipId == newer)
        await store.close()
    }

    /// The half of the fix that matters most: leaving a card schedules a close that fires seconds
    /// later, by which time another card may own the preview. An unconditional close would tear
    /// down the preview the user is now looking at — the same defect in slow motion.
    @Test("A stale close does not dismiss another card's preview")
    func staleCloseIsIgnored() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        try await store.insert(clip("left"))
        try await store.insert(clip("right"))
        model.start()
        try await Task.sleep(for: .milliseconds(300))

        let newer = model.clips[0].id
        let older = model.clips[1].id

        model.openPreview(for: older)
        model.openPreview(for: newer)
        // The close scheduled when the pointer left the older card finally fires.
        model.closePreview(ifOwnedBy: older)
        #expect(model.previewClipId == newer, "the preview in front of the user survives")

        model.closePreview(ifOwnedBy: newer)
        #expect(model.previewClipId == nil, "its own close still works")
        await store.close()
    }

    /// The shelf must not collapse out from under an open preview — collapsing tears down the
    /// hosting view, and the popover is anchored to a card inside it.
    @Test("The shelf counts as busy exactly while a preview is open")
    func previewHoldsTheShelfOpen() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        try await store.insert(clip("one"))
        model.start()
        try await Task.sleep(for: .milliseconds(300))
        let id = model.clips[0].id

        #expect(!model.isPreviewOpen)
        model.openPreview(for: id)
        #expect(model.isPreviewOpen)
        model.closePreview(ifOwnedBy: id)
        #expect(!model.isPreviewOpen)
        await store.close()
    }

    /// The shelf's type chips narrow it the same way the Library's do.
    @Test("Shelf type chips filter the strip")
    func shelfTypeChips() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        for i in 1...4 { try await store.insert(clip("text \(i)")) }
        for i in 1...3 {
            try await store.insert(CapturedClip(
                contentType: .image, contentHash: Dedupe.hash("img \(i)"), body: "img \(i)"))
        }

        model.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.clips.count == 7)
        #expect(model.availableTypes.contains(.image))
        #expect(model.availableTypes.contains(.text))

        model.activeTypes = [.image]
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.clips.count == 3)
        #expect(model.clips.allSatisfy { $0.contentType == .image })

        model.activeTypes = []
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.clips.count == 7, "clearing the chips restores the whole strip")
        await store.close()
    }

    /// Offering a chip for a type the user has never copied gives them a filter that can only
    /// ever empty the shelf.
    @Test("Only types that exist are offered as chips")
    func shelfOffersOnlyPresentTypes() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        try await store.insert(clip("just text"))
        model.start()
        try await Task.sleep(for: .milliseconds(300))

        #expect(model.availableTypes == [.text])
        #expect(!model.availableTypes.contains(.image))
        await store.close()
    }

    /// Type chips and the favourites toggle both narrow the same query rather than replacing
    /// one another.
    @Test("Shelf type chips compose with the favourites filter")
    func shelfTypeChipsComposeWithFavourites() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        let plain = try await store.insert(CapturedClip(
            contentType: .image, contentHash: Dedupe.hash("plain"), body: "plain"))
        let starred = try await store.insert(CapturedClip(
            contentType: .image, contentHash: Dedupe.hash("starred"), body: "starred"))
        try await store.insert(clip("some text"))
        try await store.setFavorite(true, ids: [starred.id])
        _ = plain

        model.start()
        try await Task.sleep(for: .milliseconds(300))
        model.activeTypes = [.image]
        model.favouritesOnly = true
        try await Task.sleep(for: .milliseconds(400))

        #expect(model.clips.count == 1, "images AND favourites, not either")
        #expect(model.clips.first?.preview == "starred")
        await store.close()
    }

    /// Fewer clips than the shelf shows must not invent a scroll region or stretch the panel.
    @Test("A shelf that is not full shows exactly what there is")
    func shorterThanItemCount() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        for i in 1...3 { try await store.insert(clip("clip \(i)")) }

        model.itemCount = 10
        model.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.clips.count == 3)
        #expect(model.visibleCardCount == 3)
        await store.close()
    }

    /// Over-fetching then filtering is what stops a run of secrets emptying the shelf: with a
    /// naive "take N then filter", ten copied passwords would leave nothing showing.
    @Test("A run of secrets does not empty the shelf")
    func backfillsPastSecrets() async throws {
        let scratch = Scratch()
        let (model, store) = try await make(scratch)
        for i in 1...8 { try await store.insert(clip("old clip \(i)")) }
        for i in 1...6 { try await store.insert(clip("sk-secret\(i)aaaaaaaaaaaaaaaaaaaa", sensitivity: .secret)) }

        model.itemCount = 5
        model.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.visibleCardCount == 5, "should backfill with older non-secret clips")
        #expect(!model.clips.contains { $0.sensitivity == .secret },
                "and no secret may reach the strip, scrolled to or not")
        await store.close()
    }
}
