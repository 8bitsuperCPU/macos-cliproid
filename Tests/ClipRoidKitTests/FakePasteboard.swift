import Foundation
import ClipRoidCore

/// An in-memory stand-in for `NSPasteboard`, isolated the same way the real one is.
///
/// This is the seam that makes the capture pipeline testable at all: no window server, no TCC
/// prompt, no real clipboard to clobber while the suite runs.
@PasteboardActor
final class FakePasteboard: PasteboardReading, PasteboardWriting {
    private(set) var count = 0
    private var types: [String] = []
    private var text: String?
    private var lastOwnedChangeCount = -1

    /// Everything ever written through `write`, so a test can assert on our own writes.
    private(set) var writes: [PasteboardPayload] = []

    nonisolated init() {}

    var changeCount: Int { count }

    func isOwnChange(_ count: Int) -> Bool { count <= lastOwnedChangeCount }

    func declaredTypes() -> [String] { types }

    func snapshot(sourceApp: SourceApp, maxBytes: Int) -> RawSnapshot? {
        guard !PasteboardConventions.shouldSkipCapture(declaredTypes: types) else { return nil }
        guard let text else { return nil }
        return RawSnapshot(
            changeCount: count,
            declaredTypes: types,
            text: text,
            sourceAppBundleId: sourceApp.bundleId,
            sourceAppName: sourceApp.name
        )
    }

    /// Simulates some *other* app copying something.
    func externalCopy(_ value: String, types: [String] = ["public.utf8-plain-text"]) {
        count += 1
        self.text = value
        self.types = types
    }

    /// Mirrors `SystemPasteboard.write` exactly, including recording the owned change count with no
    /// suspension point in between.
    @discardableResult
    func write(_ payload: PasteboardPayload, originClipUUID: UUID?) -> PasteboardWriteReceipt {
        count += 1
        writes.append(payload)
        if case .text(let value) = payload {
            text = value
            types = ["public.utf8-plain-text"]
        }
        if originClipUUID != nil {
            types.append(PasteboardConventions.originType)
        }
        lastOwnedChangeCount = count
        return PasteboardWriteReceipt(changeCount: count, clipUUID: originClipUUID)
    }
}

struct StubFrontmostApp: FrontmostAppProviding {
    var app: SourceApp
    func frontmostApp() -> SourceApp { app }
}

/// Self-deleting temp directory. Same idea as
/// ~/projects/nyx/Tests/NyxLibTests/TestDoubles.swift; duplicated rather than shared because test
/// targets cannot import one another.
final class ScratchDirectory {
    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClipRoidTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
