import SwiftUI
import ClipRoidCore

/// Reports where the keyboard cursor currently is, so Ctrl-Space can open its menu there.
struct FocusedCardFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// Album-style grid, for browsing images and screenshots visually (spec §4.11).
struct ClipGridView: View {
    @Bindable var model: LibraryViewModel

    private static let spacing: CGFloat = 10

    /// Derived from the slider, so the grid reflows as it moves.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.tileSize, maximum: model.tileSize * 1.35),
                  spacing: Self.spacing)]
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Self.spacing) {
                        ForEach(model.clips) { clip in
                            card(clip)
                                .id(clip.id)
                                .modifier(ClipSelectionGestures(clip: clip, model: model))
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
                // Arrowing off the visible area has to bring the cursor back into view, or the
                // selection moves somewhere the user cannot see.
                .onChange(of: model.focusedId) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id, anchor: .center) }
                }
            }
            // Up and down move by a row, so they need the column count SwiftUI does not report.
            .onChange(of: proxy.size.width, initial: true) { _, width in
                model.gridColumnCount = GridNavigation.columnCount(
                    availableWidth: width - 24,          // the grid's own padding
                    minimumItemWidth: model.tileSize,
                    spacing: Self.spacing)
            }
            .onChange(of: model.tileSize) { _, size in
                model.gridColumnCount = GridNavigation.columnCount(
                    availableWidth: proxy.size.width - 24,
                    minimumItemWidth: size,
                    spacing: Self.spacing)
            }
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
        // The cursor is shown separately from the selection: with several clips selected, the
        // user still needs to see which one the arrow keys will move from.
        .overlay {
            if model.focusedId == clip.id {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .background {
            if model.focusedId == clip.id {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: FocusedCardFrameKey.self, value: geo.frame(in: .global))
                }
            }
        }
    }
}

/// Click behaviour shared by the grid and the rows.
///
/// Plain click selects, Command-click toggles one, Shift-click extends a range — the standard
/// macOS trio, and the mouse half of "select several clips, then press Delete".
struct ClipSelectionGestures: ViewModifier {
    let clip: ClipSummary
    @Bindable var model: LibraryViewModel

    func body(content: Content) -> some View {
        content.gesture(
            TapGesture(count: 2)
                .onEnded {
                    model.selectOnly(clip)
                    // Images only, as before: filling the window with a text clip gains nothing.
                    // Space expands anything, for when that is what the user wants.
                    if clip.contentType == .image || clip.contentType == .screenshot {
                        model.isDetailExpanded = true
                    }
                }
                .exclusively(before: TapGesture(count: 1).onEnded { apply() })
        )
    }

    private func apply() {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            model.extendSelection(to: clip)
        } else if flags.contains(.command) {
            model.toggleSelection(clip)
        } else {
            model.selectOnly(clip)
        }
    }
}
