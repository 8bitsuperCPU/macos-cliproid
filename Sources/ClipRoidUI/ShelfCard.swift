import SwiftUI
import ClipRoidCore
import ClipRoidKit

/// One clip in the shelf.
struct ShelfCard: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel
    @Bindable var settings: SettingsStore
    var size: CGSize
    /// Which way the preview should open, so it does not open off-screen.
    var previewEdge: Edge = .bottom

    @State private var isHovered = false
    @State private var showPreview = false
    /// A clicked preview stays until dismissed, rather than vanishing when the pointer wanders.
    @State private var isPreviewPinned = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?
    /// True while the pointer is over the preview itself rather than the card.
    @State private var isPreviewHovered = false
    @State private var thumbnailURL: URL?
    @State private var preview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(10)
        .frame(width: size.width, height: size.height)
        // Opaque and independent of the panel background — see ShelfPalette.
        .background(isHovered ? ShelfPalette.cardHovered : ShelfPalette.card,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShelfPalette.cardBorder))
        .overlay(alignment: .top) { if isHovered { hoverActions } }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { inside in
            isHovered = inside
            hoverTask?.cancel()
            guard inside else {
                scheduleClose()
                return
            }
            closeTask?.cancel()
            // A short delay, so sweeping the pointer across the shelf to reach one card does not
            // fire a popover for every card it passes over.
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                showPreview = true
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: previewEdge) {
            ShelfPreview(
                clip: clip, model: model, settings: settings,
                isPinned: isPreviewPinned,
                onPin: { isPreviewPinned = true; closeTask?.cancel() },
                onClose: {
                    isPreviewPinned = false
                    closeTask?.cancel()
                    showPreview = false
                },
                onHoverChanged: { inside in
                    isPreviewHovered = inside
                    if inside {
                        // Reaching the preview keeps it open, which is what makes it clickable.
                        closeTask?.cancel()
                    } else {
                        scheduleClose()
                    }
                })
        }
        .onChange(of: showPreview) { _, shown in
            // Dismissing by clicking outside must clear the pin too, or the next hover reopens a
            // preview that is still marked pinned and can never be closed by leaving.
            if !shown { isPreviewPinned = false }
        }
        .onTapGesture { model.paste(clip) }
        .draggable(clip.displayText)
        .contextMenu { ShelfCardMenu(clip: clip, model: model) }
        // See TaskKey — enrichment lands under the same clip id, so keying on id alone leaves
        // the card showing a placeholder forever.
        .task(id: TaskKey(id: clip.id, thumbnail: clip.thumbnailPath)) {
            thumbnailURL = await model.thumbnailURL(for: clip)
            preview = await model.fullText(for: clip)
        }
    }

    @ViewBuilder
    private var content: some View {
        if clip.sensitivity == .secret {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "eye.slash").font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text("Hidden")
                    .font(.system(size: 11))
                    .foregroundStyle(ShelfPalette.cardSecondaryText)
            }
        } else if let hex = clip.colorHex, let colour = Color(hex: hex) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5).fill(colour).frame(width: 26, height: 26)
                Text(hex)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ShelfPalette.cardPrimaryText)
            }
        } else if let thumbnailURL {
            AsyncImage(url: thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text(preview.isEmpty ? clip.displayText : preview)
                .font(.system(size: 11.5))
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .foregroundStyle(ShelfPalette.cardPrimaryText)
        }
    }

    private var lineLimit: Int { max(2, Int((size.height - 44) / 15)) }

    /// Closes the preview after a delay, unless the pointer reaches it first.
    ///
    /// Moving towards the preview necessarily leaves the card that opened it, so closing
    /// immediately makes the preview impossible to click — it disappears while you are travelling
    /// to it. The delay is the width of that gap.
    private func scheduleClose() {
        guard !isPreviewPinned else { return }
        closeTask?.cancel()
        let delay = settings.previewCloseDelay
        closeTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard !isPreviewPinned, !isPreviewHovered, !isHovered else { return }
            showPreview = false
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            AppIcon(bundleId: clip.sourceAppBundleId, side: 13)
            ClipTimestamp(date: clip.copiedAt, font: .system(size: 10))
                .foregroundStyle(ShelfPalette.cardSecondaryText)
            Spacer(minLength: 0)
            if clip.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
            if clip.isFavorite {
                Image(systemName: "star.fill").font(.system(size: 8))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.top, 6)
    }

    /// Appears over the card on hover, as in the reference.
    private var hoverActions: some View {
        HStack(spacing: 2) {
            action("list.bullet.indent", "Copy without pasting") { model.copyOnly(clip) }
            Spacer(minLength: 0)
            action("trash", "Delete") { model.delete(clip) }
            action(clip.isFavorite ? "star.fill" : "star",
                   clip.isFavorite ? "Remove favourite" : "Favourite") {
                model.toggleFavourite(clip)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ShelfPalette.cardPrimaryText)
                .frame(width: 19, height: 19)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ShelfCardMenu: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel

    var body: some View {
        if !model.categories.isEmpty {
            Menu("Collection") {
                ForEach(model.categories) { category in
                    Button(category.name) { model.assign(clip, to: category) }
                }
            }
        }
        Button(clip.isPinned ? "Unpin" : "Pin", systemImage: "pin") { model.togglePin(clip) }
        Button(clip.isFavorite ? "Remove favourite" : "Favourite", systemImage: "star") {
            model.toggleFavourite(clip)
        }
        Divider()
        Button("Copy", systemImage: "doc.on.doc") { model.copyOnly(clip) }
        if clip.contentType == .image || clip.contentType == .screenshot {
            Button("Copy Text from Image", systemImage: "text.viewfinder") {
                model.copyTextFromImage(clip)
            }
        }
        if let hex = clip.colorHex {
            Menu("Copy Colour As") {
                ForEach(ColorFormats.allCases, id: \.self) { format in
                    if let text = ColorFormats.string(format, fromHex: hex) {
                        Button(text) { model.copyColour(clip, as: format) }
                    }
                }
            }
        }
        Button("Edit in Default App", systemImage: "pencil") { model.editExternally(clip) }
        Button("Paste", systemImage: "arrow.down.doc") { model.paste(clip) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(clip) }
    }
}

/// The expanded preview shown when the pointer rests on a card (spec §4.3).
///
/// Sized as a fraction of the screen rather than a fixed point size, so it is proportionate on a
/// laptop display and on a 34-inch monitor alike.
struct ShelfPreview: View {
    let clip: ClipSummary
    @Bindable var model: ShelfViewModel
    @Bindable var settings: SettingsStore
    /// Set once the user clicks: the preview then stays until they dismiss it.
    var isPinned: Bool
    var onPin: () -> Void
    var onClose: () -> Void
    /// Reports the pointer entering or leaving the preview, so the card can hold it open.
    var onHoverChanged: (Bool) -> Void = { _ in }

    @State private var thumbnailURL: URL?
    @State private var fullText = ""
    @State private var ocrText: String?

    private var height: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return screen * CGFloat(settings.previewHeightFraction)
    }

    private var width: CGFloat { min(height * 1.25, 900) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(14)
        .frame(width: width, height: height)
        // A click anywhere pins the preview, so it survives the pointer leaving the card.
        .contentShape(Rectangle())
        .onTapGesture { onPin() }
        .onHover { onHoverChanged($0) }
        .contextMenu { ShelfCardMenu(clip: clip, model: model) }
        .task(id: TaskKey(id: clip.id, thumbnail: clip.thumbnailPath)) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppIcon(bundleId: clip.sourceAppBundleId, side: 15)
            Text(clip.sourceAppName ?? "Unknown").font(.callout.weight(.medium))

            badge(clip.contentType.displayName)
            if let size = clip.imageSize {
                badge("\(size.width) × \(size.height)")
            }
            if clip.contentSizeBytes > 0 {
                badge(ByteCountFormatter.string(
                    fromByteCount: clip.contentSizeBytes, countStyle: .file))
            }

            Spacer()

            if isPinned {
                // Tools appear only once pinned. On an unpinned preview they would be unusable —
                // reaching for one means leaving the card, and the preview is on its way out.
                toolbar
            } else {
                ClipTimestamp(date: clip.copiedAt, font: .caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The pinned preview's tools, following the reference screenshots.
    private var toolbar: some View {
        HStack(spacing: 4) {
            tool("doc.on.doc", "Copy") { model.copyOnly(clip) }

            if clip.colorHex != nil {
                Menu {
                    ForEach(ColorFormats.allCases, id: \.self) { format in
                        if let text = ColorFormats.string(format, fromHex: clip.colorHex ?? "") {
                            Button(text) { model.copyColour(clip, as: format) }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
                .help("Copy in another format")
            }

            if clip.contentType == .image || clip.contentType == .screenshot {
                tool("text.viewfinder", "Copy text from image") {
                    model.copyTextFromImage(clip)
                    Task {
                        // Reflect the recognised text straight away rather than making the user
                        // reopen the preview to see it.
                        try? await Task.sleep(for: .milliseconds(400))
                        ocrText = await model.existingOCRText(for: clip)
                    }
                }
            }

            tool("pencil", "Edit in default app") { model.editExternally(clip) }
            tool(clip.isFavorite ? "star.fill" : "star",
                 clip.isFavorite ? "Remove favourite" : "Favourite") {
                model.toggleFavourite(clip)
            }
            tool("trash", "Delete") {
                model.delete(clip)
                onClose()
            }
            tool("xmark", "Close", action: onClose)
        }
    }

    private func tool(_ symbol: String, _ help: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 22)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        if clip.sensitivity == .secret {
            VStack(spacing: 6) {
                Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.orange)
                Text("Hidden — this looks like a secret").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let hex = clip.colorHex, let colour = Color(hex: hex) {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10).fill(colour)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ColorFormats.allCases, id: \.self) { format in
                        if let text = ColorFormats.string(format, fromHex: hex) {
                            HStack {
                                Text(format.displayName)
                                    .font(.caption).foregroundStyle(.tertiary)
                                    .frame(width: 48, alignment: .leading)
                                Text(text).font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let thumbnailURL {
            imageContent(url: thumbnailURL)
        } else {
            ScrollView {
                Text(fullText.isEmpty ? clip.displayText : fullText)
                    .font(.system(.body,
                                  design: clip.contentType == .code ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Small images are shown at their natural size and centred; large ones are scaled down to fit.
    ///
    /// `.aspectRatio(contentMode: .fit)` alone scales in *both* directions, so a 60×20 favicon
    /// would be blown up to fill the window — enormous, blurry, and a worse view of the clip than
    /// the card already gives.
    @ViewBuilder
    private func imageContent(url: URL) -> some View {
        GeometryReader { proxy in
            AsyncImage(url: url) { image in
                if shouldScaleDown(in: proxy.size) {
                    image.resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Natural size, centred.
                    image
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } placeholder: {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func shouldScaleDown(in available: CGSize) -> Bool {
        guard let size = clip.imageSize else { return true }
        return CGFloat(size.width) > available.width || CGFloat(size.height) > available.height
    }

    @ViewBuilder
    private var footer: some View {
        if let ocrText, !ocrText.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "text.viewfinder").font(.caption)
                Text(ocrText.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption).lineLimit(1)
                Spacer()
                Button("Copy Text") { model.copyTextFromImage(clip) }
                    .controlSize(.small)
            }
            .foregroundStyle(.secondary)
        } else {
            Text(isPinned ? "Click ✕ to close" : "Click to keep open · drag to any app")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func load() async {
        thumbnailURL = await model.thumbnailURL(for: clip)
        fullText = await model.fullText(for: clip)
        ocrText = await model.existingOCRText(for: clip)
    }
}
