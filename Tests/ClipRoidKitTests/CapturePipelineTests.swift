import Testing
import Foundation
@testable import ClipRoidKit
import ClipRoidCore
import ClipRoidStore

@Suite("Capture pipeline")
struct CapturePipelineTests {

    private func makeStore(_ scratch: ScratchDirectory) async throws -> ClipStore {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        return store
    }

    @Test("A copy from another app becomes one clip, attributed to that app")
    func capturesExternalCopy() async throws {
        let scratch = ScratchDirectory()
        let store = try await makeStore(scratch)
        let pb = await FakePasteboard()
        let poller = PasteboardPoller(
            pasteboard: pb,
            frontmost: StubFrontmostApp(app: SourceApp(bundleId: "com.apple.Safari", name: "Safari"))
        )
        let capture = CaptureCoordinator(poller: poller, store: store)

        await pb.externalCopy("hello from safari")
        await poller.tick()
        // tick() yields into the stream; drive the coordinator directly so the test does not race
        // an async consumer task.
        let snapshot = await pb.snapshot(
            sourceApp: SourceApp(bundleId: "com.apple.Safari", name: "Safari"),
            maxBytes: SizeLimits.defaultMaxCaptureBytes)
        try #require(snapshot != nil)
        await capture.ingest(snapshot!)

        let clips = try await store.recent()
        #expect(clips.count == 1)
        #expect(clips.first?.preview == "hello from safari")
        #expect(clips.first?.sourceAppName == "Safari")
        await store.close()
    }

    /// The regression test the whole `PasteboardActor` design exists to make possible.
    ///
    /// When ClipRoid pastes a clip it writes the pasteboard; the poller is watching that same
    /// pasteboard. Without the change-count handshake the app captures its own paste as a brand-new
    /// clip, and every paste silently duplicates a row. Written here in M0 and never removed.
    @Test("Pasting from ClipRoid does not capture our own write as a new clip")
    func doesNotCaptureOwnWrites() async throws {
        let scratch = ScratchDirectory()
        let store = try await makeStore(scratch)
        let pb = await FakePasteboard()
        let frontmost = StubFrontmostApp(app: SourceApp(bundleId: "com.apple.Safari", name: "Safari"))
        let poller = PasteboardPoller(pasteboard: pb, frontmost: frontmost)
        let capture = CaptureCoordinator(poller: poller, store: store)

        // A genuine external copy.
        await pb.externalCopy("the original clip")
        if let s = await pb.snapshot(sourceApp: frontmost.app, maxBytes: SizeLimits.defaultMaxCaptureBytes) {
            await capture.ingest(s)
        }
        #expect(try await store.count() == 1)
        let clip = try #require(try await store.recent().first)

        // Now ClipRoid pastes it back, twice — the second write models the optional
        // "restore previous clipboard" behaviour, which is the case a single guard would miss.
        await pb.write(.text("the original clip"), originClipUUID: clip.uuid)
        await poller.tick()
        await pb.write(.text("the original clip"), originClipUUID: clip.uuid)
        await poller.tick()

        #expect(try await store.count() == 1, "our own pasteboard writes must not become clips")
        await store.close()
    }

    @Test("Copying the same thing twice in a row promotes instead of inserting")
    func collapsesRepeats() async throws {
        let scratch = ScratchDirectory()
        let store = try await makeStore(scratch)
        let app = SourceApp(bundleId: "com.apple.dt.Xcode", name: "Xcode")
        let pb = await FakePasteboard()
        let capture = CaptureCoordinator(
            poller: PasteboardPoller(pasteboard: pb, frontmost: StubFrontmostApp(app: app)),
            store: store)

        for _ in 0..<3 {
            await pb.externalCopy("let x = 1")
            if let s = await pb.snapshot(sourceApp: app, maxBytes: SizeLimits.defaultMaxCaptureBytes) {
                await capture.ingest(s)
            }
        }

        #expect(try await store.count() == 1)
        #expect(try await store.recent().first?.repeatCount == 3)
        await store.close()
    }

    @Test("Content marked concealed by a password manager is never captured")
    func skipsConcealedContent() async throws {
        let scratch = ScratchDirectory()
        let store = try await makeStore(scratch)
        let app = SourceApp(bundleId: "com.1password.1password", name: "1Password")
        let pb = await FakePasteboard()
        let capture = CaptureCoordinator(
            poller: PasteboardPoller(pasteboard: pb, frontmost: StubFrontmostApp(app: app)),
            store: store)

        await pb.externalCopy(
            "hunter2",
            types: ["public.utf8-plain-text", PasteboardConventions.concealedType])
        let snapshot = await pb.snapshot(sourceApp: app, maxBytes: SizeLimits.defaultMaxCaptureBytes)
        #expect(snapshot == nil, "concealed pasteboard content must not even be read")
        if let snapshot { await capture.ingest(snapshot) }

        #expect(try await store.count() == 0)
        await store.close()
    }

    @Test("Clips from an ignored app are dropped")
    func honoursIgnoreList() async throws {
        let scratch = ScratchDirectory()
        let store = try await makeStore(scratch)
        let app = SourceApp(bundleId: "com.example.secret", name: "Secret App")
        let pb = await FakePasteboard()
        let capture = CaptureCoordinator(
            poller: PasteboardPoller(pasteboard: pb, frontmost: StubFrontmostApp(app: app)),
            store: store,
            ignoredBundleIds: ["com.example.secret"])

        await pb.externalCopy("should not be stored")
        if let s = await pb.snapshot(sourceApp: app, maxBytes: SizeLimits.defaultMaxCaptureBytes) {
            await capture.ingest(s)
        }

        #expect(try await store.count() == 0)
        await store.close()
    }
}

@Suite("Classification")
struct ClassifierTests {
    private func snapshot(_ text: String) -> RawSnapshot {
        RawSnapshot(changeCount: 1, declaredTypes: ["public.utf8-plain-text"], text: text)
    }

    @Test("A bare URL is a link, prose containing a URL is not", arguments: [
        ("https://github.com/anthropics", ClipContentType.link),
        ("see https://example.com for details", ClipContentType.text),
        ("#FF8800", ClipContentType.color),
        ("#not-a-color", ClipContentType.text),
    ])
    func classifiesTypes(input: String, expected: ClipContentType) {
        let clip = ClipClassifier.classify(snapshot(input))
        #expect(clip?.contentType == expected)
    }

    @Test("Whitespace-only clips are discarded")
    func ignoresBlank() {
        #expect(ClipClassifier.classify(snapshot("   \n\t ")) == nil)
    }

    @Test("A Swift function is typed as code")
    func detectsCode() {
        let source = """
        func greet(name: String) -> String {
            return "hello \\(name)"
        }
        """
        #expect(ClipClassifier.classify(snapshot(source))?.contentType == .code)
    }
}
