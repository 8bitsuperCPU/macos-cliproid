import SwiftUI
import ClipRoidCore

/// One clip in the shelf.
struct ShelfCard: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel
    var size: CGSize
    /// Which way the preview should open, so it does not open off-screen.
    var previewEdge: Edge = .bottom

    @State private var isHovered = false
    @State private var showPreview = false
    @State private var hoverTask: Task<Void, Never>?
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
        .onHover { inside in
            isHovered = inside
            hoverTask?.cancel()
            guard inside else {
                showPreview = false
                return
            }
            // A short delay, so sweeping the pointer across the shelf to reach one card does not
            // fire a popover for every card it passes over.
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                showPreview = true
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: previewEdge) {
            ShelfPreview(clip: clip, model: model)
        }
        .onTapGesture { model.paste(clip) }
        .draggable(clip.displayText)
        .contextMenu { ShelfCardMenu(clip: clip, model: model) }
        // See TaskKey — enrichment lands under the same clip id, so keying on id alone leaves
        // the card showing a placeholder forever.
        .task(id: TaskKey(id: clip.id, thumbnail: clip.thumbnailPath)) {
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
                    .foregroundStyle(ShelfPalette.cardSecondaryText)
            }
        } else if let hex = clip.colorHex, let colour = Color(hex: hex) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5).fill(colour).frame(width: 26, height: 26)
                Text(hex)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ShelfPalette.cardPrimaryText)
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
                .foregroundStyle(ShelfPalette.cardPrimaryText)
        }
    }

    private var lineLimit: Int { max(2, Int((size.height - 44) / 15)) }

    private var footer: some View {
        HStack(spacing: 5) {
            AppIcon(bundleId: clip.sourceAppBundleId, side: 13)
            ClipTimestamp(date: clip.copiedAt, font: .system(size: 10))
                .foregroundStyle(ShelfPalette.cardSecondaryText)
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
                .foregroundStyle(ShelfPalette.cardPrimaryText)
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

/// The expanded preview shown when the pointer rests on a card (spec §4.3).
///
/// Worth having even though the card itself shows a preview: the card is a fixed size and clips
/// long text to a few lines, whereas this shows the clip at a size you can actually read, the full
/// image rather than a cropped fill, and the colour's value alongside its swatch.
struct ShelfPreview: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel

    @State private var thumbnailURL: URL?
    @State private var fullText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AppIcon(bundleId: clip.sourceAppBundleId, side: 14)
                Text(clip.sourceAppName ?? "Unknown").font(.caption.weight(.medium))
                Spacer()
                ClipTimestamp(date: clip.copiedAt, font: .caption2)
                    .foregroundStyle(.secondary)
            }

            if clip.sensitivity == .secret {
                Label("Hidden — this looks like a secret", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let hex = clip.colorHex, let colour = Color(hex: hex) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6).fill(colour).frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ColorFormats.allCases, id: \.self) { format in
                            if let text = ColorFormats.string(format, fromHex: hex) {
                                Text(text).font(.system(size: 11, design: .monospaced))
                            }
                        }
                    }
                }
            } else if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 100)
                }
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if let size = clip.imageSize {
                    Text("\(size.width) × \(size.height)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text(fullText.isEmpty ? clip.displayText : fullText)
                    .font(.system(.callout,
                                  design: clip.contentType == .code ? .monospaced : .default))
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Click to paste · drag to any app")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 300)
        .task(id: TaskKey(id: clip.id, thumbnail: clip.thumbnailPath)) {
            thumbnailURL = await model.thumbnailURL(for: clip)
            fullText = await model.fullText(for: clip)
        }
    }
}
