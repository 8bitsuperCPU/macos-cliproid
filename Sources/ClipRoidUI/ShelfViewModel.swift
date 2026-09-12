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
    public var position: ShelfPosition = .top
    /// Spec §4.19 allows 5–20.
    public var itemCount: Int = 10 {
        didSet { Task { await reload() } }
    }

    private let store: ClipStore
    private let coordinator: PasteCoordinator
    private let settings: SettingsStore
    private var observation: Task<Void, Never>?

    public init(store: ClipStore, coordinator: PasteCoordinator, settings: SettingsStore) {
        self.store = store
        self.coordinator = coordinator
        self.settings = settings
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

    private func reload() async {
        // Over-fetch, then drop secrets. Spec §4.7 keeps them off the shelf by default: the shelf
        // is always on screen, which makes it exactly the wrong place for a copied password —
        // anyone walking past sees it.
        let recent = (try? await store.recent(limit: itemCount * 3)) ?? []
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

    public func paste(_ clip: ClipSummary) {
        Task {
            // The shelf is clicked while another app is frontmost, so the target is whatever was
            // in front — captured now, before our own click can shift focus.
            coordinator.captureTarget()
            await coordinator.paste(clip)
        }
    }
}
