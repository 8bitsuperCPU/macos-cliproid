import Foundation
import Observation
import ClipRoidCore
import ClipRoidKit
import ClipRoidStore

/// Holds one page of `ClipSummary` and applies store deltas in place.
///
/// It never re-queries the timeline on capture, and it never holds image bytes. Both rules exist
/// for the same reason: spec §13 requires interactive behaviour with 10,000+ clips, and the usual
/// way that requirement is missed is a view model holding `[Clip]` with inline thumbnail `Data`.
@MainActor
@Observable
public final class TimelineViewModel {
    public private(set) var clips: [ClipSummary] = []
    public private(set) var isLoading = false
    public var errorMessage: String?

    private let store: ClipStore
    private var observation: Task<Void, Never>?
    private let pageSize = 200

    public init(store: ClipStore) {
        self.store = store
    }

    public func start() {
        guard observation == nil else { return }
        Task { await reload() }
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

    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            clips = try await store.recent(limit: pageSize)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func apply(_ change: ClipStoreChange) {
        switch change {
        case .inserted(let summary):
            clips.insert(summary, at: 0)
            if clips.count > pageSize { clips.removeLast(clips.count - pageSize) }
        case .updated(let summary):
            if let i = clips.firstIndex(where: { $0.id == summary.id }) { clips[i] = summary }
        case .promoted(let summary):
            clips.removeAll { $0.id == summary.id }
            clips.insert(summary, at: 0)
        case .deleted(let ids):
            let set = Set(ids)
            clips.removeAll { set.contains($0.id) }
        }
    }

    public func delete(_ summary: ClipSummary) {
        Task {
            do { try await store.delete(ids: [summary.id]) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
