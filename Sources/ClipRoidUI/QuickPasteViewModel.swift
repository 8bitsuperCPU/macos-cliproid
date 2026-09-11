import Foundation
import Observation
import ClipRoidCore
import ClipRoidKit
import ClipRoidStore
import ClipRoidPlatform

@MainActor
@Observable
public final class QuickPasteViewModel {
    public var queryText: String = "" {
        didSet { scheduleSearch() }
    }
    public private(set) var results: [ClipSummary] = []
    public var selectedIndex: Int = 0
    /// Set briefly after a clipboard-only paste, to tell the user to press ⌘V themselves.
    public private(set) var hudMessage: String?

    /// Bumped every time the panel opens, so the view can move focus back to the search field.
    ///
    /// `.onAppear` is not enough: the hosting view is created once and reused for the life of the
    /// panel, so it fires on the first show and never again. Without this the second and every
    /// subsequent Ctrl+Cmd+V opens a panel whose search field cannot be typed into — the window is
    /// key, but the panel itself is first responder.
    public private(set) var focusNonce: Int = 0

    private let store: ClipStore
    private let coordinator: PasteCoordinator
    private var searchTask: Task<Void, Never>?

    public init(store: ClipStore, coordinator: PasteCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    public var selectedClip: ClipSummary? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Called each time the panel opens. Resets rather than reusing state, because a stale query
    /// from ten minutes ago is never what the user wants to see.
    public func prepare() {
        queryText = ""
        selectedIndex = 0
        hudMessage = nil
        focusNonce &+= 1
        Task { await loadRecent() }
    }

    private func loadRecent() async {
        results = (try? await store.recent(limit: 50)) ?? []
        selectedIndex = 0
    }

    /// Debounced, because this runs on every keystroke. 120ms is below the threshold where typing
    /// feels laggy but high enough that a fast typist does not trigger a query per character.
    private func scheduleSearch() {
        searchTask?.cancel()
        let text = queryText
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            await loadRecent()
            return
        }
        let query = SearchQueryParser.parse(text)
        let found = (try? await store.search(query, limit: 50)) ?? []
        guard !Task.isCancelled else { return }
        results = found
        selectedIndex = 0
    }

    // MARK: - Keyboard navigation

    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    /// Spec §4.4 "Quick Paste": Enter pastes the selection immediately, no confirmation.
    public func pasteSelection() async -> PasteOutcome? {
        guard let clip = selectedClip else { return nil }
        let outcome = await coordinator.paste(clip)
        switch outcome {
        case .pasted:
            hudMessage = nil
        case .clipboardOnly(let reason):
            hudMessage = Self.message(for: reason)
        }
        return outcome
    }

    static func message(for reason: ClipboardOnlyReason) -> String {
        switch reason {
        case .accessibilityNotGranted: "Copied — press ⌘V to paste"
        case .noTargetApp: "Copied to the clipboard"
        case .keyboardLayoutUnresolvable: "Copied — press ⌘V to paste"
        case .appOnDenyList: "Copied — press ⌘V to paste"
        }
    }
}
