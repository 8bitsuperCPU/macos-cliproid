import SwiftUI
import ClipRoidCore

/// One clip in the shelf.
struct ShelfCard: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel
    var size: CGSize

    @State private var isHovered = false
    @State private var thumbnailURL: URL?
    @State private var preview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(10)
        .frame(width: size.width, height: size.height)
        // Opaque and independent of the panel background — see ShelfPalette.
        .background(isHovered ? ShelfPalette.cardHovered : ShelfPalette.card,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShelfPalette.cardBorder))
        .overlay(alignment: .top) { if isHovered { hoverActions } }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
        .onTapGesture { model.paste(clip) }
        .draggable(clip.displayText)
        .contextMenu { ShelfCardMenu(clip: clip, model: model) }
        .task(id: clip.id) {
            thumbnailURL = await model.thumbnailURL(for: clip)
            preview = await model.fullText(for: clip)
        }
    }

    @ViewBuilder
    private var content: some View {
        if clip.sensitivity == .secret {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "eye.slash").font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text("Hidden")
                    .font(.system(size: 11))
                    .foregroundStyle(ShelfPalette.secondaryText)
            }
        } else if let hex = clip.colorHex, let colour = Color(hex: hex) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5).fill(colour).frame(width: 26, height: 26)
                Text(hex)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ShelfPalette.primaryText)
            }
        } else if let thumbnailURL {
            AsyncImage(url: thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text(preview.isEmpty ? clip.displayText : preview)
                .font(.system(size: 11.5))
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .foregroundStyle(ShelfPalette.primaryText)
        }
    }

    private var lineLimit: Int { max(2, Int((size.height - 44) / 15)) }

    private var footer: some View {
        HStack(spacing: 5) {
            AppIcon(bundleId: clip.sourceAppBundleId, side: 13)
            ClipTimestamp(date: clip.copiedAt, font: .system(size: 10))
                .foregroundStyle(ShelfPalette.secondaryText)
            Spacer(minLength: 0)
            if clip.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
            if clip.isFavorite {
                Image(systemName: "star.fill").font(.system(size: 8))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.top, 6)
    }

    /// Appears over the card on hover, as in the reference.
    private var hoverActions: some View {
        HStack(spacing: 2) {
            action("list.bullet.indent", "Copy without pasting") { model.copyOnly(clip) }
            Spacer(minLength: 0)
            action("trash", "Delete") { model.delete(clip) }
            action(clip.isFavorite ? "star.fill" : "star",
                   clip.isFavorite ? "Remove favourite" : "Favourite") {
                model.toggleFavourite(clip)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ShelfPalette.primaryText)
                .frame(width: 19, height: 19)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ShelfCardMenu: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel

    var body: some View {
        if !model.categories.isEmpty {
            Menu("Collection") {
                ForEach(model.categories) { category in
                    Button(category.name) { model.assign(clip, to: category) }
                }
            }
        }
        Button(clip.isPinned ? "Unpin" : "Pin", systemImage: "pin") { model.togglePin(clip) }
        Button(clip.isFavorite ? "Remove favourite" : "Favourite", systemImage: "star") {
            model.toggleFavourite(clip)
        }
        Divider()
        Button("Copy", systemImage: "doc.on.doc") { model.copyOnly(clip) }
        Button("Paste", systemImage: "arrow.down.doc") { model.paste(clip) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(clip) }
    }
}
