import SwiftUI
import ClipRoidCore

/// The shelf's contents: a horizontal strip of the most recent clips.
struct ShelfView: View {
    @Bindable var model: ShelfViewModel
    @State private var hovered: Int64?

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
                    .onHover { hovered = $0 ? clip.id : nil }
                    .onTapGesture { model.paste(clip) }
                    // Drag out works everywhere, needs no permission, and is the most robust
                    // delivery path of all (spec §4.12).
                    .draggable(clip.displayText)
                    .help(clip.displayText)
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
