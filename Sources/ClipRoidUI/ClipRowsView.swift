import SwiftUI
import ClipRoidCore

/// Timeline and list layouts.
///
/// `LazyVStack` inside a `ScrollView` rather than `List`: it virtualises properly for thousands of
/// rows, and `onAppear` on the last row is what drives cursor pagination.
struct ClipRowsView: View {
    @Bindable var model: LibraryViewModel
    var dense: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.clips) { clip in
                    LibraryClipRow(
                        clip: clip, dense: dense,
                        isSelected: model.selection.contains(clip.id),
                        model: model)
                        .onTapGesture { select(clip) }
                        .contextMenu { ClipContextMenu(clip: clip, model: model) }
                        // Drag out to any app (spec §4.12). Always available, needs no permission,
                        // and is the most robust delivery path for images and files.
                        .draggable(clip.preview)
                        .onAppear {
                            if clip.id == model.clips.last?.id {
                                Task { await model.loadNextPage() }
                            }
                        }
                    Divider().opacity(dense ? 0.3 : 0.15)
                }
                if model.isLoadingPage {
                    ProgressView().padding(12)
                }
            }
        }
    }

    private func select(_ clip: ClipSummary) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.selection.contains(clip.id) {
                model.selection.remove(clip.id)
            } else {
                model.selection.insert(clip.id)
            }
        } else {
            model.selection = [clip.id]
        }
    }
}

struct LibraryClipRow: View {
    let clip: ClipSummary
    var dense: Bool
    var isSelected: Bool
    @Bindable var model: LibraryViewModel

    var body: some View {
        HStack(spacing: 10) {
            ClipThumbnail(clip: clip, model: model, side: dense ? 22 : 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.sensitivity == .secret ? "••••••••••••••••" : clip.displayText)
                    .lineLimit(dense ? 1 : 2)
                    .font(dense ? .caption : .body)
                    .blur(radius: clip.sensitivity == .secret ? 3 : 0)

                HStack(spacing: 5) {
                    AppIcon(bundleId: clip.sourceAppBundleId, side: 11)
                    if let app = clip.sourceAppName { Text(app) }
                    ClipTimestamp(date: clip.copiedAt)
                    if clip.repeatCount > 1 { Text("×\(clip.repeatCount)") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if clip.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
            if clip.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
            if clip.sensitivity == .secret {
                Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.orange)
                    .help("Looks like a secret — hidden by default")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, dense ? 4 : 8)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
    }
}

/// Loads a thumbnail lazily, by URL.
///
/// The view model never holds image bytes — that is the whole reason `ClipSummary` carries a path
/// rather than `Data`. Ten thousand rows each holding a decoded thumbnail is how a timeline of this
/// size becomes unusable.
struct ClipThumbnail: View {
    let clip: ClipSummary
    @Bindable var model: LibraryViewModel
    var side: CGFloat

    @State private var url: URL?

    var body: some View {
        Group {
            if let hex = clip.colorHex {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(hex: hex) ?? .gray)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
            } else if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: clip.contentType.symbolName)
                    .font(.system(size: side * 0.45))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .task(id: clip.id) { url = await model.thumbnailURL(for: clip) }
    }
}

struct ClipContextMenu: View {
    let clip: ClipSummary
    @Bindable var model: LibraryViewModel

    var body: some View {
        Button(clip.isPinned ? "Unpin" : "Pin", systemImage: "pin") { model.togglePin(clip) }
        Button(clip.isFavorite ? "Remove favourite" : "Favourite", systemImage: "star") {
            model.toggleFavorite(clip)
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            model.delete(ids: [clip.id])
        }
    }
}

extension Color {
    /// Parses the `#RRGGBB` / `#RGB` / `#RRGGBBAA` forms the colour classifier stores.
    init?(hex: String) {
        var value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else {
            return nil
        }
        let hasAlpha = value.count == 8
        let r = Double((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(number & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
