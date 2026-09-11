import SwiftUI
import ClipRoidCore
import ClipRoidKit

/// The full Library window (spec §4.11).
public struct LibraryView: View {
    @Bindable var model: LibraryViewModel
    let environment: AppEnvironment

    public init(model: LibraryViewModel, environment: AppEnvironment) {
        self.model = model
        self.environment = environment
    }

    public var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            HSplitView {
                clipsPane
                if let selected = model.singleSelection {
                    ClipDetailPane(clip: selected, model: model, environment: environment)
                        .frame(minWidth: 280, idealWidth: 340)
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search clips")
        .toolbar { toolbarContent }
        .task { model.start() }
    }

    private var clipsPane: some View {
        VStack(spacing: 0) {
            TypeFilterChips(model: model)
            Divider()
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

            Section("Types") {
                ForEach(ClipContentType.allCases.filter { model.typeCounts[$0] ?? 0 > 0 }, id: \.self) { type in
                    row(.type(type), type.displayName, type.symbolName, count: model.typeCounts[type])
                }
            }

            Section("Apps") {
                ForEach(model.sourceApps.prefix(12), id: \.bundleId) { app in
                    row(.app(app.bundleId), app.name.isEmpty ? app.bundleId : app.name,
                        "app", count: app.count)
                }
            }
        }
        .listStyle(.sidebar)
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
