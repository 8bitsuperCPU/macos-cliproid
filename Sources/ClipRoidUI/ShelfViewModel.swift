import Foundation
import Observation
import ClipRoidCore
import ClipRoidKit
import ClipRoidStore
import ClipRoidPlatform

public enum ShelfPosition: String, CaseIterable, Sendable, Codable {
    case top, left, right, bottom, hidden
}

@MainActor
@Observable
public final class ShelfViewModel {
    public private(set) var clips: [ClipSummary] = []

    /// Called whenever the visible clips change.
    ///
    /// The shelf is sized to its contents, and those load asynchronously — so the panel cannot
    /// size itself once at show() time and be done. Without this the shelf is laid out for zero
    /// items and stays at its minimum width forever, which is exactly the "it never shrinks"
    /// symptom, just in the other direction.
    public var onClipsChanged: (@MainActor () -> Void)?

    /// Free-text filter for the shelf's own search field.
    public var searchText: String = "" { didSet { scheduleReload() } }
    /// nil means "All".
    public var activeCategoryId: Int64? { didSet { Task { await reload() } } }
    public var favouritesOnly = false { didSet { Task { await reload() } } }

    public private(set) var categories: [ClipCategory] = []
    public private(set) var categoryCounts: [Int64: Int] = [:]
    public var position: ShelfPosition = .top
    /// Spec §4.19 allows 5–20.
    public var itemCount: Int = 10 {
        didSet { Task { await reload() } }
    }

    private let store: ClipStore
    private let coordinator: PasteCoordinator
    private let settings: SettingsStore
    private let enrichment: EnrichmentPipeline?
    private let editor: ExternalEditor?
    private var observation: Task<Void, Never>?

    public init(store: ClipStore, coordinator: PasteCoordinator, settings: SettingsStore,
                enrichment: EnrichmentPipeline? = nil, editor: ExternalEditor? = nil) {
        self.store = store
        self.coordinator = coordinator
        self.settings = settings
        self.enrichment = enrichment
        self.editor = editor
        self.position = ShelfPosition(rawValue: settings.shelfPosition.rawValue) ?? .top
        self.itemCount = settings.shelfItemCount
    }

    /// Re-reads the preferences the Settings window may have changed.
    public func applySettings() {
        position = ShelfPosition(rawValue: settings.shelfPosition.rawValue) ?? .top
        itemCount = settings.shelfItemCount
        Task { await reload() }
    }

    public func start() {
        guard observation == nil else { return }
        Task { await reload() }
        observation = Task { [weak self] in
            guard let self else { return }
            for await _ in await store.changes() {
                // The shelf is a small fixed window onto the newest clips, so any change just
                // re-reads it. Applying deltas here would be more code for no benefit at N=10.
                await self.reload()
            }
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }

    private var searchTask: Task<Void, Never>?

    private func scheduleReload() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    public func refreshCategories() async {
        categories = (try? await store.categories()) ?? []
        categoryCounts = (try? await store.categoryCounts()) ?? [:]
    }

    private func reload() async {
        // Over-fetch, then drop secrets. Spec §4.7 keeps them off the shelf by default: the shelf
        // is always on screen, which makes it exactly the wrong place for a copied password —
        // anyone walking past sees it.
        await refreshCategories()

        let candidates: [ClipSummary]
        if let categoryId = activeCategoryId {
            candidates = (try? await store.clips(inCategory: categoryId, limit: itemCount * 4)) ?? []
        } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            var query = SearchQueryParser.parse(searchText)
            query.favoritesOnly = favouritesOnly
            candidates = (try? await store.search(query, limit: itemCount * 4)) ?? []
        } else if favouritesOnly {
            var query = SearchQuery()
            query.favoritesOnly = true
            candidates = (try? await store.search(query, limit: itemCount * 4)) ?? []
        } else {
            candidates = (try? await store.recent(limit: itemCount * 3)) ?? []
        }

        let recent = candidates
        let hideSecrets = settings.hideSecretsFromShelf
        let updated = Array(recent.lazy
            .filter { !hideSecrets || $0.sensitivity != .secret }
            .prefix(itemCount))
        let countChanged = updated.count != clips.count
        clips = updated
        // Only when the count changes: re-laying out the window on every content change would
        // make the shelf twitch every time a clip was copied.
        if countChanged { onClipsChanged?() }
    }

