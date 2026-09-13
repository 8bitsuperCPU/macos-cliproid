import Testing
import Foundation
@testable import ClipRoidUI
import ClipRoidCore
import ClipRoidKit
import ClipRoidStore
import ClipRoidPlatform

/// Filters the user left applied are part of "how I left the app", like the window size. Reopening
/// unfiltered when they left it showing only images is the app forgetting what it was told.
@Suite("Restored state")
@MainActor
struct RestoredStateTests {

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ClipRoidRestoreTests-\(UUID().uuidString)")!
    }

    private func makeStore() async throws -> ClipStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ClipStore.makeDefault(root: dir)
        try await store.open(backupDirectory: nil)
        return store
    }

    private func makeShelf(_ store: ClipStore, _ settings: SettingsStore) async -> ShelfViewModel {
        let coordinator = PasteCoordinator(
            store: store, pasteboard: await SystemPasteboard(),
            deliverer: PasteDeliverer(), frontmost: WorkspaceFrontmostAppProvider())
        return ShelfViewModel(store: store, coordinator: coordinator, settings: settings)
    }

    /// The case from the report: filter the shelf to images, quit, come back to images.
    @Test("The shelf reopens with the type filter it was left on")
    func shelfTypeFilterSurvivesRestart() async throws {
        let store = try await makeStore()
        let defaults = scratchDefaults()

        let first = await makeShelf(store, SettingsStore(defaults: defaults))
        first.activeTypes = [.image]

        // A fresh model over the same defaults is what the next launch builds.
        let second = await makeShelf(store, SettingsStore(defaults: defaults))
        #expect(second.activeTypes == [.image])
        await store.close()
    }

    @Test("The shelf reopens with its collection and favourites filters")
    func shelfOtherFiltersSurvive() async throws {
        let store = try await makeStore()
        let defaults = scratchDefaults()

        let first = await makeShelf(store, SettingsStore(defaults: defaults))
        first.favouritesOnly = true
        first.activeCategoryId = 42

        let second = await makeShelf(store, SettingsStore(defaults: defaults))
        #expect(second.favouritesOnly)
        #expect(second.activeCategoryId == 42)
        await store.close()
    }

    /// Clearing a filter has to persist as reliably as setting one, or the app reopens filtered
    /// after the user deliberately cleared it — the more annoying half of the bug.
    @Test("Clearing the shelf filters persists too")
    func shelfClearedFiltersPersist() async throws {
        let store = try await makeStore()
        let defaults = scratchDefaults()

        let first = await makeShelf(store, SettingsStore(defaults: defaults))
        first.activeTypes = [.image]
        first.activeCategoryId = 7
        first.activeTypes = []
        first.activeCategoryId = nil

        let second = await makeShelf(store, SettingsStore(defaults: defaults))
        #expect(second.activeTypes.isEmpty)
        #expect(second.activeCategoryId == nil)
        await store.close()
    }

    @Test("The Library reopens with its section, chips and sort")
    func librarySurvivesRestart() async throws {
        let store = try await makeStore()
        let defaults = scratchDefaults()

        let first = LibraryViewModel(store: store, settings: SettingsStore(defaults: defaults))
        first.section = .app("com.apple.Safari")
        first.activeTypes = [.image, .link]
        first.sort = .largest

        let second = LibraryViewModel(store: store, settings: SettingsStore(defaults: defaults))
        #expect(second.section == .app("com.apple.Safari"))
        #expect(second.activeTypes == [.image, .link])
        #expect(second.sort == .largest)
        await store.close()
    }

    /// Every case has to survive, including the ones carrying an associated value — a section
    /// that fails to decode silently drops the user back to "All".
    @Test("Every sidebar section round-trips through storage", arguments: [
        LibrarySection.all, .pinned, .favorites,
        .type(.screenshot), .app("com.apple.dt.Xcode"), .category(99), .tag("design"),
    ])
    func sectionRoundTrips(_ section: LibrarySection) {
        #expect(LibrarySection(storageKey: section.storageKey) == section)
    }

    /// Bundle ids and tag names contain dots and can contain colons, so the payload is everything
    /// after the *first* separator rather than a naive split.
    @Test("Sections survive payloads containing the separator")
    func sectionHandlesColons() {
        let tag = LibrarySection.tag("a:b:c")
        #expect(LibrarySection(storageKey: tag.storageKey) == tag)
    }

    /// A preference file from an older or hand-edited build must not crash or mis-select.
    @Test("Unreadable stored state falls back rather than failing")
    func garbageFallsBack() async throws {
        #expect(LibrarySection(storageKey: "nonsense") == nil)
        #expect(LibrarySection(storageKey: "type:9999") == nil)
        #expect(LibrarySection(storageKey: "category:not-a-number") == nil)

        let store = try await makeStore()
        let defaults = scratchDefaults()
        defaults.set("nonsense", forKey: "library.section")
        defaults.set([999, 1], forKey: "library.types")

        let model = LibraryViewModel(store: store, settings: SettingsStore(defaults: defaults))
        #expect(model.section == .all, "an unreadable section falls back to All")
        #expect(model.activeTypes == [.text], "the unknown type is dropped, the valid one kept")
        await store.close()
    }

    /// Restoring must not look like a user edit: the observers would write back and, worse, drive
    /// a reload against a store the environment has not opened yet.
    @Test("Restoring does not fire a reload")
    func restoreIsSilent() async throws {
        let store = try await makeStore()
        let defaults = scratchDefaults()
        defaults.set([3], forKey: "shelf.types")

        let shelf = await makeShelf(store, SettingsStore(defaults: defaults))
        #expect(shelf.activeTypes == [.image])
        // Nothing was loaded, because nothing asked it to — `start()` does that.
        #expect(shelf.clips.isEmpty)
        await store.close()
    }
}
