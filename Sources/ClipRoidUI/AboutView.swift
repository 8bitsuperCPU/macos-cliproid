import SwiftUI
import ClipRoidCore
import ClipRoidKit
import ClipRoidPlatform

/// Settings → About: what version this is, what the app does, and how to drive it (spec §4.19).
struct AboutView: View {
    @Bindable var settings: SettingsStore

    /// Read from the bundle rather than hard-coded, so it cannot drift from what was shipped.
    /// `bundle.sh` derives these from git — the version from the latest tag, the build from the
    /// commit count.
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                features
                Divider()
                howToUse
                Divider()
                privacy
            }
            .padding(18)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let icon = NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("ClipDroid").font(.title2.weight(.semibold))
                Text("Version \(version) (build \(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Clipboard history for macOS")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What it does").font(.headline)

            item("clock.arrow.circlepath", "Keeps what you copy",
                 "Text, images, screenshots, files, colours, code and links are saved as you copy them, tagged with the app they came from.")
            item("magnifyingglass", "Finds it again",
                 "Full-text search across everything, including text recognised inside screenshots.")
            item("eye.slash", "Leaves secrets alone",
                 "Passwords, API keys and card numbers are detected, hidden from the shelf and blurred until you ask to see them.")
            item("rectangle.topthird.inset.filled", "Stays out of the way",
                 "A shelf at the screen edge collapses to a slim bar until you point at it.")
            item("folder", "Organises itself",
                 "Collections, tags and rules that file clips automatically — everything from Figma into Design Assets, say.")
            if FeatureFlags.inlineShortcuts {
                item("text.cursor", "Expands shortcuts",
                     "Assign ;sig to a clip and type it anywhere. Off by default.")
            }
        }
    }

    private var howToUse: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to use it").font(.headline)

            shortcut("⌃⌘V", "Open Quick Paste anywhere — type a few letters, press Return.")
            shortcut("⌃⌘0–9", "Paste one of the ten most recent clips directly.")
            shortcut("Point at the screen edge", "Open the shelf. Click a card to paste it, or drag it into any app.")
            shortcut("Hover a card", "See a preview. Pin it to keep it open.")
            shortcut("Double-click an image", "Fill the window with it. Click anywhere in it to read a colour.")
            shortcut("Right-click a clip", "Copy, edit in another app, read text out of an image, file it away.")

            Text("In the Library window").font(.headline).padding(.top, 6)

            shortcut("Arrow keys", "Move between clips. Hold Shift to select a run of them.")
            shortcut("Space", "Open the preview. Escape closes it.")
            shortcut("⌃Space", "Open the clip's menu without the mouse.")
            shortcut("⌘A", "Select everything listed — filter to Images first to select just those.")
            shortcut("⌘-click / ⇧-click", "Add one clip to the selection, or extend it.")
            shortcut("Delete", "Delete the selection, after confirming.")

            Text("Search accepts filters: dashboard @screenshot @today, or @Figma, or @favourite.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your clips").font(.headline)
            Text("Everything is stored on this Mac, in ~/Library/Application Support/ClipRoid. There is no account, no sync and no analytics. The only time ClipDroid contacts the internet is if you switch on link previews.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Someone reading About to decide whether to trust the app should not have to go
            // hunting for this.
            Label {
                Text(PasteDeliverer.isAccessibilityGranted
                     ? "Accessibility is granted, so ClipDroid can paste for you."
                     : "Accessibility is not granted. Clips are copied to the clipboard and you press ⌘V yourself.")
            } icon: {
                Image(systemName: PasteDeliverer.isAccessibilityGranted
                      ? "checkmark.circle" : "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func shortcut(_ key: String, _ what: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .frame(width: 150, alignment: .leading)
            Text(what).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