    public func thumbnailURL(for summary: ClipSummary) async -> URL? {
        guard let path = summary.thumbnailPath else { return nil }
        return await store.thumbnailURL(relativePath: path)
    }

    /// Capped, because a shelf preview showing a 40MB log paste helps nobody and would take a
    /// visible moment to render.
    public func fullText(for summary: ClipSummary) async -> String {
        let text = (try? await store.fullText(id: summary.id)) ?? summary.displayText
        return String(text.prefix(600))
    }

    /// Opens the Library window. Set by the app, since the model cannot reach the window itself.
    public var openLibrary: (@MainActor () -> Void)?

    /// Creates an empty note clip, ready to be edited in the Library (spec §4.15).
    public func createNote() {
        Task {
            let body = ""
            _ = try? await store.insert(CapturedClip(
                contentType: .note,
                contentHash: Dedupe.hash(UUID().uuidString),
                body: body,
                sourceAppName: "ClipRoid",
                enrichmentState: .notApplicable))
            await reload()
            openLibrary?()
        }
    }

    // MARK: - Card actions

    public func delete(_ clip: ClipSummary) {
        Task {
            try? await store.delete(ids: [clip.id])
            await reload()
        }
    }

    public func toggleFavourite(_ clip: ClipSummary) {
        Task {
            try? await store.setFavorite(!clip.isFavorite, ids: [clip.id])
            await reload()
        }
    }

    public func togglePin(_ clip: ClipSummary) {
        Task {
            try? await store.setPinned(!clip.isPinned, ids: [clip.id])
            await reload()
        }
    }

    public func assign(_ clip: ClipSummary, to category: ClipCategory) {
        Task {
            try? await store.assign(clipIds: [clip.id], toCategory: category.id)
            await reload()
        }
    }

    public func createCategory(named name: String) {
        Task {
            _ = try? await store.createCategory(name: name)
            await reload()
        }
    }

    /// OCR text already on record, without starting recognition — the preview should not kick off
    /// Vision work merely because the pointer paused over a card.
    public func existingOCRText(for clip: ClipSummary) async -> String? {
        try? await store.ocrText(forClip: clip.id)
    }

    /// Copies the text Vision recognised inside an image (spec §4.8).
    public func copyTextFromImage(_ clip: ClipSummary) {
        Task {
            guard let enrichment,
                  let text = await enrichment.recognizeTextNow(clipId: clip.id),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await coordinator.writeOnly(.text(text), originClipUUID: clip.uuid)
        }
    }

    /// Copies a colour clip in a chosen format (spec §4.13).
    public func copyColour(_ clip: ClipSummary, as format: ColorFormats) {
        guard let hex = clip.colorHex,
              let text = ColorFormats.string(format, fromHex: hex) else { return }
        Task { await coordinator.writeOnly(.text(text), originClipUUID: clip.uuid) }
    }

    /// Opens the clip in whichever app the system considers the default for its type.
    public func editExternally(_ clip: ClipSummary) {
        Task { await editor?.edit(clip) }
    }

    /// Copies without pasting — for the shelf's "copy" affordance.
    public func copyOnly(_ clip: ClipSummary) {
        Task {
            guard let text = try? await store.fullText(id: clip.id) else { return }
            await pasteboardWrite(text, uuid: clip.uuid)
        }
    }

    private func pasteboardWrite(_ text: String, uuid: UUID) async {
        await coordinator.writeOnly(.text(text), originClipUUID: uuid)
    }

    public func paste(_ clip: ClipSummary) {
        Task {
            // The shelf is clicked while another app is frontmost, so the target is whatever was
            // in front — captured now, before our own click can shift focus.
            coordinator.captureTarget()
            await coordinator.paste(clip)
        }
    }
}
