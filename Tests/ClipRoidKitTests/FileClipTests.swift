import Testing
import Foundation
@testable import ClipRoidKit
import ClipRoidCore
import ClipRoidStore

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
