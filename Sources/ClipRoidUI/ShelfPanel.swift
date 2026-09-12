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
    private let settings: SettingsStore

    private var pointerTimer: Timer?
    /// Expanded means the full panel is showing; collapsed means the nub.
    private var isExpanded = false
    /// Tracks the auto-collapse preference so `applySettings` can tell a change of that setting
    /// apart from a change to anything else.
    private var wasAutoHiding = false

    /// Consecutive polls the pointer has been at the edge, or away from the shelf.
    ///
    /// Without a dwell requirement the shelf springs open whenever the pointer merely crosses the
    /// top of the screen — reaching for the menu bar, or throwing the cursor to a corner — which
    /// makes it feel like it is in the way rather than waiting to be asked. Collapsing needs its
    /// own, longer count so a moment's overshoot while reaching for a card does not dismiss it.
    private var edgeDwell = 0
    private var awayDwell = 0
    private static let ticksToExpand = 2    // ~300ms at a 150ms poll
    private static let ticksToCollapse = 4  // ~600ms

    /// How close to the screen edge the pointer must come to reveal an auto-hidden shelf.
    /// Generous enough to hit without aiming, small enough not to trigger in passing.
    private let revealMargin: CGFloat = 4

    private var thickness: CGFloat { CGFloat(settings.shelfThickness) }
    private let maxLengthFraction: CGFloat = 0.8

    public init(model: ShelfViewModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
        super.init()

        model.onClipsChanged = { [weak self] in
            self?.repositionIfVisible()
        }

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

    /// Called when the Settings window changes shelf position or item count.
    public func applySettings() {
        model.applySettings()
        // The hosting view is rebuilt so appearance changes — thickness, background, previews —
        // take effect immediately rather than on next launch.
        isExpanded = !settings.shelfAutoHide
        render()
        if model.position == .hidden {
            stopAutoHideMonitor()
            hide()
        } else {
            show()
        }
    }

    /// Re-sizes to match the current contents, but only while on screen — resizing a hidden
    /// auto-hide panel would make it flash into view.
    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        reposition()
    }

    // MARK: - Auto-hide

    /// Watches the pointer so an auto-hidden shelf can reveal itself at the screen edge.
    ///
    /// Polls `NSEvent.mouseLocation` rather than installing a global mouse monitor.
    /// `addGlobalMonitorForEvents(matching: .mouseMoved)` was tried first and silently never
    /// fires: observing mouse movement across the system requires **Input Monitoring**, a
    /// separate TCC permission from Accessibility — and a more alarming one to ask for, in an app
    /// that already has to justify a keystroke tap. Asking for it so a strip can slide into view
    /// is not a trade worth making.
    ///
    /// Reading a cursor coordinate needs no permission at all. The timer only exists while
    /// auto-hide is switched on, and the work per tick is a coordinate comparison — cheaper than
    /// the pasteboard poll the app already runs.
    private func updateAutoHideMonitor() {
        guard settings.shelfAutoHide, model.position != .hidden else {
            stopAutoHideMonitor()
            return
        }
        guard pointerTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        // .common so the reveal keeps working while a menu is open or a window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        Diagnostics.log("Auto-hide pointer polling started")
    }

    private func stopAutoHideMonitor() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    /// Rebuilds the hosted view for the current collapsed/expanded state.
    private func render() {
        panel?.contentView = NSHostingView(
            rootView: ShelfView(model: model, settings: settings, isCollapsed: !isExpanded))
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        render()
        reposition()
        Diagnostics.log(expanded ? "Shelf expanded" : "Shelf collapsed")
    }

    private func pointerMoved() {
        guard settings.shelfAutoHide, let panel else { return }
        let mouse = NSEvent.mouseLocation

        if isExpanded {
            // An open preview keeps the shelf up. Collapsing would destroy the card the preview is
            // anchored to and take the preview with it, regardless of its own close delay.
            if model.isPreviewOpen {
                awayDwell = 0
                return
            }
            let generous = panel.frame.insetBy(dx: -24, dy: -24)
            if generous.contains(mouse) || isPointerAtRevealEdge(mouse) {
                awayDwell = 0
                return
            }
            awayDwell += 1
            guard awayDwell >= Self.ticksToCollapse else { return }
            awayDwell = 0
            edgeDwell = 0
            setExpanded(false)
            return
        }

        // Collapsed: expand when the pointer rests on the nub, or on the edge it sits on.
        //
        // The edge counts as well as the nub itself, and must: the nub is 6pt tall at the outer
        // screen edge, and the expanded panel hangs below it. Were only the panel's own frame
        // accepted, the pointer that triggered the expansion would be instantly outside it — so
        // it would collapse, so the edge would expand it again, several times a second.
        let nubZone = panel.frame.insetBy(dx: -10, dy: -10)
        guard nubZone.contains(mouse) || isPointerAtRevealEdge(mouse) else {
            edgeDwell = 0
            return
        }
        edgeDwell += 1
        guard edgeDwell >= Self.ticksToExpand else { return }
        edgeDwell = 0
        awayDwell = 0
        setExpanded(true)
    }

    /// True when the pointer is against the screen edge the shelf lives on, and within the span
    /// the shelf would occupy — so brushing the far corner of the screen does not summon it.
    private func isPointerAtRevealEdge(_ mouse: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        else { return false }
        let visible = screen.visibleFrame
        let span = shelfSpan(in: visible)

        switch model.position {
        case .top, .hidden:
            return mouse.y >= visible.maxY - revealMargin
                && abs(mouse.x - visible.midX) <= span / 2
        case .bottom:
            return mouse.y <= visible.minY + revealMargin
                && abs(mouse.x - visible.midX) <= span / 2
        case .left:
            return mouse.x <= visible.minX + revealMargin
                && abs(mouse.y - visible.midY) <= span / 2
        case .right:
            return mouse.x >= visible.maxX - revealMargin
                && abs(mouse.y - visible.midY) <= span / 2
        }
    }

    public func show() {
        guard model.position != .hidden else { hide(); return }
        let panel = existingOrNewPanel()
        model.start()
        // Auto-collapse starts collapsed; the nub stays on screen as the affordance.
        isExpanded = !settings.shelfAutoHide
        wasAutoHiding = settings.shelfAutoHide
        updateAutoHideMonitor()
        render()
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
            contentRect: NSRect(x: 0, y: 0, width: 400, height: thickness),
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
        panel.contentView = NSHostingView(
            rootView: ShelfView(model: model, settings: settings, isCollapsed: !isExpanded))
        self.panel = panel
        return panel
    }

    /// Places the shelf on the screen that currently owns the menu bar.
    ///
    /// `visibleFrame` already excludes the menu bar and the Dock, so its top edge is exactly the
    /// highest point a well-behaved window may occupy. On a secondary display with no menu bar,
    /// `visibleFrame.maxY` equals `frame.maxY` and the shelf simply sits at the very top, which is
    /// correct for that screen.
    private var currentThickness: CGFloat {
        isExpanded ? thickness : CGFloat(settings.collapsedThickness)
    }

    /// How long the shelf is along its running axis, sized to its contents.
    ///
    /// Previously a flat 600pt, which meant reducing the clip count left a mostly empty strip the
    /// same size as before — the shelf never shrank. It is now derived from the cards actually
    /// shown, then capped so a shelf of twenty large cards cannot span the display.
    private func shelfSpan(in visible: NSRect) -> CGFloat {
        guard isExpanded else { return CGFloat(settings.collapsedLength) }
        let content = ShelfMetrics.expandedLength(
            cardCount: model.clips.count, thickness: thickness)
        let isHorizontal = model.position == .top || model.position == .bottom
            || model.position == .hidden
        let available = (isHorizontal ? visible.width : visible.height) * maxLengthFraction
        // A floor, so an empty shelf is still a usable panel rather than a sliver.
        return min(max(content, 320), available)
    }

    private func reposition() {
        guard let panel else { return }
        // The screen the pointer is on when revealing, otherwise the one with the menu bar.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let span = shelfSpan(in: visible)
        let breadth = currentThickness
        let size: NSSize
        let origin: NSPoint

        switch model.position {
        case .top, .hidden:
            size = NSSize(width: span, height: breadth)
            origin = NSPoint(x: visible.midX - span / 2, y: visible.maxY - breadth)
        case .bottom:
            size = NSSize(width: span, height: breadth)
            origin = NSPoint(x: visible.midX - span / 2, y: visible.minY)
        case .left:
            size = NSSize(width: breadth, height: span)
            origin = NSPoint(x: visible.minX, y: visible.midY - span / 2)
        case .right:
            size = NSSize(width: breadth, height: span)
            origin = NSPoint(x: visible.maxX - breadth, y: visible.midY - span / 2)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

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
