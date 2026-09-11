import Testing
import Foundation
import CoreGraphics
@testable import ClipRoidKit
import ClipRoidCore
import ClipRoidStore
import ClipRoidImaging

/// A stand-in for Vision, so the pipeline's behaviour is tested rather than Apple's OCR accuracy.
struct StubRecognizer: TextRecognizing {
    var result: String?
    var error: (any Error)?

    func recognizeText(in imageData: Data) async throws -> String? {
        if let error { throw error }
        return result
    }
}

struct RecognizerFailure: Error {}

@Suite("Enrichment pipeline")
struct EnrichmentTests {

    private func makePNG(width: Int = 200, height: Int = 120) throws -> Data {
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        return try #require(Thumbnailer.encodePNG(image))
    }

    private func openStore(_ scratch: ScratchDirectory) async throws -> ClipStore {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        return store
    }

    private func imageClip(_ data: Data) -> CapturedClip {
        CapturedClip(
            contentType: .image,
            contentHash: Dedupe.hash(data),
            sourceAppBundleId: "com.apple.screencapture",
            sourceAppName: "Screenshot",
            contentSizeBytes: Int64(data.count),
            imageData: data,
            enrichmentState: .pending)
    }

    /// The point of the whole enrich-later design: OCR lands minutes after capture, updates one
    /// row, and the FTS trigger makes it searchable with no reindex.
    @Test("OCR text becomes searchable after enrichment")
    func ocrTextBecomesSearchable() async throws {
        let scratch = ScratchDirectory()
        let store = try await openStore(scratch)
        let pipeline = EnrichmentPipeline(
            store: store, recognizer: StubRecognizer(result: "Connection refused on port 5432"))

        let summary = try await store.insert(imageClip(try makePNG()))
        #expect(try await store.search("5432").isEmpty, "not searchable before enrichment")

        await pipeline.drainOnce()

        let hits = try await store.search("5432")
        #expect(hits.map(\.id) == [summary.id], "searchable by its visible text after enrichment")
        await store.close()
    }

    @Test("Enrichment writes a thumbnail and records image dimensions")
    func producesThumbnailAndDimensions() async throws {
        let scratch = ScratchDirectory()
        let store = try await openStore(scratch)
        let pipeline = EnrichmentPipeline(store: store, recognizer: StubRecognizer(result: nil))

        let summary = try await store.insert(imageClip(try makePNG(width: 640, height: 480)))
        #expect(try await store.summary(id: summary.id)?.thumbnailPath == nil)

        await pipeline.drainOnce()

        let path = try #require(try await store.summary(id: summary.id)?.thumbnailPath)
        let thumb = try #require(await store.imageData(forBlobPath: path))
        let info = try #require(Thumbnailer.inspect(thumb))
        #expect(max(info.width, info.height) <= Thumbnailer.maxThumbnailDimension)
        await store.close()
    }

    @Test("A drained clip is not picked up again")
    func doesNotReprocess() async throws {
        let scratch = ScratchDirectory()
        let store = try await openStore(scratch)
        let pipeline = EnrichmentPipeline(store: store, recognizer: StubRecognizer(result: "once"))

        try await store.insert(imageClip(try makePNG()))
        #expect(await pipeline.drainOnce() == 1)
        #expect(await pipeline.drainOnce() == 0, "backlog must drain, not loop")
        await store.close()
    }

    /// A permanently failing job at the head of the backlog would starve everything behind it, so
    /// failure has to be terminal rather than retried forever.
    @Test("A failing OCR still resolves the job instead of retrying forever")
    func failureIsTerminal() async throws {
        let scratch = ScratchDirectory()
        let store = try await openStore(scratch)
        let pipeline = EnrichmentPipeline(
            store: store, recognizer: StubRecognizer(error: RecognizerFailure()))

        try await store.insert(imageClip(try makePNG()))
        #expect(await pipeline.drainOnce() == 1)
        #expect(await pipeline.drainOnce() == 0, "a failed job must not stay in the backlog")
        await store.close()
    }

    @Test("Text clips are not queued for enrichment at all")
    func textClipsSkipEnrichment() async throws {
        let scratch = ScratchDirectory()
        let store = try await openStore(scratch)
        try await store.insert(CapturedClip(
            contentType: .text, contentHash: Dedupe.hash("plain"), body: "plain",
            enrichmentState: .notApplicable))
        #expect(try await store.pendingEnrichment().isEmpty)
        await store.close()
    }
}

@Suite("Retention sweeper")
struct RetentionSweeperTests {
    private func openStore(_ scratch: ScratchDirectory) async throws -> ClipStore {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        return store
    }

    @Test("Sweeping enforces the count limit and removes blobs with the rows")
    func sweepsAndRemovesBlobs() async throws {
        let scratch = ScratchDirectory()
        let store = try await openStore(scratch)

        // Long enough to be spilled to a blob file, so blob cleanup is observable.
        for i in 1...6 {
            let body = String(repeating: "\(i)", count: SizeLimits.textBlobThreshold + 256)
            try await store.insert(CapturedClip(
                contentType: .text, contentHash: Dedupe.hash(body), body: body,
                copiedAt: Date().addingTimeInterval(Double(i))))
        }
        #expect(try await store.count() == 6)

        let sweeper = RetentionSweeper(store: store, policy: RetentionPolicy(maxClipCount: 2))
        let purged = await sweeper.sweep()

        #expect(purged.count == 4)
        #expect(try await store.count() == 2)

        let remaining = FileManager.default
            .enumerator(at: scratch.url.appendingPathComponent("clips"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "txt" }.count ?? 0
        #expect(remaining == 2, "retention must reclaim bytes, not just rows")
        await store.close()
    }

    @Test("Search survives a retention sweep with the index intact")
    func indexStaysConsistent() async throws {
        let scratch = ScratchDirectory()
        let store = try await openStore(scratch)
        for i in 1...5 {
            try await store.insert(CapturedClip(
                contentType: .text, contentHash: Dedupe.hash("term\(i)"), body: "term\(i) searchable",
                copiedAt: Date().addingTimeInterval(Double(i))))
        }
        await RetentionSweeper(store: store, policy: RetentionPolicy(maxClipCount: 2)).sweep()

        #expect(try await store.search("term1").isEmpty, "purged clips must leave the index")
        #expect(try await store.search("term5").count == 1, "surviving clips stay searchable")
        await store.close()
    }
}
