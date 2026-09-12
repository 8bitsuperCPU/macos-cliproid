import SwiftUI
import AppKit
import ClipRoidCore

/// Keyboard driving for the clip list (arrows, Space, Ctrl-Space, Escape, Delete, Select All).
///
/// One `onKeyPress(phases:)` rather than a modifier per key: the general form is the only one that
/// reports the modifier flags, and Space and Ctrl-Space differ only by those flags. Handling them
/// in separate `onKeyPress(.space)` modifiers would make whichever registered first swallow both.
struct LibraryKeyboardModifier: ViewModifier {
    @Bindable var model: LibraryViewModel
    /// Where to pop the menu for Ctrl-Space, in SwiftUI global coordinates.
    var focusedCardFrame: CGRect?
    var menuContent: (ClipSummary) -> AnyView

    @FocusState private var hasKeyboardFocus: Bool

    func body(content: Content) -> some View {
        content
            // Without this the pane can never become first responder, and no key press arrives.
            .focusable()
            // The ring would outline the entire clip list, which is noise — the focused card
            // already shows where the cursor is.
            .focusEffectDisabled()
            .focused($hasKeyboardFocus)
            .onAppear { hasKeyboardFocus = true }
            // Clicking a clip should also hand the keyboard back to the list, so the arrow keys
            // work straight after a mouse selection without an intervening Tab.
            .onChange(of: model.selection) { _, _ in hasKeyboardFocus = true }
            .onKeyPress(phases: .down) { press in handle(press) }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers

        // Select All. Handled here rather than as a menu command so it applies to the clip list
        // and not to whatever text field last had focus.
        if modifiers.contains(.command), press.key == KeyEquivalent("a") {
            model.selectAll()
            return .handled
        }

        switch press.key {
        case .upArrow:
            return model.moveFocus(.up, extending: modifiers.contains(.shift)) ? .handled : .ignored
        case .downArrow:
            return model.moveFocus(.down, extending: modifiers.contains(.shift)) ? .handled : .ignored
        case .leftArrow:
            return model.moveFocus(.left, extending: modifiers.contains(.shift)) ? .handled : .ignored
        case .rightArrow:
            return model.moveFocus(.right, extending: modifiers.contains(.shift)) ? .handled : .ignored

        case .space:
            guard let clip = model.focusedClip else { return .ignored }
            if modifiers.contains(.control) {
                ContextMenuPopup.show(menuContent(clip), at: focusedCardFrame)
            } else {
                model.isDetailExpanded.toggle()
            }
            return .handled

        case .escape:
            // Escape means "back out one step": first close the preview, and only once it is
            // closed does a second press drop the selection.
            if model.isDetailExpanded {
                model.isDetailExpanded = false
            } else if model.pendingDelete != nil {
                model.cancelPendingDelete()
            } else if !model.selection.isEmpty {
                model.clearSelection()
            } else {
                return .ignored
            }
            return .handled

        case .delete, .deleteForward:
            guard !model.selection.isEmpty else { return .ignored }
            model.requestDeleteSelection()
            return .handled

        case .return:
            guard let clip = model.focusedClip else { return .ignored }
            model.loadIntoClipboard(clip)
            return .handled

        default:
            return .ignored
        }
    }
}

extension View {
    func libraryKeyboard(
        model: LibraryViewModel,
        focusedCardFrame: CGRect?,
        menuContent: @escaping (ClipSummary) -> AnyView
    ) -> some View {
        modifier(LibraryKeyboardModifier(
            model: model, focusedCardFrame: focusedCardFrame, menuContent: menuContent))
    }
}

/// Pops a SwiftUI menu open from the keyboard.
///
/// `NSHostingMenu` renders the very same SwiftUI content the `.contextMenu` uses, so Ctrl-Space
/// and right-click cannot drift apart — an AppKit rewrite of the menu would have to be kept in
/// step by hand, and silently would not be.
enum ContextMenuPopup {
    static func show(_ content: AnyView, at frame: CGRect?) {
        let menu = NSHostingMenu(rootView: content)
        guard let window = NSApp.keyWindow, let contentView = window.contentView else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }

        guard let frame else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }

        // SwiftUI's global space is the window's content area with y increasing downwards;
        // AppKit's content view is the same area with y increasing upwards. Without the flip the
        // menu opens as far from the card as the card is from the top of the window.
        let point = NSPoint(x: frame.minX, y: contentView.bounds.height - frame.maxY)
        menu.popUp(positioning: nil, at: point, in: contentView)
    }
}

/// Closes the expanded preview on Escape, wherever focus happens to be.
///
/// `onKeyPress` only reaches the focused view, and in expanded mode focus is easily somewhere
/// else: the search field, an inline editor, or nothing at all after clicking the image to sample
/// a colour. That is why Escape worked only sometimes — it depended on what the user had touched
/// last. A window-level monitor does not care where focus landed.
struct EscapeClosesPreview: ViewModifier {
    @Bindable var model: LibraryViewModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.isDetailExpanded, initial: true) { _, expanded in
                if expanded { install() } else { remove() }
            }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // Escape

            // Sound here, unlike the enrichment-actor case that once crashed the app: local event
            // monitors are called synchronously on the main thread during event dispatch, so this
            // asserts something already true. It has to be synchronous — returning nil is what
            // swallows the key, and that decision cannot be deferred to a Task.
            // Returns a Bool rather than the event itself only because `assumeIsolated`
            // requires a Sendable result and NSEvent is explicitly not Sendable.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                // While text is being edited Escape means "cancel this edit", so it is left
                // alone; the preview is then one more press away.
                guard !(event.window?.firstResponder is NSText) else { return false }
                guard model.isDetailExpanded else { return false }
                model.isDetailExpanded = false
                return true
            }
            return consumed ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// Escape leaves the expanded preview regardless of which subview has focus.
    func escapeClosesPreview(model: LibraryViewModel) -> some View {
        modifier(EscapeClosesPreview(model: model))
    }
}
