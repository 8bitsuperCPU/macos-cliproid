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
    public var position: ShelfPosition = .top
    /// Spec §4.19 allows 5–20.
    public var itemCount: Int = 10 {
        didSet { Task { await reload() } }
    }

    private let store: ClipStore
    private let coordinator: PasteCoordinator
    private var observation: Task<Void, Never>?

    public init(store: ClipStore, coordinator: PasteCoordinator) {
        self.store = store
        self.coordinator = coordinator
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

    private func reload() async {
        // Over-fetch, then drop secrets. Spec §4.7 keeps them off the shelf by default: the shelf
        // is always on screen, which makes it exactly the wrong place for a copied password —
        // anyone walking past sees it.
        let recent = (try? await store.recent(limit: itemCount * 3)) ?? []
        clips = Array(recent.lazy.filter { $0.sensitivity != .secret }.prefix(itemCount))
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
