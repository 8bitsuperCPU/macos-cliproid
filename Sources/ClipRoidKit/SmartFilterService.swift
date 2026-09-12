import Foundation
import ClipRoidCore
import ClipRoidStore
import os.log

/// Applies smart filter rules, both at capture time and retroactively (spec §4.2).
public actor SmartFilterService {
    private let store: ClipStore
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "SmartFilters")

    private var cachedRules: [SmartFilterRule] = []
    private var rulesLoaded = false

    public init(store: ClipStore) {
        self.store = store
    }

    /// Rules are cached because this runs on every capture; the cache is dropped whenever the
    /// user edits a rule, so an edit takes effect on the very next clip rather than after a
    /// restart.
    public func invalidateRules() {
        rulesLoaded = false
    }

    private func rules() async -> [SmartFilterRule] {
        if !rulesLoaded {
            cachedRules = (try? await store.smartFilterRules()) ?? []
            rulesLoaded = true
        }
        return cachedRules
    }

    /// Files a freshly captured clip. Never throws into the capture path: a broken rule must not
    /// cost the user the clip.
    public func apply(toClipId id: Int64, candidate: SmartFilterEngine.Candidate) async {
        let matched = SmartFilterEngine.categoryIds(for: candidate, rules: await rules())
        guard !matched.isEmpty else { return }
        for categoryId in matched {
            try? await store.assign(clipIds: [id], toCategory: categoryId)
        }
    }

    /// Re-applies every rule across the whole history (spec §4.2).
    ///
    /// Chunked with a yield between batches so a sweep over tens of thousands of clips cannot lock
    /// the UI or monopolise the cooperative pool. Progress is reported so the user sees movement
    /// rather than a frozen sheet.
    @discardableResult
    public func reapplyToAll(
        batchSize: Int = 500,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async -> Int {
        invalidateRules()
        let rules = await rules()
        guard !rules.isEmpty else { return 0 }

        var lastId: Int64 = 0
        var assigned = 0
        var processed = 0

        while true {
            let batch = (try? await store.ruleCandidates(limit: batchSize, after: lastId)) ?? []
            if batch.isEmpty { break }

            for entry in batch {
                let matched = SmartFilterEngine.categoryIds(for: entry.candidate, rules: rules)
                for categoryId in matched {
                    try? await store.assign(clipIds: [entry.id], toCategory: categoryId)
                    assigned += 1
                }
                lastId = max(lastId, entry.id)
            }
            processed += batch.count
            progress?(processed)
            await Task.yield()
        }

        logger.info("Retroactive smart filters made \(assigned) assignment(s) over \(processed) clip(s)")
        return assigned
    }
}
