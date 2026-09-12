import Foundation
import AppKit
import UniformTypeIdentifiers
import ClipRoidCore
import ClipRoidStore
import os.log

/// Opens a clip in whichever app the system considers the default for its type, and saves edits
/// back (spec §4.11's "edit content", extended to binary types the detail panel cannot edit).
///
/// Why a temp file rather than an in-app editor: the system already knows which app should open a
/// PNG, a snippet of Swift, or an HTML fragment, and that answer is the user's own configuration.
/// Reimplementing even a fraction of those editors would be worse at all of them.
@MainActor
public final class ExternalEditor {
    private let store: ClipStore
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "ExternalEdit")

    /// Active sessions, keyed by clip id, so opening the same clip twice does not start two
    /// watchers fighting over it.
    private var sessions: [Int64: Session] = [:]

    public init(store: ClipStore) {
        self.store = store
    }

    private final class Session {
        let url: URL
        var lastModified: Date
        var timer: Timer?
        init(url: URL, lastModified: Date) {
            self.url = url
            self.lastModified = lastModified
        }
    }

    public enum EditResult: Sendable, Equatable {
        case opened
        /// The clip is a file, so the real file was opened and edits apply directly.
        case openedOriginal
        case unsupported(reason: String)
        case failed(String)
    }

    /// Exports the clip and hands it to the system's default application.
    @discardableResult
    public func edit(_ summary: ClipSummary) async -> EditResult {
        // A file clip already exists on disk. Opening a copy would edit the copy and leave the
        // user's actual file untouched — the opposite of what "edit" means here.
        if summary.contentType == .file {
            if let path = try? await store.fullText(id: summary.id),
               let first = path.split(separator: "\n").first {
                let url = URL(fileURLWithPath: String(first))
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return .unsupported(reason: "That file no longer exists.")
                }
                NSWorkspace.shared.open(url)
                return .openedOriginal
            }
            return .unsupported(reason: "That file could not be located.")
        }

        guard let (data, ext) = await payload(for: summary) else {
            return .unsupported(reason: "This kind of clip cannot be opened in another app.")
        }

        do {
            let url = try write(data, ext: ext, summary: summary)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                            as? Date) ?? Date()
            startWatching(summary: summary, url: url, modified: modified)
            NSWorkspace.shared.open(url)
            return .opened
        } catch {
            logger.error("External edit failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    private func payload(for summary: ClipSummary) async -> (Data, String)? {
        switch summary.contentType {
        case .image, .screenshot:
            guard let path = summary.thumbnailPath else { return nil }
            // The thumbnail is a downscaled preview; editing that would quietly destroy the
            // original's resolution. Reach for the full-size blob.
            let fullPath = path.replacingOccurrences(of: ".thumb.png", with: ".png")
            guard let data = await store.imageData(forBlobPath: fullPath) else { return nil }
            return (data, "png")

        case .richText:
            guard let text = try? await store.fullText(id: summary.id) else { return nil }
            return (Data(text.utf8), "html")

        case .text, .code, .link, .note, .color, .unknown, .multiClip:
            guard let text = try? await store.fullText(id: summary.id) else { return nil }
            return (Data(text.utf8), "txt")

        case .file:
            return nil
        }
    }

    private func write(_ data: Data, ext: String, summary: ClipSummary) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClipRoid-Edit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Named after the clip, not a random string, so the editor's title bar says something
        // recognisable rather than a UUID.
        let name = summary.displayText
            .prefix(28)
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = name.isEmpty ? "clip-\(summary.id)" : name
        let url = directory.appendingPathComponent("\(safe).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Watches the exported file and writes changes back to the clip.
    ///
    /// Polls the modification date rather than watching a file descriptor: most editors save by
    /// writing a new file and renaming it over the old one, which invalidates a descriptor-based
    /// watch on the very first save — the case it most needs to catch.
    private func startWatching(summary: ClipSummary, url: URL, modified: Date) {
        sessions[summary.id]?.timer?.invalidate()
        let session = Session(url: url, lastModified: modified)

        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForChanges(clipId: summary.id, type: summary.contentType) }
        }
        RunLoop.main.add(timer, forMode: .common)
        session.timer = timer
        sessions[summary.id] = session

        // Watching forever would keep a timer per clip ever opened. Half an hour covers a real
        // edit; after that the user can simply open it again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1_800) { [weak self] in
            self?.stopWatching(clipId: summary.id)
        }
    }

    private func checkForChanges(clipId: Int64, type: ClipContentType) {
        guard let session = sessions[clipId] else { return }
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: session.url.path)[.modificationDate] as? Date,
              modified > session.lastModified else { return }
        session.lastModified = modified

        Task { [weak self] in
            guard let self else { return }
            await self.saveBack(clipId: clipId, type: type, from: session.url)
        }
    }

    private func saveBack(clipId: Int64, type: ClipContentType, from url: URL) async {
        switch type {
        case .image, .screenshot:
            // Binary content is not edited in place by the store, so this is left alone for now
            // rather than silently doing nothing that looks like it worked.
            Diagnostics.log("External edit of an image is not saved back yet (clip \(clipId))")
        default:
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { return }
            do {
                try await store.updateText(id: clipId, to: text)
                Diagnostics.log("Saved external edit back to clip \(clipId)")
            } catch {
                logger.error("Could not save external edit: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func stopWatching(clipId: Int64) {
        sessions[clipId]?.timer?.invalidate()
        sessions[clipId] = nil
    }

    public func stopAll() {
        for (_, session) in sessions { session.timer?.invalidate() }
        sessions.removeAll()
    }
}
