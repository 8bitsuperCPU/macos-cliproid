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
    /// Suppresses the property observers while the initialiser restores saved filters.
    ///
    /// Each restored assignment would otherwise write the value straight back to settings and
    /// kick off a reload — against a store that has not been opened yet, since the environment
    /// opens it after the view models are built.
    private var isRestoring = true

    public private(set) var clips: [ClipSummary] = []

    /// Called whenever the visible clips change.
    ///
    /// The shelf is sized to its contents, and those load asynchronously — so the panel cannot
    /// size itself once at show() time and be done. Without this the shelf is laid out for zero
    /// items and stays at its minimum width forever, which is exactly the "it never shrinks"
    /// symptom, just in the other direction.
    public var onClipsChanged: (@MainActor () -> Void)?

    /// True while a hover preview is on screen.
    ///
    /// The shelf must not collapse while one is open. A preview is an NSPopover anchored to a
    /// card, so collapsing tears down the hosting view, the card goes with it, and the popover is
    /// destroyed — no matter what the close delay is set to. That is why a 10-second preview
    /// vanished in about a second: the collapse timer, not the preview timer, was ending it.
    public var isPreviewOpen: Bool { previewClipId != nil }

    /// The one clip whose hover preview is open, or nil.
    ///
    /// Held here rather than as a `showPreview` flag on each card. Per-card flags meant the card
    /// you left stayed presented for the whole close delay while the card you arrived at presented
    /// too — two popovers presented at once, of which the later in the view tree wins. Cards run
    /// newest-first, left to right, so moving right happened to land on the winner and moving left
    /// reverted to the card just left. One owner makes that race impossible rather than merely
    /// unlikely.
    public var previewClipId: Int64?

    /// Opens `id`'s preview, taking ownership from whichever card held it.
    ///
    /// One assignment both presents this preview and dismisses the previous one, so there is no
    /// window in which two are presented and the view tree decides which wins.
    public func openPreview(for id: Int64) {
        previewClipId = id
    }

    /// Closes the preview only if `id` still owns it.
    ///
    /// The ownership check is the point. Leaving a card schedules a close that fires seconds
    /// later, by which time the pointer may have moved on and another card may own the preview —
    /// an unconditional close would then tear down the preview the user is actually looking at.
    public func closePreview(ifOwnedBy id: Int64) {
        if previewClipId == id { previewClipId = nil }
    }

    /// Free-text filter for the shelf's own search field.
    public var searchText: String = "" { didSet { scheduleReload() } }
    /// nil means "All".
    public var activeCategoryId: Int64? {
        didSet {
            guard !isRestoring, activeCategoryId != oldValue else { return }
            settings.shelfCategoryId = activeCategoryId ?? -1
            Task { await reload() }
        }
    }
    public var favouritesOnly = false {
        didSet {
            guard !isRestoring, favouritesOnly != oldValue else { return }
            settings.shelfFavouritesOnly = favouritesOnly
            Task { await reload() }
        }
    }
    /// Content-type chips, matching the Library's. Additive with the category and favourites
    /// filters — all three narrow the same query rather than replacing one another.
    public var activeTypes: Set<ClipContentType> = [] {
        didSet {
            guard !isRestoring, activeTypes != oldValue else { return }
            settings.shelfTypes = activeTypes.map(\.rawValue).sorted()
            Task { await reload() }
        }
    }
    /// Which types actually exist, so the shelf only offers chips that can match something.
    public private(set) var availableTypes: [ClipContentType] = []

    public private(set) var categories: [ClipCategory] = []
    public private(set) var categoryCounts: [Int64: Int] = [:]
    public var position: ShelfPosition = .top
    /// Spec §4.19 allows 5–20.
    /// How many clips the strip holds, against `itemCount` which is how many it *shows*.
    ///
    /// The shelf is sized to fit exactly `itemCount` cards, so with the two equal the scroll view
    /// had no overflow and swiping it did nothing — there was simply nothing to scroll. Holding
    /// more than fits is what gives the trackpad and Magic Mouse something to move through, and
    /// the extra rows were already being fetched and discarded.
    var scrollDepth: Int { max(itemCount * 3, itemCount) }

    /// How many cards the shelf is wide enough to show at once.
    public var visibleCardCount: Int { min(clips.count, itemCount) }

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
        // Restored before the first reload, so the shelf opens already filtered rather than
        // showing everything and then visibly narrowing.
        self.activeTypes = Set(settings.shelfTypes.compactMap(ClipContentType.init(rawValue:)))
        self.favouritesOnly = settings.shelfFavouritesOnly
        self.activeCategoryId = settings.shelfCategoryId >= 0 ? settings.shelfCategoryId : nil
        isRestoring = false
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

    public private(set) var typeCounts: [ClipContentType: Int] = [:]

    public func refreshCategories() async {
        categories = (try? await store.categories()) ?? []
        categoryCounts = (try? await store.categoryCounts()) ?? [:]
        typeCounts = (try? await store.typeCounts()) ?? [:]
    }

    private func reload() async {
        // Over-fetch, then drop secrets. Spec §4.7 keeps them off the shelf by default: the shelf
        // is always on screen, which makes it exactly the wrong place for a copied password —
        // anyone walking past sees it.
        await refreshCategories()

        availableTypes = ClipContentType.allCases.filter { (typeCounts[$0] ?? 0) > 0 }

        let candidates: [ClipSummary]
        if let categoryId = activeCategoryId {
            // A category is a join, not a column predicate, so the type chips are applied after
            // the fetch rather than folded into the query.
            let all = (try? await store.clips(inCategory: categoryId, limit: itemCount * 6)) ?? []
            candidates = activeTypes.isEmpty ? all : all.filter { activeTypes.contains($0.contentType) }
        } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            var query = SearchQueryParser.parse(searchText)
            query.favoritesOnly = favouritesOnly
            query.types.formUnion(activeTypes)
            candidates = (try? await store.search(query, limit: itemCount * 4)) ?? []
        } else if favouritesOnly || !activeTypes.isEmpty {
            var query = SearchQuery()
            query.favoritesOnly = favouritesOnly
            query.types = activeTypes
            candidates = (try? await store.search(query, limit: itemCount * 4)) ?? []
        } else {
            candidates = (try? await store.recent(limit: itemCount * 3)) ?? []
        }

        let recent = candidates
        let hideSecrets = settings.hideSecretsFromShelf
        let updated = Array(recent.lazy
            .filter { !hideSecrets || $0.sensitivity != .secret }
            .prefix(scrollDepth))
        // The panel is sized from the visible count, not the buffer, so a deeper buffer must not
        // make it re-lay out — that is the twitch this guard exists to prevent.
        let countChanged = min(updated.count, itemCount) != visibleCardCount
        clips = updated
        // Only when the count changes: re-laying out the window on every content change would
        // make the shelf twitch every time a clip was copied.
        if countChanged { onClipsChanged?() }
    }

    /// The full-resolution image, for previews large enough that a thumbnail would visibly blur.
    public func fullImageURL(for summary: ClipSummary) async -> URL? {
        (try? await store.fullImageURL(forClip: summary.id)) ?? nil
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
                sourceAppName: "ClipDroid",
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
