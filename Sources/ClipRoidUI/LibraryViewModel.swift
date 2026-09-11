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
    public private(set) var typeCounts: [ClipContentType: Int] = [:]
    public private(set) var totalCount = 0
    public var errorMessage: String?

    private let store: ClipStore
    private var observation: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    /// One page. The whole point of `ClipSummary` over `Clip` is that this can be raised without
    /// pulling megabytes of image data into memory — but a page is still bounded, because SwiftUI
    /// diffing 10,000 rows on every capture is its own problem.
    private let pageSize = 200

    public init(store: ClipStore) {
        self.store = store
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

    public func thumbnailURL(for summary: ClipSummary) async -> URL? {
        guard let path = summary.thumbnailPath else { return nil }
        return await store.thumbnailURL(relativePath: path)
    }
}
