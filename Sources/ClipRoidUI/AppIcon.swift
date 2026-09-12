import SwiftUI
import AppKit

/// The real icon of the app a clip came from.
///
/// Spec §4.2 asks for the source app's icon on every card, and it is most of what makes the
/// timeline scannable — you recognise "the thing I copied from Figma" by its badge far faster than
/// by reading an app name. A generic SF Symbol in its place reads as a broken checkbox.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleId bundleId: String?) -> NSImage? {
        guard let bundleId else { return nil }
        if let cached = cache[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleId] = icon
        return icon
    }
}

struct AppIcon: View {
    let bundleId: String?
    var side: CGFloat = 13

    var body: some View {
        if let icon = AppIconCache.icon(forBundleId: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: side, height: side)
        } else {
            // An uninstalled or unknown app still gets a placeholder of the same size, so rows do
            // not jump around when one app in the list cannot be resolved.
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: side * 0.85))
                .frame(width: side, height: side)
                .foregroundStyle(.tertiary)
        }
    }
}


/// The system's icon for a file, as Finder shows it.
///
/// Spec §4.2 asks a file card to carry the file's icon, name, size and kind. A generic document
/// glyph loses the one cue that makes a file recognisable at a glance — a spreadsheet should look
/// like a spreadsheet.
@MainActor
enum FileIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        // `icon(forFile:)` answers for a missing file too, falling back to the generic document
        // icon, so a clip whose file has been deleted still renders sensibly.
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

struct FileIcon: View {
    let path: String
    var side: CGFloat

    var body: some View {
        if let icon = FileIconCache.icon(forPath: path) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
        } else {
            Image(systemName: "doc")
                .font(.system(size: side * 0.6))
                .frame(width: side, height: side)
                .foregroundStyle(.secondary)
        }
    }
}
