import Testing
import Foundation
import AppKit
@testable import ClipRoidKit
import ClipRoidCore
import ClipRoidStore
import ClipRoidPlatform

/// Exercises the real Vision framework rather than a stub.
///
/// The rest of the enrichment suite uses `StubRecognizer`, which is the right default — it tests
/// ClipRoid's behaviour rather than Apple's OCR accuracy, and runs in milliseconds. This suite
/// exists to catch the thing a stub structurally cannot: that the real pipeline, from image bytes
/// through Vision and into the FTS index, actually joins up.
@Suite("Vision OCR integration")
struct VisionIntegrationTests {

    /// Renders real text so Vision has something genuine to read.
    private func renderTextImage(_ text: String) throws -> Data {
        let size = NSSize(width: 900, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 30, y: 70), withAttributes: [
            .font: NSFont.systemFont(ofSize: 48),
            .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test("Text visible only inside a screenshot becomes searchable")
    func realOCRFeedsTheIndex() async throws {
        let scratch = ScratchDirectory()
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)

        let png = try renderTextImage("Connection refused port 5432")
        try await store.insert(CapturedClip(
            contentType: .screenshot,
            contentHash: Dedupe.hash(png),
            sourceAppBundleId: "com.apple.screencapture",
            sourceAppName: "Screenshot",
            contentSizeBytes: Int64(png.count),
            imageData: png,
            enrichmentState: .pending))

        // Nothing about this clip is searchable yet — the text exists only as pixels.
        #expect(try await store.search("5432").isEmpty)

        await EnrichmentPipeline(store: store, recognizer: VisionTextRecognizer()).drainOnce()

        #expect(try await store.search("5432").count == 1)
        #expect(try await store.search("refused").count == 1)
        await store.close()
    }
}
