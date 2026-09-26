import Foundation
import Observation
import ClipRoidCore
import ClipRoidKit
import ClipRoidStore

public enum LibraryLayout: String, CaseIterable, Sendable {
    case timeline, grid, list

    public var symbolName: String {
        switch self {
        case .timeline: "list.bullet.indent"
        case .grid: "square.grid.2x2"
        case .list: "list.dash"
        }
    }
}

/// What the sidebar is currently showing.
public enum LibrarySection: Hashable, Sendable {
    case all
    case pinned
    case favorites
    case type(ClipContentType)
    case app(String)
    case category(Int64)
    case tag(String)
}

extension LibrarySection {
    /// A flat string, so the sidebar selection survives a restart.
    ///
    /// Hand-rolled rather than `Codable` because the associated values are already strings and
    /// integers: one line to write, one to read, and nothing to migrate when a case is added.
    /// The separator is ":" and app bundle ids and tag names may contain it, so the payload is
    /// everything after the *first* one.
    var storageKey: String {
        switch self {
        case .all: "all"
        case .pinned: "pinned"
        case .favorites: "favorites"
        case .type(let t): "type:\(t.rawValue)"
        case .app(let id): "app:\(id)"
        case .category(let id): "category:\(id)"
        case .tag(let name): "tag:\(name)"
        }
    }

    init?(storageKey: String) {
        let head = storageKey.prefix { $0 != ":" }
        let tail = String(storageKey.dropFirst(head.count + 1))
        switch head {
        case "all": self = .all
        case "pinned": self = .pinned
        case "favorites": self = .favorites
        case "type":
            guard let raw = Int(tail), let t = ClipContentType(rawValue: raw) else { return nil }
            self = .type(t)
        case "app":
            guard !tail.isEmpty else { return nil }
            self = .app(tail)
        case "category":
            guard let id = Int64(tail) else { return nil }
            self = .category(id)
        case "tag":
            guard !tail.isEmpty else { return nil }
            self = .tag(tail)
        default: return nil
        }
    }
}

@MainActor
@Observable
public final class LibraryViewModel {
    /// Suppresses the property observers while the initialiser restores saved filters.
    ///
    /// Each restored assignment would otherwise write the value straight back to settings and
    /// kick off a reload — against a store that has not been opened yet, since the environment
    /// opens it after the view models are built.
    private var isRestoring = true

    public private(set) var clips: [ClipSummary] = []
    public private(set) var isLoadingPage = false
    public private(set) var hasMore = true

    public var layout: LibraryLayout = .grid {
        didSet { settings?.libraryLayout = layout.rawValue }
    }
    /// Tile width in the grid, remembered across launches.
    public var tileSize: Double = 150 {
        didSet { settings?.tileSize = tileSize }
    }
    public var section: LibrarySection = .all {
        didSet {
            guard !isRestoring, section != oldValue else { return }
            settings?.librarySection = section.storageKey
            reloadFromScratch()
        }
    }
    public var searchText: String = "" { didSet { scheduleSearch() } }
    /// Chips are additive with the sidebar section; both narrow the same query.
    public var activeTypes: Set<ClipContentType> = [] {
        didSet {
            guard !isRestoring, activeTypes != oldValue else { return }
            settings?.libraryTypes = activeTypes.map(\.rawValue).sorted()
            reloadFromScratch()
        }
    }
    /// Remembered across launches, like the layout and tile size.
    public var sort: ClipSort = .automatic {
        didSet {
            guard !isRestoring, sort != oldValue else { return }
            settings?.librarySort = sort.rawValue
            reloadFromScratch()
        }
    }

