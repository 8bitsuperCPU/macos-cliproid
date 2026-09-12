import AppKit
import SwiftUI
import ClipRoidCore
import ClipRoidKit

/// A pinned preview, in a window of its own.
///
/// The hover preview is an `NSPopover`, which is transient by design: it dismisses on an outside
/// click and cannot be persuaded otherwise after presentation. Clicking *inside* it did not pin it
/// either, because the preview contains selectable text and a scroll view, and those consume the
/// click before any tap gesture sees it — so "click to keep open" silently did nothing.
///
/// Pinning therefore hands the clip to a real panel that ClipRoid owns outright: it stays until
/// closed, can be moved, and several can be open at once for comparing clips side by side.
@MainActor
public final class PreviewWindowController: NSObject, NSWindowDelegate {
    public static let shared = PreviewWindowController()

    private var panels: [Int64: NSPanel] = [:]

    public func show(clip: ClipSummary, model: ShelfViewModel, settings: SettingsStore) {
        if let existing = panels[clip.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let height = screen.height * CGFloat(settings.previewHeightFraction)
        let width = min(height * 1.25, 900)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("preview-\(clip.id)")

        panel.contentView = NSHostingView(rootView:
            ShelfPreview(
                clip: clip, model: model, settings: settings,
                isPinned: true,
                onPin: {},
                onClose: { [weak self] in self?.close(clipId: clip.id) })
            .frame(maxWidth: .infinity, maxHeight: .infinity))

        // Cascade, so a second pinned preview does not land exactly on the first.
        let offset = CGFloat(panels.count) * 26
        panel.setFrameOrigin(NSPoint(
            x: screen.midX - width / 2 + offset,
            y: screen.midY - height / 2 - offset))

        panels[clip.id] = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public func close(clipId: Int64) {
        panels[clipId]?.close()
        panels[clipId] = nil
    }

    public func closeAll() {
        for (_, panel) in panels { panel.close() }
        panels.removeAll()
    }

    /// Keeps the table in step when the user closes a panel with its own close button.
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let raw = window.identifier?.rawValue,
              let id = Int64(raw.replacingOccurrences(of: "preview-", with: "")) else { return }
        panels[id] = nil
    }
}
