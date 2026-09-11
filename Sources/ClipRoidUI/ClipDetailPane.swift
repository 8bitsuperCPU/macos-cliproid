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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    contentSection
                    metadataSection
                }
                .padding(14)
            }
            Divider()
            actions
        }
        .task(id: clip.id) { await load() }
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
