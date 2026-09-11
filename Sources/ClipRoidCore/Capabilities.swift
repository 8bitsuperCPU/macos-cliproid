import Foundation

/// The system capabilities ClipRoid needs, declared here in the pure-domain target so that the
/// logic which uses them can be exercised against in-memory doubles. `ClipRoidPlatform` provides
/// the real implementations; `ClipRoidKit` composes the two.

/// Identifies the app that owned the screen when a clip was copied.
public struct SourceApp: Sendable, Equatable {
    public var bundleId: String?
    public var name: String?
    public var processIdentifier: Int32?

    public init(bundleId: String? = nil, name: String? = nil, processIdentifier: Int32? = nil) {
        self.bundleId = bundleId
        self.name = name
        self.processIdentifier = processIdentifier
    }
}

/// Returned by a pasteboard write so the caller can prove which change counts it owns.
public struct PasteboardWriteReceipt: Sendable, Equatable {
    public var changeCount: Int
    public var clipUUID: UUID?

    public init(changeCount: Int, clipUUID: UUID? = nil) {
        self.changeCount = changeCount
        self.clipUUID = clipUUID
    }
}

/// Reading the pasteboard. Isolated to `PasteboardActor` so reads cannot interleave with writes.
@PasteboardActor
public protocol PasteboardReading: AnyObject, Sendable {
    var changeCount: Int { get }
    /// Whether this change count is one ClipRoid produced itself by writing a clip out to paste.
    /// The poller checks this before doing anything else; see `PasteboardActor`.
    func isOwnChange(_ count: Int) -> Bool
    /// The UTIs currently declared, read without pulling any payload bytes. Checked first so a
    /// transient or concealed item can be skipped before its contents are ever touched.
    func declaredTypes() -> [String]
    func snapshot(sourceApp: SourceApp, maxBytes: Int) -> RawSnapshot?
}

/// Writing the pasteboard.
@PasteboardActor
public protocol PasteboardWriting: AnyObject, Sendable {
    /// Must assign the resulting change count with no suspension point between `clearContents()`
    /// and recording it, or a poll tick can observe the intermediate state and capture our own
    /// write as a new clip.
    func write(_ payload: PasteboardPayload, originClipUUID: UUID?) -> PasteboardWriteReceipt
}

public protocol FrontmostAppProviding: Sendable {
    /// Must be read *before* any ClipRoid window appears. One frame later the answer is ClipRoid.
    func frontmostApp() -> SourceApp
}

public protocol TextRecognizing: Sendable {
    func recognizeText(in imageData: Data) async throws -> String?
}

public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}
