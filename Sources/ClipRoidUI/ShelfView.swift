import SwiftUI
import ClipRoidCore
import ClipRoidKit

/// Sizing derived from the shelf's thickness, so every part scales together.
///
/// Centralised because the panel needs the same numbers to size itself as the view uses to lay
/// out — if they disagreed the shelf would clip its own contents or leave dead space.
enum ShelfMetrics {
    static let itemSpacing: CGFloat = 4
    static let padding: CGFloat = 6

    /// How long a tile is along the running axis.
    ///
    /// Square while the shelf is small, then widening as it grows, because a tall preview of text
    /// needs width to be readable at all — a 140pt square showing three words is worse than a
    /// wider tile showing a line.
    static func itemLength(forThickness thickness: CGFloat) -> CGFloat {
        let inner = thickness - padding * 2
        return inner < SettingsStore.previewThreshold - padding * 2
            ? inner
            : inner * 1.9
    }

    static func itemBreadth(forThickness thickness: CGFloat) -> CGFloat {
        thickness - padding * 2
    }
}

struct ShelfView: View {
    @Bindable var model: ShelfViewModel
    @Bindable var settings: SettingsStore
    @State private var hovered: Int64?

    private var thickness: CGFloat { CGFloat(settings.shelfThickness) }
    private var isVertical: Bool { model.position == .left || model.position == .right }

    /// The preview must open away from the edge the shelf is pinned to, or macOS flips it
    /// somewhere unhelpful.
    private var popoverEdge: Edge {
        switch model.position {
        case .top, .hidden: .bottom
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }

    var body: some View {
        Group {
            if isVertical {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: ShelfMetrics.itemSpacing) { items }
                        .padding(ShelfMetrics.padding)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ShelfMetrics.itemSpacing) { items }
                        .padding(ShelfMetrics.padding)
                }
            }
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private var background: some View {
        switch settings.shelfBackground {
        case .material:
            Rectangle().fill(.regularMaterial)
        case .custom:
            Rectangle()
                .fill(Color(hex: settings.shelfTintHex) ?? .black)
                .opacity(settings.shelfOpacity)
        }
    }

    @ViewBuilder
    private var items: some View {
        if model.clips.isEmpty {
            Text("No clips yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ForEach(model.clips) { clip in
                ShelfItem(
                    clip: clip, model: model,
                    isHovered: hovered == clip.id,
                    thickness: thickness,
                    showsPreview: settings.shelfShowsPreviews)
                    .onHover { inside in
                        hovered = inside ? clip.id : (hovered == clip.id ? nil : hovered)
                    }
                    .onTapGesture { model.paste(clip) }
                    .draggable(clip.displayText)
                    // At larger sizes the tile already shows the content, so a popover on top of
                    // it would be redundant — and would cover the thing it is previewing.
                    .popover(isPresented: .init(
                        get: { !settings.shelfShowsPreviews && hovered == clip.id },
                        set: { if !$0 && hovered == clip.id { hovered = nil } }
                    ), arrowEdge: popoverEdge) {
                        ShelfPreview(clip: clip, model: model)
                    }
                    .help(settings.shelfShowsPreviews ? clip.displayText : "")
            }
        }
    }
}

struct ShelfItem: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel
    var isHovered: Bool
    var thickness: CGFloat
    var showsPreview: Bool

    @State private var thumbnailURL: URL?
    @State private var preview: String = ""

    private var length: CGFloat { ShelfMetrics.itemLength(forThickness: thickness) }
    private var breadth: CGFloat { ShelfMetrics.itemBreadth(forThickness: thickness) }

    var body: some View {
        content
            .frame(width: length, height: breadth)
            .background(isHovered ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    isHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(isHovered ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .task(id: clip.id) {
                guard showsPreview else { return }
                thumbnailURL = await model.thumbnailURL(for: clip)
                preview = await model.fullText(for: clip)
            }
    }

    @ViewBuilder
    private var content: some View {
        if showsPreview {
            largeContent
        } else {
            // Compact: an icon and the source app badge. A text preview at this size would be a
            // few illegible pixels, so the hover popover carries the detail instead.
            VStack(spacing: 2) {
                icon(size: 14)
                AppIcon(bundleId: clip.sourceAppBundleId, side: 9)
            }
        }
    }

    @ViewBuilder
    private var largeContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            if clip.sensitivity == .secret {
                // A secret on an always-visible strip is exactly what should not be readable from
                // across a desk, so size does not change that.
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.orange)
                    Text("Hidden").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let hex = clip.colorHex, let colour = Color(hex: hex) {
                RoundedRectangle(cornerRadius: 4).fill(colour)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(hex).font(.system(size: 9, design: .monospaced)).lineLimit(1)
            } else if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text(preview.isEmpty ? clip.displayText : preview)
                    .font(.system(size: 10))
                    .lineLimit(previewLineLimit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 3) {
                AppIcon(bundleId: clip.sourceAppBundleId, side: 9)
                ClipTimestamp(date: clip.copiedAt, font: .system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(5)
    }

    /// Scales with the space available, so a taller shelf genuinely shows more rather than
    /// leaving whitespace under a truncated line.
    private var previewLineLimit: Int {
        max(2, Int((breadth - 18) / 12))
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        if let hex = clip.colorHex, let colour = Color(hex: hex) {
            RoundedRectangle(cornerRadius: 4).fill(colour).frame(width: size + 6, height: size + 6)
        } else {
            Image(systemName: clip.contentType.symbolName)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
        }
    }
}

/// The expanded preview shown on hover while the shelf is compact (spec §4.3).
struct ShelfPreview: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel

    @State private var thumbnailURL: URL?
    @State private var fullText: String = ""

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
                    .font(.caption).foregroundStyle(.secondary)
            } else if let hex = clip.colorHex, let colour = Color(hex: hex) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6).fill(colour).frame(width: 44, height: 44)
                    Text(hex).font(.system(.body, design: .monospaced))
                }
            } else if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 90)
                }
                .frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(fullText.isEmpty ? clip.displayText : fullText)
                    .font(.system(.callout, design: clip.contentType == .code ? .monospaced : .default))
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Click to paste · drag to any app")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 280)
        .task(id: clip.id) {
            thumbnailURL = await model.thumbnailURL(for: clip)
            fullText = await model.fullText(for: clip)
        }
    }
}
