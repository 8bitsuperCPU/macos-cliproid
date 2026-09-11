import SwiftUI
import ClipRoidCore

/// Album-style grid, for browsing images and screenshots visually (spec §4.11).
struct ClipGridView: View {
    @Bindable var model: LibraryViewModel

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.clips) { clip in
                    card(clip)
                        .onTapGesture { model.selection = [clip.id] }
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
            ClipThumbnail(clip: clip, model: model, side: 110)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Text(clip.sensitivity == .secret ? "••••••••" : clip.preview)
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
