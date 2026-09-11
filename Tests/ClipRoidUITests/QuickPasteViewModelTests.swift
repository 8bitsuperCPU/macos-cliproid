import Testing
import Foundation
@testable import ClipRoidUI
import ClipRoidCore
import ClipRoidKit
import ClipRoidStore
import ClipRoidPlatform

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
