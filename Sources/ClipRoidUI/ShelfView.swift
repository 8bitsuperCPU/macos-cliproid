import SwiftUI
import ClipRoidCore
import ClipRoidKit

/// Sizing for the shelf, shared between the view and the panel that hosts it — if they disagreed
/// the shelf would clip its own contents or leave dead space.
enum ShelfMetrics {
    static let cardSpacing: CGFloat = 6
    static let padding: CGFloat = 8
    static let rowSpacing: CGFloat = 5

    /// What the search row, the chip row, their spacings and the panel padding cost.
    ///
    /// Measured against the real controls rather than estimated. This used to include a section
    /// header row and more generous padding, which together cost 102pt — on a 170pt shelf that is
    /// more than half the height spent on chrome before a single clip is shown. The header said
    /// what the selected chip already says, so it went; the padding was tightened.
    static let chromeHeight: CGFloat = padding + 24 + rowSpacing + 24 + rowSpacing + padding

    /// The height left for cards once the chrome has taken its share.
    static func cardHeight(forThickness thickness: CGFloat) -> CGFloat {
        max(52, thickness - chromeHeight)
    }

    static func cardSize(forThickness thickness: CGFloat) -> CGSize {
        cardSize(forHeight: cardHeight(forThickness: thickness))
    }

    /// Landscape, because a card carries a line or two of text under a preview and a square wastes
    /// the width that makes it readable.
    static func cardSize(forHeight height: CGFloat) -> CGSize {
        CGSize(width: height * 1.5, height: height)
    }

    /// Total expanded length along the running axis.
    static func expandedLength(cardCount: Int, thickness: CGFloat) -> CGFloat {
        let card = cardSize(forThickness: thickness)
        let cards = CGFloat(max(cardCount, 1)) * (card.width + cardSpacing)
        return cards + padding * 2
    }
}

struct ShelfView: View {
    @Bindable var model: ShelfViewModel
    @Bindable var settings: SettingsStore
    /// Collapsed renders the nub; expanded renders the full panel.
    var isCollapsed: Bool

    @State private var isAddingCategory = false
    @State private var newCategoryName = ""

    private var thickness: CGFloat { CGFloat(settings.shelfThickness) }

    /// A preview must open away from the screen edge the shelf is pinned to, or it opens
    /// off-screen and macOS flips it somewhere unhelpful.
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
            if isCollapsed {
                collapsedNub
            } else {
                expanded
            }
        }
        .alert("New Collection", isPresented: $isAddingCategory) {
            TextField("Name", text: $newCategoryName)
            Button("Cancel", role: .cancel) { newCategoryName = "" }
            Button("Create") {
                let name = newCategoryName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.createCategory(named: name) }
                newCategoryName = ""
            }
        }
    }

    /// What is on screen when the shelf is out of use: a small bar, not nothing.
    ///
    /// Hiding entirely would leave no affordance at all — the user has to remember an invisible
    /// screen edge exists. A nub is unobtrusive and still says "something lives here".
    private var collapsedNub: some View {
        CollapsedBar(settings: settings)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: ShelfMetrics.rowSpacing) {
            searchRow
            chipsRow
            cards
        }
        .padding(ShelfMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ShelfPalette.panel(settings))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
    }

    private var searchRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(ShelfPalette.secondaryText(settings))
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ShelfPalette.primaryText(settings))

            Spacer(minLength: 8)

            // The clip count lived under a section header of its own. That header duplicated the
            // selected chip, so it was removed and the count rehomed here, where the search row
            // already had width going spare.
            if !model.clips.isEmpty {
                Text("\(model.clips.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(ShelfPalette.tertiaryText(settings))
            }

            iconButton("square.and.pencil", "New note") { model.createNote() }
            iconButton("arrow.up.forward", "Open Library") { model.openLibrary?() }
        }
    }

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                iconToggle("star.fill", isOn: model.favouritesOnly, help: "Favourites only") {
                    model.favouritesOnly.toggle()
                    if model.favouritesOnly { model.activeCategoryId = nil }
                }

                chip("All", count: nil, isOn: model.activeCategoryId == nil && !model.favouritesOnly) {
                    model.activeCategoryId = nil
                    model.favouritesOnly = false
                }

                ForEach(model.categories) { category in
                    chip(category.name,
                         count: model.categoryCounts[category.id],
                         isOn: model.activeCategoryId == category.id) {
                        model.favouritesOnly = false
                        model.activeCategoryId =
                            model.activeCategoryId == category.id ? nil : category.id
                    }
                }

                iconButton("plus", "New collection") { isAddingCategory = true }
            }
        }
        .frame(height: 24)
    }

    /// Cards fill whatever height is left, measured rather than predicted.
    ///
    /// Sizing them from a constant estimate of the chrome meant any drift — a different system
    /// font size, a control a point taller than assumed — became blank space beneath the row. The
    /// estimate is still used to size the panel's width, where being a few points out is invisible.
    private var cards: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ShelfMetrics.cardSpacing) {
                    if model.clips.isEmpty {
                        Text(model.searchText.isEmpty ? "No clips yet" : "No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(ShelfPalette.tertiaryText(settings))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(model.clips) { clip in
                            ShelfCard(
                                clip: clip, model: model, settings: settings,
                                size: ShelfMetrics.cardSize(forHeight: max(proxy.size.height, 40)),
                                previewEdge: popoverEdge)
                        }
                    }
                }
                .frame(height: proxy.size.height)
            }
            // A ScrollView applies its own content margins by default, which pushed the row a few
            // points down and clipped the bottom of every card — the timestamps went missing.
            .contentMargins(.all, 0, for: .scrollContent)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Small controls

    private func chip(_ title: String, count: Int?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isOn ? ShelfPalette.selectedChipText(settings).opacity(0.55)
                                              : ShelfPalette.tertiaryText(settings))
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(isOn ? ShelfPalette.selectedChip(settings) : ShelfPalette.control(settings), in: Capsule())
            .foregroundStyle(isOn ? ShelfPalette.selectedChipText(settings) : ShelfPalette.primaryText(settings))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ShelfPalette.primaryText(settings))
                .frame(width: 24, height: 24)
                .background(ShelfPalette.control(settings), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconToggle(_ symbol: String, isOn: Bool, help: String,
                            _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? ShelfPalette.selectedChipText(settings) : ShelfPalette.primaryText(settings))
                .frame(width: 24, height: 24)
                .background(isOn ? ShelfPalette.selectedChip(settings) : ShelfPalette.control(settings),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