    public var selection: Set<Int64> = []
    /// The keyboard cursor: the clip the arrow keys are currently on.
    ///
    /// Distinct from `selection` because they diverge under shift-extension — the cursor is the
    /// moving end of the range while the anchor stays put — and because a selection made with the
    /// mouse still needs somewhere for the first arrow key to start from.
    public var focusedId: Int64?
    /// The fixed end of a shift-extended range.
    private var selectionAnchor: Int64?
    /// How many columns the grid is showing, so up and down move by a row rather than an item.
    ///
    /// Set by the grid from its measured width; row layouts leave it at 1.
    public var gridColumnCount: Int = 1
    /// Clips awaiting the user's confirmation to delete. Non-nil presents the alert.
    public var pendingDelete: [ClipSummary]?
    /// When true the detail pane takes the whole window instead of the right-hand column.
    public var isDetailExpanded = false
    public private(set) var sourceApps: [ClipStore.SourceApp] = []
    public private(set) var categories: [ClipCategory] = []
    public private(set) var categoryCounts: [Int64: Int] = [:]
    public private(set) var shortcuts: [String: Int64] = [:]
    public private(set) var tagCounts: [ClipStore.TagCount] = []
    public private(set) var reapplyProgress: Int?
    public private(set) var typeCounts: [ClipContentType: Int] = [:]
    public private(set) var totalCount = 0
    public var errorMessage: String?

    private let store: ClipStore
    private let coordinator: PasteCoordinator?
    private let editor: ExternalEditor?
    private let enrichment: EnrichmentPipeline?
    private let settings: SettingsStore?
    private var observation: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    /// One page. The whole point of `ClipSummary` over `Clip` is that this can be raised without
    /// pulling megabytes of image data into memory — but a page is still bounded, because SwiftUI
    /// diffing 10,000 rows on every capture is its own problem.
    private let pageSize = 200

    public init(store: ClipStore, coordinator: PasteCoordinator? = nil,
                editor: ExternalEditor? = nil, enrichment: EnrichmentPipeline? = nil,
                settings: SettingsStore? = nil) {
        self.store = store
        self.coordinator = coordinator
        self.editor = editor
        self.enrichment = enrichment
        self.settings = settings
        if let settings {
            self.layout = LibraryLayout(rawValue: settings.libraryLayout) ?? .grid
            self.tileSize = settings.tileSize
            self.sort = ClipSort(rawValue: settings.librarySort) ?? .automatic
            // Restored before `start()`, so the first load already carries the filters rather
            // than fetching an unfiltered page and replacing it a moment later.
            self.section = LibrarySection(storageKey: settings.librarySection) ?? .all
            self.activeTypes = Set(settings.libraryTypes.compactMap(ClipContentType.init(rawValue:)))
        }
        isRestoring = false
    }

    public var selectedClips: [ClipSummary] {
        clips.filter { selection.contains($0.id) }
    }

    public var singleSelection: ClipSummary? {
        selection.count == 1 ? clips.first { selection.contains($0.id) } : nil
    }

