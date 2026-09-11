import SwiftUI
import ClipRoidCore

/// The shelf's contents: a horizontal strip of the most recent clips.
struct ShelfView: View {
    @Bindable var model: ShelfViewModel
    @State private var hovered: Int64?

    /// The preview must open away from the screen edge the shelf is pinned to, or it opens
    /// off-screen and macOS silently flips it somewhere unhelpful.
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
            if model.position == .left || model.position == .right {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) { items }.padding(6)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { items }.padding(6)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
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
                ShelfItem(clip: clip, model: model, isHovered: hovered == clip.id)
                    .onHover { inside in
                        hovered = inside ? clip.id : (hovered == clip.id ? nil : hovered)
                    }
                    .onTapGesture { model.paste(clip) }
                    // Drag out works everywhere, needs no permission, and is the most robust
                    // delivery path of all (spec §4.12).
                    .draggable(clip.displayText)
                    // A real popover rather than .help(): spec §4.3 asks for an expanded preview
                    // with more content detail, and a tooltip cannot show a thumbnail or wrap
                    // multiple lines of text.
                    .popover(isPresented: .init(
                        get: { hovered == clip.id },
                        set: { if !$0 && hovered == clip.id { hovered = nil } }
                    ), arrowEdge: popoverEdge) {
                        ShelfPreview(clip: clip, model: model)
                    }
            }
        }
    }
}

struct ShelfItem: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel
    var isHovered: Bool

    var body: some View {
        VStack(spacing: 2) {
            icon
            AppIcon(bundleId: clip.sourceAppBundleId, side: 9)
        }
        .frame(width: 42, height: 42)
        .background(isHovered ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .scaleEffect(isHovered ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var icon: some View {
        if let hex = clip.colorHex, let colour = Color(hex: hex) {
            RoundedRectangle(cornerRadius: 4).fill(colour).frame(width: 20, height: 20)
        } else {
            Image(systemName: clip.contentType.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(height: 20)
        }
    }
}


/// The expanded preview shown on hover (spec §4.3).
struct ShelfPreview: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel

    @State private var thumbnailURL: URL?
    @State private var body_: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AppIcon(bundleId: clip.sourceAppBundleId, side: 14)
                Text(clip.sourceAppName ?? "Unknown").font(.caption.weight(.medium))
                Spacer()
                ClipTimestamp(date: clip.copiedAt, font: .caption2)
                    .foregroundStyle(.secondary)
            }

            if let hex = clip.colorHex, let colour = Color(hex: hex) {
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
                Text(body_.isEmpty ? clip.displayText : body_)
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
            body_ = await model.fullText(for: clip)
        }
    }
}
