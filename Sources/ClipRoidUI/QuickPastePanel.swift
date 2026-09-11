import AppKit
import SwiftUI
import ClipRoidCore
import ClipRoidKit
import ClipRoidCore

/// The floating Quick Paste window (spec §4.4).
///
/// `NSPanel` with `.nonactivatingPanel`, not a `Window` scene, because the panel must be able to
/// take keyboard focus **without** making ClipRoid the active application — otherwise showing it
/// destroys the very thing the paste needs, namely which app was in front.
@MainActor
public final class QuickPastePanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    /// Guards against `windowDidResignKey` firing during setup and hiding the panel before it has
    /// finished appearing.
    private var isShowing = false
    private let model: QuickPasteViewModel
    private let onDismiss: @MainActor () -> Void

    public init(model: QuickPasteViewModel, onDismiss: @escaping @MainActor () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
        super.init()
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    public func toggle() {
        isVisible ? hide() : show()
    }

    public func show() {
        let panel = existingOrNewPanel()
        model.prepare()
        position(panel)

        // ClipRoid has to become active for the search field to reliably take keystrokes. A
        // .nonactivatingPanel *can* become key while another app is frontmost, but it is fragile:
        // in practice the panel immediately resigns key and hides itself again, so the window
        // appears and vanishes within a frame.
        //
        // Activating is safe here precisely because PasteCoordinator.captureTarget() already ran,
        // in the hotkey handler, before this method was called. The app we are about to displace
        // has already been recorded, so stealing focus costs nothing — and `deliver(to:)` hands it
        // straight back.
        //
        // .nonactivatingPanel is kept for the rest of its behaviour: the panel does not take over
        // the menu bar and does not force a Space switch.
        isShowing = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        guard isShowing else { return }
        isShowing = false
        panel?.orderOut(nil)
        onDismiss()
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            // .nonactivatingPanel is the load-bearing flag: it lets the panel accept keystrokes
            // while another app stays active.
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false)

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Follows the user across Spaces and sits above a full-screen app rather than forcing a
        // Space switch, which would be far more disruptive than the paste is worth.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self

        panel.contentView = NSHostingView(
            rootView: QuickPasteView(model: model, onDismiss: { [weak self] in self?.hide() }))

        self.panel = panel
        return panel
    }

    /// Appears on the screen the cursor is on — not the "main" screen, which on a multi-monitor
    /// desk is usually the wrong one (spec §10).
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        // Slightly above centre: the eye goes there first, and it keeps the panel clear of the Dock.
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + frame.height * 0.12)
        panel.setFrameOrigin(origin)
    }

    public func windowDidResignKey(_ notification: Notification) {
        // Transient by design (spec §6: "stay out of the way"). Deferred by a turn of the run loop
        // so that losing key *because we are pasting* does not race the paste itself.
        guard isShowing else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShowing, self.panel?.isKeyWindow == false else { return }
            self.hide()
        }
    }
}

/// A borderless panel cannot become key by default, which would make the search field untypeable.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