    public func start() {
        guard observation == nil else { return }
        reloadFromScratch()
        observation = Task { [weak self] in
            guard let self else { return }
            for await change in await store.changes() {
                self.apply(change)
            }
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }

    // MARK: - Loading

    private func reloadFromScratch() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            self.clips = []
            self.hasMore = true
            await self.loadNextPage()
            await self.refreshFacets()
        }
    }

    /// Called from the view when the last row appears. Cursor-based on `copied_at`, not OFFSET:
    /// OFFSET makes the database walk and discard every skipped row, so page 50 costs fifty times
    /// page 1. A cursor is a single index seek however deep the scroll goes.
    public func loadNextPage() async {
        guard !isLoadingPage, hasMore else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let page: [ClipSummary]
            // A category is a join against clip_categories rather than a column predicate, so it
            // cannot fold into SearchQuery the way the other facets do.
            if case .category(let categoryId) = section, searchText.isEmpty {
                guard clips.isEmpty else { hasMore = false; return }
                page = try await store.clips(inCategory: categoryId, limit: 500)
                hasMore = false
                clips.append(contentsOf: page)
                return
            }
            if case .tag(let name) = section, searchText.isEmpty {
                guard clips.isEmpty else { hasMore = false; return }
                page = try await store.clips(withTag: name, limit: 500)
                hasMore = false
                clips.append(contentsOf: page)
                return
            }
            // Only newest-first can be paged on a timestamp cursor: "everything older than my
            // last row" means nothing once rows are ordered by size, type or app. The others are
            // served as one bounded page, which is no loss — whatever the user sorted for is at
            // the top of it.
            if currentQuery.isEmpty, sort.supportsTimestampCursor {
                page = try await store.recent(
                    limit: pageSize, before: clips.last?.copiedAt, sort: sort)
            } else if currentQuery.isEmpty {
                guard clips.isEmpty else { hasMore = false; return }
                page = try await store.recent(limit: 500, sort: sort)
                hasMore = false
                clips.append(contentsOf: page)
                return
            } else {
                // FTS results are ranked, not chronological, so they do not paginate on a
                // timestamp cursor. Ask for one larger page instead and stop there — a search that
                // needs more than 500 hits wants a narrower search, not more scrolling.
                guard clips.isEmpty else { hasMore = false; return }
                page = try await store.search(currentQuery, limit: 500, sort: sort)
            }
            if page.count < pageSize { hasMore = false }
            clips.append(contentsOf: page)
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    /// The chips are only shown under All Clips, so only there do they filter. Applying them
    /// elsewhere made a remembered Images chip invisibly add images to every Type section, and
    /// silently dropped the category or tag join. They are kept, not cleared, so returning to All
    /// Clips brings them back.
    private var effectiveTypes: Set<ClipContentType> {
        section == .all ? activeTypes : []
    }

    /// The sidebar section, the chips and the search box all fold into one query object, so there
    /// is a single code path to reason about rather than three that can disagree.
    private var currentQuery: SearchQuery {
        var query = SearchQueryParser.parse(searchText)
        query.types.formUnion(effectiveTypes)

        switch section {
        case .all: break
        case .pinned: query.pinnedOnly = true
        case .favorites: query.favoritesOnly = true
        case .type(let type): query.types.insert(type)
        case .app(let bundleId): query.appTerms.insert(bundleId)
        case .category, .tag: break  // joins, not column predicates — handled separately
        }
        return query
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reloadFromScratch()
        }
    }

    private func refreshFacets() async {
        sourceApps = (try? await store.sourceApps()) ?? []
        categories = (try? await store.categories()) ?? []
        categoryCounts = (try? await store.categoryCounts()) ?? [:]
        shortcuts = (try? await store.shortcuts()) ?? [:]
        tagCounts = (try? await store.tagCounts()) ?? []
        typeCounts = (try? await store.typeCounts()) ?? [:]
        totalCount = (try? await store.count()) ?? 0
    }

    // MARK: - Deltas

    func apply(_ change: ClipStoreChange) {
        switch change {
        case .inserted(let summary):
            // Only prepend when the new clip actually belongs in what is being shown; otherwise a
            // clip appears in a filtered view it does not match.
            guard matchesCurrentFilters(summary) else { return }
            clips.insert(summary, at: 0)
            totalCount += 1
        case .updated(let summary):
            if let i = clips.firstIndex(where: { $0.id == summary.id }) { clips[i] = summary }
        case .promoted(let summary):
            clips.removeAll { $0.id == summary.id }
            if matchesCurrentFilters(summary) { clips.insert(summary, at: 0) }
        case .deleted(let ids):
            let set = Set(ids)
            clips.removeAll { set.contains($0.id) }
            selection.subtract(set)
            // The cursor must not be left on a clip that no longer exists, or the next arrow key
            // finds no index to move from and navigation appears dead.
            if let focusedId, set.contains(focusedId) { self.focusedId = nil }
            if let anchor = selectionAnchor, set.contains(anchor) { selectionAnchor = nil }
            totalCount = max(0, totalCount - ids.count)
            // The sidebar's type, app and tag counts are per-clip too. Without this, clearing the
            // history leaves "Images 12" beside a section that is now empty.
            Task { await refreshFacets() }
            // Expanded mode shows one clip and hides the list. Deleting that clip would leave an
            // empty pane with no visible way back to anything.
            if selection.isEmpty { isDetailExpanded = false }
        }
    }

    /// Deliberately conservative: it only checks the cheap structural filters, not the full-text
    /// term. A live capture that matches the text query but is not shown until the next reload is a
    /// far smaller problem than one that appears in a view it does not belong to.
    private func matchesCurrentFilters(_ summary: ClipSummary) -> Bool {
        let query = currentQuery
        if !query.text.isEmpty { return false }
        if !query.types.isEmpty && !query.types.contains(summary.contentType) { return false }
        if query.pinnedOnly && !summary.isPinned { return false }
        if query.favoritesOnly && !summary.isFavorite { return false }
        if !query.appTerms.isEmpty {
            let haystack = [summary.sourceAppBundleId, summary.sourceAppName]
                .compactMap { $0?.lowercased() }
            guard query.appTerms.contains(where: { term in
                haystack.contains { $0.contains(term.lowercased()) }
            }) else { return false }
        }
        return true
    }

    // MARK: - Actions

    public func delete(ids: [Int64]) {
        Task {
            do { try await store.delete(ids: ids) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    public func deleteSelection() {
        delete(ids: Array(selection))
    }

    // MARK: - Keyboard navigation and selection

    private var focusedIndex: Int? {
        guard let focusedId else { return nil }
        return clips.firstIndex { $0.id == focusedId }
    }

    /// Moves the cursor, optionally dragging a selection along with it.
    ///
    /// Returns false when the move is impossible, so the caller can leave the key unhandled
    /// rather than swallowing it at the edges of the grid.
    @discardableResult
    public func moveFocus(_ direction: GridNavigation.Direction, extending: Bool = false) -> Bool {
        guard !clips.isEmpty else { return false }

        // An arrow key with nothing focused starts at the top rather than doing nothing, which is
        // what makes the keyboard usable without touching the mouse first.
        guard let current = focusedIndex else {
            focus(clips[0], extending: false)
            return true
        }
        guard let next = GridNavigation.destination(
            from: current, count: clips.count,
            columns: layout == .grid ? gridColumnCount : 1,
            direction: direction) else { return false }

        focus(clips[next], extending: extending)
        return true
    }

    private func focus(_ clip: ClipSummary, extending: Bool) {
        focusedId = clip.id
        if extending {
            let anchor = selectionAnchor ?? clip.id
            selectionAnchor = anchor
            extendSelection(toIndexOf: clip.id, from: anchor)
        } else {
            selection = [clip.id]
            selectionAnchor = clip.id
        }
    }

    /// Plain click: the clip becomes the whole selection and the new anchor.
    public func selectOnly(_ clip: ClipSummary) {
        selection = [clip.id]
        focusedId = clip.id
        selectionAnchor = clip.id
    }

    /// Command-click: add or remove one clip without disturbing the rest.
    public func toggleSelection(_ clip: ClipSummary) {
        if selection.contains(clip.id) {
            selection.remove(clip.id)
        } else {
            selection.insert(clip.id)
        }
        focusedId = clip.id
        selectionAnchor = clip.id
    }

    /// Shift-click: select everything between the anchor and this clip.
    public func extendSelection(to clip: ClipSummary) {
        guard let anchor = selectionAnchor ?? focusedId else {
            selectOnly(clip)
            return
        }
        selectionAnchor = anchor
        focusedId = clip.id
        extendSelection(toIndexOf: clip.id, from: anchor)
    }

    private func extendSelection(toIndexOf id: Int64, from anchor: Int64) {
        guard let start = clips.firstIndex(where: { $0.id == anchor }),
              let end = clips.firstIndex(where: { $0.id == id }) else { return }
        selection = Set(GridNavigation.range(from: start, to: end).map { clips[$0].id })
    }

    /// Everything currently listed — which, with the type chips or sidebar applied, is how the
    /// user selects all images: filter to Images, then Select All.
    public func selectAll() {
        selection = Set(clips.map(\.id))
        selectionAnchor = clips.first?.id
        if focusedId == nil { focusedId = clips.first?.id }
    }

    public func clearSelection() {
        selection = []
        selectionAnchor = nil
        focusedId = nil
    }

    /// The clip the keyboard is on, falling back to a lone mouse selection.
    public var focusedClip: ClipSummary? {
        if let focusedId, let clip = clips.first(where: { $0.id == focusedId }) { return clip }
        return singleSelection
    }

    // MARK: - Delete, with confirmation

    /// Deleting is not undoable, so it asks first — and says how many, because a Delete keypress
    /// after a Select All is exactly the mistake worth catching.
    public func requestDeleteSelection() {
        let clips = selectedClips
        guard !clips.isEmpty else { return }
        pendingDelete = clips
    }

    /// Confirmation for a single clip deleted from a menu, so every delete in the Library window
    /// asks — a context-menu Delete that acted immediately while the Delete key asked first would
    /// be the more dangerous of the two.
    public func requestDelete(_ clip: ClipSummary) {
        pendingDelete = [clip]
    }

    public func confirmPendingDelete() {
        guard let pending = pendingDelete else { return }
        pendingDelete = nil
        delete(ids: pending.map(\.id))
        clearSelection()
    }

    public func cancelPendingDelete() {
        pendingDelete = nil
    }

    public func togglePin(_ summary: ClipSummary) {
        Task {
            try? await store.setPinned(!summary.isPinned, ids: [summary.id])
        }
    }

    public func toggleFavorite(_ summary: ClipSummary) {
        Task {
            try? await store.setFavorite(!summary.isFavorite, ids: [summary.id])
        }
    }

    public func setPinnedOnSelection(_ pinned: Bool) {
        let ids = Array(selection)
        Task { try? await store.setPinned(pinned, ids: ids) }
    }

    public func setFavoriteOnSelection(_ favorite: Bool) {
        let ids = Array(selection)
        Task { try? await store.setFavorite(favorite, ids: ids) }
    }

    public func fullText(for summary: ClipSummary) async -> String {
        (try? await store.fullText(id: summary.id)) ?? summary.preview
    }

    public func saveEdit(_ summary: ClipSummary, newText: String) {
        Task {
            do { try await store.updateText(id: summary.id, to: newText) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Copy and edit

    /// Puts a clip on the clipboard without pasting it anywhere.
    public func loadIntoClipboard(_ summary: ClipSummary, transform: TextCaseTransform? = nil) {
        Task {
            guard let coordinator,
                  let payload = await coordinator.clipboardPayload(for: summary) else { return }
            // A case transform only means anything for text. Applying it by rebuilding the
            // payload as text is what turned a copied file into its own path.
            let final: PasteboardPayload
            if let transform, case .text(let text) = payload {
                final = .text(transform.apply(to: text))
            } else {
                final = payload
            }
            await coordinator.writeOnly(final, originClipUUID: summary.uuid)
        }
    }

    /// Full-size image bytes, for the detail panel's eyedropper.
    public func imageData(for summary: ClipSummary) async -> Data? {
        guard let path = summary.thumbnailPath else { return nil }
        // The full-size blob, not the thumbnail: sampling a 256px preview of a 3000px screenshot
        // would report the colour of a blended pixel rather than the one the user clicked.
        let full = path.replacingOccurrences(of: ".thumb.png", with: ".png")
        return await store.imageData(forBlobPath: full)
    }

    public func copySampledColour(_ text: String) {
        Task { await coordinator?.writeOnly(.text(text), originClipUUID: nil) }
    }

    /// Records a colour picked out of an image as a clip of its own.
    ///
    /// Writing the hex to the pasteboard is not enough to get a tile: ClipDroid suppresses its
    /// own writes, deliberately, or every paste would echo back as a new clip. So a sampled
    /// colour has to be inserted directly, which also means it keeps `colorHex` as real metadata
    /// rather than relying on the classifier to recognise the text later.
    ///
    /// Attributed to ClipDroid rather than to the app the image came from: the colour was made
    /// here, and claiming Safari copied it would be a lie the source filter would then act on.
    public func saveSampledColour(_ hex: String, sampledFrom source: ClipSummary?) {
        Task {
            let clip = ColorClip.captured(
                hex: hex,
                origin: source?.sourceAppName.map { "Sampled from an image in \($0)" }
                    ?? "Sampled from an image",
                appBundleId: Bundle.main.bundleIdentifier,
                appName: "ClipDroid")
            do { _ = try await store.insert(clip) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    /// Text already on record, without starting recognition.
    public func existingOCRText(for summary: ClipSummary) async -> String? {
        try? await store.ocrText(forClip: summary.id)
    }

    /// Recognises text now and returns it, for the detail panel's "Find text" action.
    public func recogniseText(in summary: ClipSummary) async -> String? {
        await enrichment?.recognizeTextNow(clipId: summary.id)
    }

    /// Copies the text Vision recognised inside an image (spec §4.8).
    ///
    /// Falls back to recognising it on demand, because a screenshot taken seconds ago may not have
    /// reached the enrichment queue yet — and telling the user "no text found" when the real answer
    /// is "not yet" would be wrong.
    public func copyTextFromImage(_ summary: ClipSummary) {
        Task {
            guard let enrichment, let coordinator else { return }
            guard let text = await enrichment.recognizeTextNow(clipId: summary.id),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "No text was found in that image."
                return
            }
            await coordinator.writeOnly(.text(text), originClipUUID: summary.uuid)
            // The row's summary now carries text it did not before, so republish it: the detail
            // panel is bound to the summary, not to the database.
            if let refreshed = try? await store.summary(id: summary.id) {
                apply(.updated(refreshed))
            }
        }
    }

    /// Copies a colour clip in a chosen format (spec §4.13).
    public func loadColour(_ summary: ClipSummary, as format: ColorFormats) {
        guard let hex = summary.colorHex,
              let text = ColorFormats.string(format, fromHex: hex) else { return }
        Task { await coordinator?.writeOnly(.text(text), originClipUUID: summary.uuid) }
    }

    /// Opens the clip in whichever app the system considers the default for its type.
    public func editExternally(_ summary: ClipSummary) {
        Task {
            guard let editor else { return }
            let result = await editor.edit(summary)
            switch result {
            case .opened, .openedOriginal:
                break
            case .unsupported(let reason):
                errorMessage = reason
            case .failed(let message):
                errorMessage = message
            }
        }
    }

    // MARK: - Categories and shortcuts

    public func createCategory(named name: String) {
        Task {
            _ = try? await store.createCategory(name: name)
            await refreshFacets()
        }
    }

    public func deleteCategory(_ category: ClipCategory) {
        Task {
            try? await store.deleteCategory(id: category.id)
            if section == .category(category.id) { section = .all }
            await refreshFacets()
        }
    }

    public func assignSelection(to category: ClipCategory) {
        let ids = Array(selection)
        Task {
            try? await store.assign(clipIds: ids, toCategory: category.id)
            await refreshFacets()
        }
    }

    public func categoryIds(for summary: ClipSummary) async -> Set<Int64> {
        (try? await store.categoryIds(forClip: summary.id)) ?? []
    }

    public func toggleCategory(_ category: ClipCategory, on summary: ClipSummary) async {
        let current = await categoryIds(for: summary)
        if current.contains(category.id) {
            try? await store.unassign(clipIds: [summary.id], fromCategory: category.id)
        } else {
            try? await store.assign(clipIds: [summary.id], toCategory: category.id)
        }
        await refreshFacets()
    }

    /// Returns a validation error, or nil when the shortcut was saved.
    public func setShortcut(_ shortcut: String?, on summary: ClipSummary, prefix: Character) async -> String? {
        guard let shortcut, !shortcut.isEmpty else {
            try? await store.setShortcut(nil, id: summary.id)
            await refreshFacets()
            return nil
        }
        if let error = ShortcutMatcher.validationError(
            shortcut: shortcut, prefix: prefix, existing: shortcuts, assigningTo: summary.id) {
            return error
        }
        do {
            try await store.setShortcut(shortcut, id: summary.id)
        } catch {
            // The unique partial index is the real guard against two clips claiming one shortcut;
            // the check above is only the friendly version of it.
            return "That shortcut is already in use."
        }
        await refreshFacets()
        return nil
    }

    // MARK: - Tags

    public func tags(for summary: ClipSummary) async -> [String] {
        (try? await store.tags(forClip: summary.id)) ?? []
    }

    public func addTag(_ name: String, to summary: ClipSummary) async {
        try? await store.addTags([name], toClip: summary.id)
        await refreshFacets()
    }

    public func removeTag(_ name: String, from summary: ClipSummary) async {
        try? await store.removeTag(name, fromClip: summary.id)
        await refreshFacets()
    }

    /// The full-resolution image, for previews large enough that a thumbnail would visibly blur.
    public func fullImageURL(for summary: ClipSummary) async -> URL? {
        (try? await store.fullImageURL(forClip: summary.id)) ?? nil
    }

    public func thumbnailURL(for summary: ClipSummary) async -> URL? {
        guard let path = summary.thumbnailPath else { return nil }
        return await store.thumbnailURL(relativePath: path)
    }
}
