import Foundation
import ClipRoidCore
import ClipRoidStore
import ClipRoidPlatform
import os.log

/// Orchestrates a paste: capture the target, write the pasteboard, deliver.
///
/// Deliberately the only place that sequence lives, because its ordering constraints are subtle and
/// each one was a real bug before it was written down here.
@MainActor
public final class PasteCoordinator {
    private let store: ClipStore
    private let pasteboard: SystemPasteboard
    private let deliverer: PasteDeliverer
    private let frontmost: any FrontmostAppProviding
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "PasteCoordinator")

    /// The app that owned the screen when the hotkey fired.
    ///
    /// Captured at hotkey time and held, because by the time the user has typed a search and
    /// pressed Enter the frontmost app is ClipRoid and the real target is unrecoverable.
    public private(set) var pendingTarget: SourceApp?

    public init(
        store: ClipStore, pasteboard: SystemPasteboard,
        deliverer: PasteDeliverer, frontmost: any FrontmostAppProviding
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.deliverer = deliverer
        self.frontmost = frontmost
    }

    /// Must be called from the hotkey handler **before** any ClipRoid window is shown. One frame
    /// later `frontmostApplication` is ClipRoid and the answer is useless.
    public func captureTarget() {
        pendingTarget = frontmost.frontmostApp()
    }

    /// Start of the clock for spec §13's "under three seconds" promise: hotkey press to content
    /// delivered. Measured rather than assumed, because two separate 400ms stalls have already been
    /// found in this sequence and neither was visible from the outside.
    private var hotKeyFiredAt: Date?

    public func markHotKeyFired() {
        hotKeyFiredAt = Date()
    }

    public func clearTarget() {
        pendingTarget = nil
    }

    /// Puts a clip on the pasteboard and, if permitted, delivers it to the captured target.
    @discardableResult
    public func paste(_ summary: ClipSummary) async -> PasteOutcome {
        guard let payload = await payload(for: summary) else {
            return .clipboardOnly(reason: .noTargetApp)
        }

        // Written before activation is returned, so the content is already in place when the
        // target comes forward. The receipt's change count is what stops the poller capturing this
        // write as a new clip.
        await pasteboard.write(payload, originClipUUID: summary.uuid)

        let outcome = await deliverer.deliver(to: pendingTarget)

        if let started = hotKeyFiredAt {
            let elapsed = Date().timeIntervalSince(started)
            Diagnostics.log(String(
                format: "Paste complete in %.2fs from hotkey (%@) — spec §13 budget is 3.00s",
                elapsed, String(describing: outcome)))
            hotKeyFiredAt = nil
        }
        return outcome
    }

    /// Reconstructs the payload from the store. `ClipSummary` carries only a preview, never the
    /// full content — which is what keeps a 10,000-row timeline cheap.
    private func payload(for summary: ClipSummary) async -> PasteboardPayload? {
        switch summary.contentType {
        case .image, .screenshot:
            guard let path = summary.thumbnailPath,
                  let full = await fullImage(for: summary, thumbnailPath: path) else {
                // Fall back to the preview text rather than pasting nothing at all.
                return .text(summary.preview)
            }
            return .image(full)
        default:
            let text = (try? await store.fullText(id: summary.id)) ?? summary.preview
            return .text(text)
        }
    }

    private func fullImage(for summary: ClipSummary, thumbnailPath: String) async -> Data? {
        // The thumbnail path is `<uuid>.thumb.png`; the full-resolution image is `<uuid>.png`.
        // Pasting the thumbnail would silently downgrade the user's image to 256px.
        let fullPath = thumbnailPath.replacingOccurrences(of: ".thumb.png", with: ".png")
        return await store.imageData(forBlobPath: fullPath)
    }
}
