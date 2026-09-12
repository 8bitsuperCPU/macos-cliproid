import SwiftUI
import ClipRoidCore
import ClipRoidKit

/// The detail panel: full content, metadata, and the per-clip actions from spec §4.11.
struct ClipDetailPane: View {
    let clip: ClipSummary
    @Bindable var model: LibraryViewModel
    let environment: AppEnvironment

    @State private var fullText: String = ""
    @State private var draft: String = ""
    @State private var isEditing = false
    @State private var isRevealed = false
    @State private var thumbnailURL: URL?
    @State private var shortcutDraft: String = ""
    @State private var shortcutError: String?
    @State private var assignedCategories: Set<Int64> = []
    @State private var recognisedText: String?
    @State private var isRecognising = false
    @State private var tags: [String] = []
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    contentSection
                    recognisedTextSection
                    shortcutSection
                    categorySection
                    tagSection
                    metadataSection
                }
                .padding(14)
            }
            Divider()
            actions
        }
        .task(id: TaskKey(id: clip.id, thumbnail: clip.thumbnailPath)) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: clip.contentType.symbolName)
            Text(clip.contentType.displayName).font(.headline)
            Spacer()
            if clip.isPinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
            if clip.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var contentSection: some View {
        // A secret stays obscured until the user explicitly asks for it, per spec §4.7. The reveal
        // is per-viewing and deliberately not remembered.
        if clip.sensitivity == .secret && !isRevealed {
            VStack(alignment: .leading, spacing: 8) {
                Label("This looks like a secret", systemImage: "eye.slash")
                    .font(.callout.weight(.medium))
                Text("ClipRoid hides passwords, keys and tokens until you ask to see them.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reveal") { isRevealed = true }
                    .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } else if let url = thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 120)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if isEditing {
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack {
                    Button("Cancel") { draft = fullText; isEditing = false }
                    Button("Save") {
                        model.saveEdit(clip, newText: draft)
                        fullText = draft
                        isEditing = false
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft == fullText)
                }
            }
        } else {
            Text(fullText.isEmpty ? clip.preview : fullText)
                .font(.system(.body, design: clip.contentType == .code ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Text Vision found inside the image (spec §4.8).
    ///
    /// Shown in the detail panel as well as copied, because "Copy Text from Image" otherwise puts
    /// something on the clipboard the user cannot see — and if the recognition is poor, they have
    /// no way to tell before pasting it somewhere.
    @ViewBuilder
    private var recognisedTextSection: some View {
        if clip.contentType == .image || clip.contentType == .screenshot {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Text in image").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if isRecognising {
                        ProgressView().controlSize(.small)
                    } else if recognisedText == nil {
                        Button("Find text") { Task { await recogniseText() } }
                            .controlSize(.small)
                    } else {
                        Button("Copy") { model.copyTextFromImage(clip) }
                            .controlSize(.small)
                    }
                }

                if let recognisedText {
                    ScrollView {
                        Text(recognisedText)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                } else if !isRecognising {
                    Text("No text found yet.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func recogniseText() async {
        isRecognising = true
        defer { isRecognising = false }
        recognisedText = await model.recogniseText(in: clip)
    }

    /// Inline shortcut assignment (spec §4.5).
    @ViewBuilder
    private var shortcutSection: some View {
        if clip.contentType.isEditableText {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inline shortcut").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(
                        "\(environment.settings.shortcutPrefix)shortcut",
                        text: $shortcutDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { Task { await saveShortcut() } }
                    Button("Set") { Task { await saveShortcut() } }
                        .disabled(shortcutDraft == (clip.shortcut ?? ""))
                }
                if let shortcutError {
                    Text(shortcutError).font(.caption).foregroundStyle(.red)
                } else if !environment.settings.inlineShortcutsEnabled, clip.shortcut != nil {
                    // A shortcut that silently does nothing is worse than no shortcut at all.
                    Text("Shortcuts are saved but will not expand until you turn them on in Settings.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var categorySection: some View {
        if !model.categories.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Categories").font(.caption).foregroundStyle(.secondary)
                FlowRow {
                    ForEach(model.categories) { category in
                        let isOn = assignedCategories.contains(category.id)
                        Button {
                            Task {
                                await model.toggleCategory(category, on: clip)
                                assignedCategories = await model.categoryIds(for: clip)
                            }
                        } label: {
                            Text(category.name)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                            in: Capsule())
                                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tags").font(.caption).foregroundStyle(.secondary)
            FlowRow {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text(tag)
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .onTapGesture {
                        Task {
                            await model.removeTag(tag, from: clip)
                            tags = await model.tags(for: clip)
                        }
                    }
                }
            }
            TextField("Add a tag", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    let name = newTag.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        await model.addTag(name, to: clip)
                        tags = await model.tags(for: clip)
                        newTag = ""
                    }
                }
        }
    }

    private func saveShortcut() async {
        let trimmed = shortcutDraft.trimmingCharacters(in: .whitespaces)
        shortcutError = await model.setShortcut(
            trimmed.isEmpty ? nil : trimmed, on: clip,
            prefix: environment.settings.shortcutPrefixCharacter)
        if shortcutError == nil {
            await environment.shortcuts.refreshShortcuts()
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            metadata("Source", clip.sourceAppName ?? "Unknown")
            metadata("Copied", clip.copiedAt.formatted(date: .abbreviated, time: .shortened))
            metadata("Size", ByteCountFormatter.string(
                fromByteCount: clip.contentSizeBytes, countStyle: .file))
            if clip.repeatCount > 1 { metadata("Copied again", "\(clip.repeatCount) times") }
            if let hex = clip.colorHex { metadata("Colour", hex) }
            if let shortcut = clip.shortcut { metadata("Shortcut", shortcut) }
        }
        .font(.caption)
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Paste", systemImage: "doc.on.clipboard") {
                Task { await environment.paste.paste(clip) }
            }
            .help("Put this clip on the clipboard and paste it")

            Button(clip.isPinned ? "Unpin" : "Pin", systemImage: "pin") { model.togglePin(clip) }
            Button(clip.isFavorite ? "Unstar" : "Star", systemImage: "star") {
                model.toggleFavorite(clip)
            }

            // Only text is editable. Spec §12 rules out inline editing of binary content —
            // replacing an image means capturing a new one.
            if clip.contentType.isEditableText && !isEditing {
                Button("Edit", systemImage: "pencil") { isEditing = true }
            }

            Spacer()

            Button("Delete", systemImage: "trash", role: .destructive) {
                model.delete(ids: [clip.id])
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func load() async {
        isEditing = false
        isRevealed = false
        thumbnailURL = await model.thumbnailURL(for: clip)
        fullText = await model.fullText(for: clip)
        draft = fullText
        shortcutDraft = clip.shortcut ?? ""
        shortcutError = nil
        assignedCategories = await model.categoryIds(for: clip)
        recognisedText = await model.existingOCRText(for: clip)
        tags = await model.tags(for: clip)
        newTag = ""
    }
}

extension ClipContentType {
    var isEditableText: Bool {
        switch self {
        case .text, .code, .link, .note, .richText: true
        default: false
        }
    }
}


/// Wraps chips onto as many lines as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
