import Testing
import Foundation
@testable import ClipRoidKit
import ClipRoidCore
import ClipRoidStore
import ClipRoidPlatform

@Suite("File clips")
struct FileClipTests {

    private func scratchFile(_ name: String, contents: String = "col1,col2\n1,2\n") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClipRoidFileTests-\(UUID().uuidString)-\(name)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func open(_ scratch: ScratchDirectory) async throws -> ClipStore {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        return store
    }

    /// Copying a file in some apps puts an icon on the pasteboard alongside the file URL. Testing
    /// images first classified those as pictures, so the clip held a picture of the file rather
    /// than the file — and pasting produced the icon, not the document.
    @Test("A file with an icon alongside it is still a file, not an image")
    func filesBeatImages() throws {
        let url = try scratchFile("book.xlsx")
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = RawSnapshot(
            changeCount: 1,
            declaredTypes: ["public.file-url", "public.tiff"],
            imageData: Data([0x4D, 0x4D, 0x00, 0x2A]),  // an icon rides along
            fileURLs: [url],
            sourceAppBundleId: "com.apple.finder", sourceAppName: "Finder")

        #expect(ClipClassifier.classify(snapshot)?.contentType == .file)
    }

    @Test("An image with no file URL is still an image")
    func imagesStillClassify() {
        let snapshot = RawSnapshot(
            changeCount: 1, declaredTypes: ["public.png"],
            imageData: Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(ClipClassifier.classify(snapshot)?.contentType == .image)
    }

    @Test("A file clip records the real size and type of each file")
    func recordsFileMetadata() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let url = try scratchFile("data.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try #require(ClipClassifier.classify(RawSnapshot(
            changeCount: 1, declaredTypes: ["public.file-url"], fileURLs: [url])))
        let summary = try await store.insert(clip)

        let files = try await store.files(forClip: summary.id)
        #expect(files.count == 1)
        #expect(files.first?.url.lastPathComponent == url.lastPathComponent)
        #expect(files.first?.sizeBytes == 14)
        #expect(files.first?.uti == "public.comma-separated-values-text")
        await store.close()
    }

    @Test("Several files copied together are all recorded, in order")
    func recordsMultipleFiles() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let first = try scratchFile("a.csv")
        let second = try scratchFile("b.csv")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let clip = try #require(ClipClassifier.classify(RawSnapshot(
            changeCount: 1, declaredTypes: ["public.file-url"], fileURLs: [first, second])))
        let summary = try await store.insert(clip)

        let files = try await store.files(forClip: summary.id)
        #expect(files.map(\.url.lastPathComponent) == [first.lastPathComponent,
                                                        second.lastPathComponent])
        await store.close()
    }

    /// The paths stay in the body so a file clip is findable by name.
    @Test("File clips are searchable by filename")
    func searchableByName() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let url = try scratchFile("quarterly-report.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try #require(ClipClassifier.classify(RawSnapshot(
            changeCount: 1, declaredTypes: ["public.file-url"], fileURLs: [url])))
        try await store.insert(clip)

        #expect(try await store.search("quarterly").count == 1)
        await store.close()
    }
}

/// Putting a clip back on the pasteboard.
///
/// Capture was never the problem here: a copied file was stored correctly as a `.file` clip with
/// its path in the `files` table. But a file clip's *full text* is its path, and several "copy
/// this clip" paths built `.text(fullText)` themselves rather than going through the coordinator —
/// so loading a copied document into the clipboard and pasting it into Notes produced
/// `/Users/…/PROJECTS.md` instead of the document. Auto-paste used the coordinator and worked,
/// which is what made it look like a problem with the receiving app.
@Suite("Clipboard payloads")
struct ClipboardPayloadTests {

    private func scratchFile(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClipRoidPayload-\(UUID().uuidString)-\(name)")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeCoordinator(_ store: ClipStore) async -> PasteCoordinator {
        await PasteCoordinator(
            store: store, pasteboard: await SystemPasteboard(),
            deliverer: PasteDeliverer(), frontmost: WorkspaceFrontmostAppProvider())
    }

    private func open(_ scratch: ScratchDirectory) async throws -> ClipStore {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        return store
    }

    @Test("A file clip goes back on the pasteboard as the file, not its path")
    func fileClipPastesAsFile() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let url = try scratchFile("PROJECTS.md")
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await store.insert(CapturedClip(
            contentType: .file, contentHash: Dedupe.hash(url.path), body: url.path,
            fileURLs: [url]))

        let payload = await makeCoordinator(store).clipboardPayload(for: summary)
        guard case .files(let urls) = payload else {
            Issue.record("expected .files, got \(String(describing: payload))")
            return
        }
        #expect(urls.map(\.path) == [url.path])
        await store.close()
    }

    @Test("Several copied files all come back")
    func multipleFiles() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let a = try scratchFile("a.txt")
        let b = try scratchFile("b.txt")
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        let summary = try await store.insert(CapturedClip(
            contentType: .file, contentHash: Dedupe.hash(a.path + b.path),
            body: "\(a.path)\n\(b.path)", fileURLs: [a, b]))

        guard case .files(let urls) = await makeCoordinator(store).clipboardPayload(for: summary) else {
            Issue.record("expected .files")
            return
        }
        #expect(Set(urls.map(\.path)) == Set([a.path, b.path]))
        await store.close()
    }

    /// A file moved or deleted since it was copied cannot be pasted as a file. Handing over the
    /// path as text is worse than the document but better than a broken reference the receiving
    /// app silently drops.
    @Test("A file that no longer exists degrades to its path")
    func missingFileFallsBackToText() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let url = try scratchFile("gone.txt")

        let summary = try await store.insert(CapturedClip(
            contentType: .file, contentHash: Dedupe.hash(url.path), body: url.path,
            fileURLs: [url]))
        try FileManager.default.removeItem(at: url)

        guard case .text(let text) = await makeCoordinator(store).clipboardPayload(for: summary) else {
            Issue.record("expected .text for a missing file")
            return
        }
        #expect(text == url.path)
        await store.close()
    }

    @Test("Ordinary text clips are unaffected")
    func textIsStillText() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let summary = try await store.insert(CapturedClip(
            contentType: .text, contentHash: Dedupe.hash("plain"), body: "plain"))

        guard case .text(let text) = await makeCoordinator(store).clipboardPayload(for: summary) else {
            Issue.record("expected .text")
            return
        }
        #expect(text == "plain")
        await store.close()
    }
}
