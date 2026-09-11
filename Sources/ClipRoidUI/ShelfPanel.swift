import AppKit
import SwiftUI
import ClipRoidCore
import ClipRoidKit

/// The always-visible shelf (spec §4.3).
///
/// ## What the spec asks for versus what macOS allows
///
/// §4.3 describes a "notch/dynamic-island style shelf". Two constraints shape what is actually
/// buildable:
///
/// 1. **You cannot draw inside the notch.** It is not an addressable region — the menu bar simply
///    routes around it. `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` describe the
///    flanks *beside* the notch, and they are the menu bar's own space.
/// 2. **A window at the very top either hides behind the menu bar or covers it.** Sitting above
///    `.mainMenu` level permanently occludes the menu bar, which is hostile behaviour and would
///    fail any reasonable review.
///
/// So this positions the shelf immediately **below** the menu bar, at the top of `visibleFrame`.
/// It overlays window content rather than reserving space — reserving would require the app to
/// own a system-level accessory, which is not available to a third-party app.
@MainActor
public final class ShelfPanel: NSObject {
    private var panel: NSPanel?
    private let model: ShelfViewModel

    /// Kept deliberately thin: it is glanceable, not a workspace (spec §6, "stay out of the way").
    private let thickness: CGFloat = 54
    private let maxWidthFraction: CGFloat = 0.55

    public init(model: ShelfViewModel) {
        self.model = model
        super.init()

        // Screens come and go — a laptop docking, a monitor waking. Reposition rather than leaving
        // the shelf stranded off-screen (spec §10, multiple monitors).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    public func show() {
        guard model.position != .hidden else { hide(); return }
        let panel = existingOrNewPanel()
        model.start()
        reposition()
        // orderFrontRegardless, not makeKeyAndOrderFront: the shelf must never take focus. It is
        // glanceable and clickable, and stealing key status from the user's editor to show a strip
        // of clips would be indefensible.
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }
        let panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: thickness),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        // .stationary keeps it from sliding during Space transitions; .canJoinAllSpaces means it
        // follows the user rather than living on one desktop.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.contentView = NSHostingView(rootView: ShelfView(model: model))
        self.panel = panel
        return panel
    }

    /// Places the shelf on the screen that currently owns the menu bar.
    ///
    /// `visibleFrame` already excludes the menu bar and the Dock, so its top edge is exactly the
    /// highest point a well-behaved window may occupy. On a secondary display with no menu bar,
    /// `visibleFrame.maxY` equals `frame.maxY` and the shelf simply sits at the very top, which is
    /// correct for that screen.
    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let width = min(600, visible.width * maxWidthFraction)
        let size: NSSize
        let origin: NSPoint

        switch model.position {
        case .top, .hidden:
            size = NSSize(width: width, height: thickness)
            origin = NSPoint(x: visible.midX - width / 2, y: visible.maxY - thickness)
        case .bottom:
            size = NSSize(width: width, height: thickness)
            origin = NSPoint(x: visible.midX - width / 2, y: visible.minY)
        case .left:
            size = NSSize(width: thickness, height: min(600, visible.height * maxWidthFraction))
            origin = NSPoint(x: visible.minX, y: visible.midY - size.height / 2)
        case .right:
            size = NSSize(width: thickness, height: min(600, visible.height * maxWidthFraction))
            origin = NSPoint(x: visible.maxX - thickness, y: visible.midY - size.height / 2)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        // Proof, not assumption: the shelf must sit entirely inside visibleFrame, which by
        // definition excludes the menu bar and the Dock. If its top edge ever exceeds
        // visibleFrame.maxY it is occluding the menu bar, which is the failure R6 warned about.
        let frame = panel.frame
        let clearsMenuBar = frame.maxY <= visible.maxY + 0.5
        Diagnostics.log(
            "Shelf frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) "
            + "| visibleFrame.maxY=\(Int(visible.maxY)) screen.maxY=\(Int(screen?.frame.maxY ?? 0)) "
            + "| clears menu bar: \(clearsMenuBar)")
    }
}

/// The shelf must never become key or main. A borderless panel would happily take focus on click
/// otherwise, pulling the user out of whatever they were typing into.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
