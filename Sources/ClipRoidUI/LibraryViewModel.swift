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

@MainActor
@Observable
public final class LibraryViewModel {
    public private(set) var clips: [ClipSummary] = []
    public private(set) var isLoadingPage = false
    public private(set) var hasMore = true

    public var layout: LibraryLayout = .timeline
    public var section: LibrarySection = .all { didSet { reloadFromScratch() } }
    public var searchText: String = "" { didSet { scheduleSearch() } }
    /// Chips are additive with the sidebar section; both narrow the same query.
    public var activeTypes: Set<ClipContentType> = [] { didSet { reloadFromScratch() } }

    public var selection: Set<Int64> = []
    public private(set) var sourceApps: [(bundleId: String, name: String, count: Int)] = []
    public private(set) var categories: [ClipCategory] = []
    public private(set) var categoryCounts: [Int64: Int] = [:]
    public private(set) var shortcuts: [String: Int64] = [:]
    public private(set) var tagCounts: [(name: String, count: Int)] = []
    public private(set) var reapplyProgress: Int?
    public private(set) var typeCounts: [ClipContentType: Int] = [:]
    public private(set) var totalCount = 0
    public var errorMessage: String?

    private let store: ClipStore
    private let coordinator: PasteCoordinator?
    private let editor: ExternalEditor?
    private var observation: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    /// One page. The whole point of `ClipSummary` over `Clip` is that this can be raised without
    /// pulling megabytes of image data into memory — but a page is still bounded, because SwiftUI
    /// diffing 10,000 rows on every capture is its own problem.
    private let pageSize = 200

    public init(store: ClipStore, coordinator: PasteCoordinator? = nil,
                editor: ExternalEditor? = nil) {
        self.store = store
        self.coordinator = coordinator
        self.editor = editor
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
            if case .category(let categoryId) = section, searchText.isEmpty, activeTypes.isEmpty {
                guard clips.isEmpty else { hasMore = false; return }
                page = try await store.clips(inCategory: categoryId, limit: 500)
                hasMore = false
                clips.append(contentsOf: page)
                return
            }
            if case .tag(let name) = section, searchText.isEmpty, activeTypes.isEmpty {
                guard clips.isEmpty else { hasMore = false; return }
                page = try await store.clips(withTag: name, limit: 500)
                hasMore = false
                clips.append(contentsOf: page)
                return
            }
            if currentQuery.isEmpty {
                page = try await store.recent(limit: pageSize, before: clips.last?.copiedAt)
            } else {
                // FTS results are ranked, not chronological, so they do not paginate on a
                // timestamp cursor. Ask for one larger page instead and stop there — a search that
                // needs more than 500 hits wants a narrower search, not more scrolling.
                guard clips.isEmpty else { hasMore = false; return }
                page = try await store.search(currentQuery, limit: 500)
            }
            if page.count < pageSize { hasMore = false }
            clips.append(contentsOf: page)
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    /// The sidebar section, the chips and the search box all fold into one query object, so there
    /// is a single code path to reason about rather than three that can disagree.
    private var currentQuery: SearchQuery {
        var query = SearchQueryParser.parse(searchText)
        query.types.formUnion(activeTypes)

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
            totalCount = max(0, totalCount - ids.count)
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
            guard let coordinator else { return }
            switch summary.contentType {
            case .image, .screenshot:
                if let path = summary.thumbnailPath {
                    let full = path.replacingOccurrences(of: ".thumb.png", with: ".png")
                    if let data = await store.imageData(forBlobPath: full) {
                        await coordinator.writeOnly(.image(data), originClipUUID: summary.uuid)
                        return
                    }
                }
                fallthrough
            default:
                let text = (try? await store.fullText(id: summary.id)) ?? summary.displayText
                await coordinator.writeOnly(
                    .text(transform?.apply(to: text) ?? text), originClipUUID: summary.uuid)
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

    public func thumbnailURL(for summary: ClipSummary) async -> URL? {
        guard let path = summary.thumbnailPath else { return nil }
        return await store.thumbnailURL(relativePath: path)
    }
}
