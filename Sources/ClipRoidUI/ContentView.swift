import SwiftUI
import ClipRoidCore
import ClipRoidKit

public struct ContentView: View {
    @State private var model: TimelineViewModel
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: TimelineViewModel(store: environment.store))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.clips.isEmpty {
                    ContentUnavailableView(
                        "No clips yet",
                        systemImage: "doc.on.clipboard",
                        description: Text("Copy something — your clipboard history starts here.")
                    )
                } else {
                    List(model.clips) { clip in
                        ClipRow(clip: clip)
                            .contentShape(Rectangle())
                            .onTapGesture { paste(clip) }
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { paste(clip) }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    model.delete(clip)
                                }
                            }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("ClipRoid")
        }
        .task { model.start() }
    }

    private func paste(_ clip: ClipSummary) {
        Task {
            guard let text = try? await environment.store.fullText(id: clip.id) else { return }
            await environment.pasteboard.write(.text(text), originClipUUID: clip.uuid)
        }
    }
}

struct ClipRow: View {
    let clip: ClipSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: clip.contentType.symbolName)
                .font(.system(size: 16))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.sensitivity == .secret ? "••••••••••••" : clip.preview)
                    .lineLimit(2)
                    .font(.body)
                HStack(spacing: 6) {
                    if let app = clip.sourceAppName {
                        Text(app)
                    }
                    Text(clip.copiedAt, style: .relative)
                    if clip.repeatCount > 1 {
                        Text("×\(clip.repeatCount)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if clip.sensitivity == .secret {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.orange)
                    .help("Contains what looks like a secret — hidden by default")
            }
        }
        .padding(.vertical, 4)
    }
}

extension ClipContentType {
    var symbolName: String {
        switch self {
        case .text, .note: "textformat"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .screenshot: "camera.viewfinder"
        case .file: "doc"
        case .color: "paintpalette"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .multiClip: "square.stack"
        case .unknown: "questionmark.square.dashed"
        }
    }
}
