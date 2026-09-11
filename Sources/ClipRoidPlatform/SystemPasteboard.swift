import Foundation
import AppKit
import ClipRoidCore
import os.log

/// The real `NSPasteboard.general`, confined to `PasteboardActor`.
///
/// The `lastOwnedChangeCount` field is the first and cheapest of the three layers that stop
/// ClipRoid capturing its own paste as a new clip. See `write(_:originClipUUID:)`.
@PasteboardActor
public final class SystemPasteboard: PasteboardReading, PasteboardWriting {
    /// `nonisolated(unsafe)` because the reference itself is immutable and only needs to be
    /// assignable from the `nonisolated` init. Every *use* of it below is `@PasteboardActor`
    /// isolated, which is the property that actually matters — see `PasteboardActor`.
    private nonisolated(unsafe) let pasteboard: NSPasteboard
    private var lastOwnedChangeCount: Int = -1
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Pasteboard")

    /// `nonisolated` so the composition root can build this synchronously in `App.init` without
    /// hopping to `PasteboardActor`. Safe because nothing has escaped yet at this point — every
    /// subsequent touch of `pasteboard` is actor-isolated.
    public nonisolated init() {
        self.pasteboard = .general
    }

    /// Test seam: an `NSPasteboard(name:)` of our own rather than the system one.
    public nonisolated init(named name: NSPasteboard.Name) {
        self.pasteboard = NSPasteboard(name: name)
    }

    public var changeCount: Int { pasteboard.changeCount }

    /// True when this change count is one ClipRoid produced itself.
    public func isOwnChange(_ count: Int) -> Bool { count <= lastOwnedChangeCount }

    public func declaredTypes() -> [String] {
        (pasteboard.types ?? []).map(\.rawValue)
    }

    public func snapshot(sourceApp: SourceApp, maxBytes: Int) -> RawSnapshot? {
        let types = declaredTypes()
        guard !PasteboardConventions.shouldSkipCapture(declaredTypes: types) else { return nil }

        var snapshot = RawSnapshot(
            changeCount: pasteboard.changeCount,
            declaredTypes: types,
            sourceAppBundleId: sourceApp.bundleId,
            sourceAppName: sourceApp.name
        )

        if let text = pasteboard.string(forType: .string), text.utf8.count <= maxBytes {
            snapshot.text = text
        }
        if let html = pasteboard.data(forType: .html), html.count <= maxBytes {
            snapshot.htmlData = html
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let image = pasteboard.data(forType: type), image.count <= maxBytes {
                snapshot.imageData = image
                break
            }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            snapshot.fileURLs = urls.filter(\.isFileURL)
        }

        let hasContent = snapshot.text != nil || snapshot.imageData != nil
            || snapshot.htmlData != nil || !snapshot.fileURLs.isEmpty
        return hasContent ? snapshot : nil
    }

    /// Records the resulting change count with **no suspension point** between `clearContents()`
    /// and the assignment. That is the whole trick: because reads and writes share this actor and
    /// this function never awaits, a poll tick cannot observe the intermediate state and mistake
    /// our own write for a new clip.
    @discardableResult
    public func write(_ payload: PasteboardPayload, originClipUUID: UUID?) -> PasteboardWriteReceipt {
        let count = pasteboard.clearContents()

        switch payload {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .html(let data, let fallback):
            pasteboard.setData(data, forType: .html)
            if let fallback { pasteboard.setString(fallback, forType: .string) }
        case .image(let data):
            pasteboard.setData(data, forType: .png)
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }

        // Layer 2: if a tick somehow sees a count we own, this marker lets it promote the existing
        // clip rather than insert a duplicate.
        if let originClipUUID {
            pasteboard.setString(
                originClipUUID.uuidString,
                forType: NSPasteboard.PasteboardType(PasteboardConventions.originType))
        }

        lastOwnedChangeCount = pasteboard.changeCount
        return PasteboardWriteReceipt(changeCount: count, clipUUID: originClipUUID)
    }
}

/// `NSWorkspace.shared.frontmostApplication`, which needs no permission of any kind.
public struct WorkspaceFrontmostAppProvider: FrontmostAppProviding {
    public init() {}

    public func frontmostApp() -> SourceApp {
        guard let app = NSWorkspace.shared.frontmostApplication else { return SourceApp() }
        return SourceApp(
            bundleId: app.bundleIdentifier,
            name: app.localizedName,
            processIdentifier: app.processIdentifier
        )
    }
}
