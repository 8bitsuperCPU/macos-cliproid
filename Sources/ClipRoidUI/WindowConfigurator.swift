import SwiftUI
import AppKit

/// Gives the hosting window a frame autosave name and a minimum size.
///
/// SwiftUI's `WindowGroup` does not persist a window's frame on its own, so the Library reopened
/// at its default size every launch no matter how it had been left. AppKit already does this well
/// via `setFrameAutosaveName`, which stores the frame in user defaults and restores it — this just
/// reaches the `NSWindow` to switch it on.
///
/// Adapted from ~/projects/nyx/avatar-editor/.../Views/WindowConfigurator.swift.
struct WindowConfigurator: NSViewRepresentable {
    let autosaveName: String
    var minSize: NSSize?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window during makeNSView, so configuration waits a turn of the run loop.
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        if let minSize { window.minSize = minSize }
        guard window.frameAutosaveName != autosaveName else { return }
        // Setting the name both restores a saved frame and starts saving future ones.
        window.setFrameAutosaveName(autosaveName)
    }
}

extension View {
    /// Persists this window's position and size across launches.
    func persistentWindowFrame(_ name: String, minSize: NSSize? = nil) -> some View {
        background(WindowConfigurator(autosaveName: name, minSize: minSize))
    }
}
