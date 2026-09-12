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
