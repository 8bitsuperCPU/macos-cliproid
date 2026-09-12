import SwiftUI
import ClipRoidCore

/// Album-style grid, for browsing images and screenshots visually (spec §4.11).
struct ClipGridView: View {
    @Bindable var model: LibraryViewModel

    /// Derived from the slider, so the grid reflows as it moves.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.tileSize, maximum: model.tileSize * 1.35), spacing: 10)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.clips) { clip in
                    card(clip)
                        .gesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    model.selection = [clip.id]
                                    if clip.contentType == .image || clip.contentType == .screenshot {
                                        model.isDetailExpanded = true
                                    }
                                }
                                .exclusively(before:
                                    TapGesture(count: 1)
                                        .onEnded { model.selection = [clip.id] })
                        )
                        .contextMenu { ClipContextMenu(clip: clip, model: model) }
                        .onAppear {
                            if clip.id == model.clips.last?.id {
                                Task { await model.loadNextPage() }
                            }
                        }
                }
            }
            .padding(12)
        }
    }

    private func card(_ clip: ClipSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipThumbnail(clip: clip, model: model, side: model.tileSize * 0.72)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Text(clip.sensitivity == .secret ? "••••••••" : clip.displayText)
                .font(.caption)
                .lineLimit(2)
                .blur(radius: clip.sensitivity == .secret ? 3 : 0)

            if let app = clip.sourceAppName {
                Text(app).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(model.selection.contains(clip.id)
                    ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
