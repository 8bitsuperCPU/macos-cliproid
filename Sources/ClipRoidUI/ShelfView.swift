import SwiftUI
import ClipRoidCore
import ClipRoidKit

/// Sizing for the shelf, shared between the view and the panel that hosts it — if they disagreed
/// the shelf would clip its own contents or leave dead space.
enum ShelfMetrics {
    static let cardSpacing: CGFloat = 8
    static let padding: CGFloat = 12
    /// Search row + chips row + section header.
    static let chromeHeight: CGFloat = 108

    static func cardSize(forThickness thickness: CGFloat) -> CGSize {
        let height = max(64, thickness - chromeHeight - padding)
        return CGSize(width: height * 1.45, height: height)
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
        VStack(alignment: .leading, spacing: 10) {
            searchRow
            chipsRow
            Text(sectionTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ShelfPalette.secondaryText)
            cards
        }
        .padding(ShelfMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ShelfPalette.panel(settings))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
    }

    private var sectionTitle: String {
        if let id = model.activeCategoryId,
           let category = model.categories.first(where: { $0.id == id }) {
            return category.name
        }
        if model.favouritesOnly { return "Favourites" }
        if !model.searchText.isEmpty { return "Results" }
        return "Recent"
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(ShelfPalette.secondaryText)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ShelfPalette.primaryText)

            Spacer(minLength: 8)

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
        .frame(height: 26)
    }

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ShelfMetrics.cardSpacing) {
                if model.clips.isEmpty {
                    Text(model.searchText.isEmpty ? "No clips yet" : "No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(ShelfPalette.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.clips) { clip in
                        ShelfCard(clip: clip, model: model,
                                  size: ShelfMetrics.cardSize(forThickness: thickness))
                    }
                }
            }
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
                        .foregroundStyle(isOn ? ShelfPalette.selectedChipText.opacity(0.55)
                                              : ShelfPalette.tertiaryText)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(isOn ? ShelfPalette.selectedChip : ShelfPalette.controlFill, in: Capsule())
            .foregroundStyle(isOn ? ShelfPalette.selectedChipText : ShelfPalette.primaryText)
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ShelfPalette.primaryText)
                .frame(width: 26, height: 26)
                .background(ShelfPalette.controlFill, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconToggle(_ symbol: String, isOn: Bool, help: String,
                            _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? ShelfPalette.selectedChipText : ShelfPalette.primaryText)
                .frame(width: 26, height: 26)
                .background(isOn ? ShelfPalette.selectedChip : ShelfPalette.controlFill,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
