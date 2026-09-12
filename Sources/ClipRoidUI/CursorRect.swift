import SwiftUI
import AppKit

/// Sets the pointer's shape over a region.
///
/// Uses AppKit's cursor-rect machinery rather than `NSCursor.push()` / `.pop()` in an `onHover`.
/// Push and pop have to be balanced exactly, and a view that disappears while the pointer is over
/// it — a clip being deleted, a panel closing, a selection changing — never pops, leaving the
/// pointer stuck as an eyedropper over the whole app. A cursor rect is managed by AppKit and
/// resets itself when the view goes away.
struct CursorRect: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView {
        CursorView(cursor: cursor)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CursorView)?.cursor = cursor
    }

    private final class CursorView: NSView {
        var cursor: NSCursor {
            didSet { window?.invalidateCursorRects(for: self) }
        }

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }
    }
}

extension NSCursor {
    /// An eyedropper, drawn from the SF Symbol.
    ///
    /// macOS ships no eyedropper cursor, and `.crosshair` reads as "select a region" rather than
    /// "sample a colour". Falls back to crosshair if the symbol is unavailable.
    /// `@MainActor` because `NSCursor` is not `Sendable`; cursors are only ever touched from the
    /// main thread anyway.
    @MainActor
    static let eyedropper: NSCursor = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "eyedropper",
                                   accessibilityDescription: "Sample a colour")?
            .withSymbolConfiguration(configuration) else {
            return .crosshair
        }

        // Drawn onto an opaque-bordered copy so it stays visible over both light and dark images.
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        symbol.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()

        // The hot spot is the dropper's tip, at the bottom-left of the glyph — not the centre,
        // or the sampled pixel is offset from the one the user is pointing at.
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: size.height - 3))
    }()
}

extension View {
    /// Shows `cursor` while the pointer is over this view.
    func cursor(_ cursor: NSCursor) -> some View {
        background(CursorRect(cursor: cursor))
    }
}
