import SwiftUI
import ClipRoidCore
import ClipRoidKit
import ClipRoidStore

/// The full Library window (spec §4.11).
public struct LibraryView: View {
    /// `@State`, not a passed-in `@Bindable`.
    ///
    /// Constructing the view model in the Scene body — `LibraryView(model: LibraryViewModel(...))`
    /// — builds a brand new one on every body evaluation. `start()` then runs against an instance
    /// that is immediately discarded, so the window renders "No clips here" and empty facets while
    /// the store is full. The view has to own the model for it to survive a re-render.
    @State private var model: LibraryViewModel
    let environment: AppEnvironment
    /// Remembered across launches.
    @AppStorage("library.detailWidth") private var detailWidth: Double = 340
    @State private var dragStartWidth: Double?

    public init(store: ClipStore, environment: AppEnvironment) {
        _model = State(initialValue: LibraryViewModel(
            store: store, coordinator: environment.paste, editor: environment.externalEditor,
            enrichment: environment.enrichment, settings: environment.settings))
        self.environment = environment
    }

    public var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            // Expanded, the detail pane takes the whole pane rather than a column, so a
            // double-clicked image gets the room it needs.
            if model.isDetailExpanded, let selected = model.singleSelection {
                ClipDetailPane(clip: selected, model: model, environment: environment)
            } else {
                // An explicit width with a draggable divider, rather than HSplitView.
                //
                // HSplitView owns its divider position and treats idealWidth as a hint applied on
                // first layout only, so returning from the expanded view rebuilt the split and
                // gave the detail pane whatever proportion it felt like — about 30% of the window,
                // regardless of how wide it had been. Holding the width ourselves means restoring
                // is exact.
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        clipsPane
                            .frame(maxWidth: .infinity)
                        if model.singleSelection != nil {
                            detailDivider(in: proxy.size.width)
                        }
                        if let selected = model.singleSelection {
                            ClipDetailPane(clip: selected, model: model, environment: environment)
                                .frame(width: clampedDetailWidth(in: proxy.size.width))
                        }
                    }
                }
            }
        }
        .persistentWindowFrame("ClipDroidLibrary", minSize: NSSize(width: 760, height: 460))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search clips")
        .toolbar { toolbarContent }
        .task { model.start() }
    }

    /// Keeps the pane usable whatever the window size — a remembered 600pt on a narrow window
    /// would otherwise leave no room for the clips themselves.
    private func clampedDetailWidth(in available: Double) -> Double {
        let maximum = max(280, min(700, available * 0.6))
        return min(max(detailWidth, 260), maximum)
    }

    /// A draggable divider. Dragging updates the remembered width directly, so what is restored is
    /// exactly what the user last set.
    private func detailDivider(in available: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .overlay(Divider())
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStartWidth ?? detailWidth
                        dragStartWidth = start
                        // Dragging left widens the detail pane, since it sits on the right.
                        detailWidth = min(max(start - value.translation.width, 260),
                                          max(280, min(700, available * 0.6)))
                    }
                    .onEnded { _ in dragStartWidth = nil })
    }

    private var clipsPane: some View {
        VStack(spacing: 0) {
            // Only under "All Clips".
            //
            // Within a Type section they contradict the sidebar — picking Images in the sidebar
            // and then Text in the chips can only ever produce nothing — and within an App or Tag
            // they are a second, quieter copy of a filter already applied. Showing them
            // everywhere made the two rows argue with each other.
            if model.section == .all {
                TypeFilterChips(model: model)
                Divider()
            }
            if model.clips.isEmpty {
                emptyState
            } else {
                switch model.layout {
                case .timeline, .list:
                    ClipRowsView(model: model, dense: model.layout == .list)
                case .grid:
                    ClipGridView(model: model)
                }
            }
        }
        .frame(minWidth: 380)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.searchText.isEmpty ? "No clips here" : "No matches",
                  systemImage: "doc.on.clipboard")
        } description: {
            Text(model.searchText.isEmpty
                 ? "Copy something — your clipboard history starts here."
                 : "Try a different search, or clear the filters.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.layout == .grid {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3").font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $model.tileSize, in: 90...320)
                        .frame(width: 110)
                    Image(systemName: "square.grid.2x2").font(.body)
                        .foregroundStyle(.secondary)
                }
                .help("Tile size")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Layout", selection: $model.layout) {
                ForEach(LibraryLayout.allCases, id: \.self) { layout in
                    Image(systemName: layout.symbolName).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .help("Timeline, grid or list")
        }
        ToolbarItem(placement: .primaryAction) {
            // Bulk actions appear only with a multi-selection, rather than sitting greyed out.
            if model.selection.count > 1 {
                Menu {
                    Button("Pin", systemImage: "pin") { model.setPinnedOnSelection(true) }
                    Button("Unpin", systemImage: "pin.slash") { model.setPinnedOnSelection(false) }
                    Button("Favourite", systemImage: "star") { model.setFavoriteOnSelection(true) }
                    Divider()
                    Button("Delete \(model.selection.count) clips", systemImage: "trash",
                           role: .destructive) { model.deleteSelection() }
                } label: {
                    Label("\(model.selection.count) selected", systemImage: "checklist")
                }
            }
        }
    }
}

