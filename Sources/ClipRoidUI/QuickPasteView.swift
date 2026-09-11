import SwiftUI
import ClipRoidCore
import ClipRoidKit

/// The Quick Paste window's contents: search field, results, keyboard hints.
///
/// Mouseless operation is the primary path (spec §4.4), so every affordance here is reachable from
/// the keyboard and the mouse is a convenience rather than a requirement.
struct QuickPasteView: View {
    @Bindable var model: QuickPasteViewModel
    var onDismiss: @MainActor () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if model.results.isEmpty {
                emptyState
            } else {
                resultsList
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        .onAppear { focusSearchField() }
        // Re-focus on every open, not just the first. See QuickPasteViewModel.focusNonce.
        .onChange(of: model.focusNonce) { _, _ in focusSearchField() }
        .overlay(alignment: .bottom) { hud }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search clips…", text: $model.queryText)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($searchFocused)
                .onSubmit { Task { await paste() } }
                // Arrow keys must move the selection even though the text field has focus, or
                // mouseless operation is impossible.
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.escape) { onDismiss(); return .handled }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, clip in
                        QuickPasteRow(clip: clip, isSelected: index == model.selectedIndex)
                            .id(clip.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedIndex = index
                                Task { await paste() }
                            }
                    }
                }
            }
            .onChange(of: model.selectedIndex) { _, new in
                guard model.results.indices.contains(new) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.results[new].id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(model.queryText.isEmpty ? "No clips yet" : "No matches")
                .foregroundStyle(.secondary)
            if model.queryText.isEmpty {
                Text("Copy something — your clipboard history starts here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Navigate")
            hint("↩", "Paste")
            hint("esc", "Close")
            Spacer()
            if !model.results.isEmpty {
                Text("\(model.results.count) clip\(model.results.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var hud: some View {
        if let message = model.hudMessage {
            Text(message)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .padding(.bottom, 44)
                .transition(.opacity)
        }
    }

    /// Deferred by a turn of the run loop: `NSApp.activate()` is asynchronous, and setting focus
    /// before the window is key silently does nothing.
    private func focusSearchField() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            searchFocused = true
        }
    }

    private func paste() async {
        let outcome = await model.pasteSelection()
        // A delivered paste closes the panel immediately. A clipboard-only paste leaves it up
        // briefly so the "press ⌘V" hint is actually readable.
        switch outcome {
        case .pasted, .none:
            onDismiss()
        case .clipboardOnly:
            try? await Task.sleep(for: .milliseconds(1400))
            onDismiss()
        }
    }
}

struct QuickPasteRow: View {
    let clip: ClipSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: clip.contentType.symbolName)
                .frame(width: 22)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))

            VStack(alignment: .leading, spacing: 1) {
                Text(clip.sensitivity == .secret ? "••••••••••••" : clip.displayText)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let app = clip.sourceAppName { Text(app) }
                    ClipTimestamp(date: clip.copiedAt)
                }
                .font(.caption2)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }

            Spacer(minLength: 4)

            if clip.sensitivity == .secret {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.orange))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }
}