struct LibrarySidebar: View {
    @Bindable var model: LibraryViewModel
    @State private var isAddingCategory = false
    @State private var newCategoryName = ""
    // Remembered across launches: a sidebar the user collapsed should stay collapsed.
    @AppStorage("library.sidebar.tagsExpanded") private var tagsExpanded = true
    @AppStorage("library.sidebar.appsExpanded") private var appsExpanded = true
    @AppStorage("library.sidebar.typesExpanded") private var typesExpanded = true

    var body: some View {
        List(selection: Binding(
            get: { model.section },
            set: { if let new = $0 { model.section = new } }
        )) {
            Section {
                row(.all, "All Clips", "tray.full", count: model.totalCount)
                row(.pinned, "Pinned", "pin")
                row(.favorites, "Favourites", "star")
            }

            Section {
                ForEach(model.categories) { category in
                    HStack {
                        Image(systemName: category.iconName ?? "folder")
                            .foregroundStyle(category.colorHex.flatMap { Color(hex: $0) } ?? .accentColor)
                        Text(category.name)
                        Spacer()
                        if let count = model.categoryCounts[category.id], count > 0 {
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(LibrarySection.category(category.id))
                    .contextMenu {
                        Button("Delete category", systemImage: "trash", role: .destructive) {
                            model.deleteCategory(category)
                        }
                        // Worth saying: deleting a label must not look like it deletes content.
                        Text("Clips stay in your history")
                    }
                }
                Button("New Category…", systemImage: "plus") { isAddingCategory = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } header: {
                Text("Categories")
            }

            Section(isExpanded: $typesExpanded) {
                ForEach(ClipContentType.allCases.filter { model.typeCounts[$0] ?? 0 > 0 }, id: \.self) { type in
                    row(.type(type), type.displayName, type.symbolName, count: model.typeCounts[type])
                }
            } header: {
                Text("Types")
            }

            if !model.tagCounts.isEmpty {
                Section(isExpanded: $tagsExpanded) {
                    ForEach(model.tagCounts, id: \.name) { tag in
                        HStack {
                            Image(systemName: "tag")
                            Text(tag.name)
                            Spacer()
                            Text("\(tag.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .tag(LibrarySection.tag(tag.name))
                    }
                } header: {
                    Text("Tags")
                }
            }

            Section(isExpanded: $appsExpanded) {
                ForEach(model.sourceApps.prefix(12), id: \.bundleId) { app in
                    HStack {
                        AppIcon(bundleId: app.bundleId, side: 15)
                        Text(app.name.isEmpty ? app.bundleId : app.name)
                        Spacer()
                        Text("\(app.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .tag(LibrarySection.app(app.bundleId))
                }
            } header: {
                Text("Apps")
            }
        }
        .listStyle(.sidebar)
        .alert("New Category", isPresented: $isAddingCategory) {
            TextField("Name", text: $newCategoryName)
            Button("Cancel", role: .cancel) { newCategoryName = "" }
            Button("Create") {
                let name = newCategoryName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.createCategory(named: name) }
                newCategoryName = ""
            }
        }
    }

    private func row(_ section: LibrarySection, _ title: String, _ symbol: String,
                     count: Int? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            if let count, count > 0 {
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .tag(section)
    }
}

struct TypeFilterChips: View {
    @Bindable var model: LibraryViewModel

    private var available: [ClipContentType] {
        ClipContentType.allCases.filter { (model.typeCounts[$0] ?? 0) > 0 }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", isOn: model.activeTypes.isEmpty) { model.activeTypes = [] }
                ForEach(available, id: \.self) { type in
                    chip(type.displayName, isOn: model.activeTypes.contains(type)) {
                        if model.activeTypes.contains(type) {
                            model.activeTypes.remove(type)
                        } else {
                            model.activeTypes.insert(type)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: Capsule())
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

extension ClipContentType {
    var displayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .image: "Images"
        case .screenshot: "Screenshots"
        case .file: "Files"
        case .color: "Colours"
        case .code: "Code"
        case .link: "Links"
        case .note: "Notes"
        case .multiClip: "Multi-clip"
        case .unknown: "Other"
        }
    }
}
