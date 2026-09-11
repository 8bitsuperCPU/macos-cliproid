import Foundation

/// What the poller hands off when it notices the pasteboard changed.
///
/// Deliberately made of value types only: nothing derived from `NSPasteboardItem`, `NSImage` or
/// `NSRunningApplication` ever crosses an actor boundary. That conversion happens at the boundary
/// where those objects are created, which is what lets the whole package build in Swift 6
/// language mode without `@unchecked Sendable` anywhere.
public struct RawSnapshot: Sendable {
    public var changeCount: Int
    public var declaredTypes: [String]
    public var text: String?
    public var htmlData: Data?
    public var imageData: Data?
    public var fileURLs: [URL]
    public var sourceAppBundleId: String?
    public var sourceAppName: String?
    public var capturedAt: Date

    public init(
        changeCount: Int,
        declaredTypes: [String] = [],
        text: String? = nil,
        htmlData: Data? = nil,
        imageData: Data? = nil,
        fileURLs: [URL] = [],
        sourceAppBundleId: String? = nil,
        sourceAppName: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.changeCount = changeCount
        self.declaredTypes = declaredTypes
        self.text = text
        self.htmlData = htmlData
        self.imageData = imageData
        self.fileURLs = fileURLs
        self.sourceAppBundleId = sourceAppBundleId
        self.sourceAppName = sourceAppName
        self.capturedAt = capturedAt
    }
}

/// A classified snapshot, ready to be written to the store. Still carries payload bytes; the store
/// is what splits them between DB columns and on-disk blobs.
public struct CapturedClip: Sendable {
    public var uuid: UUID
    public var contentType: ClipContentType
    public var contentHash: String
    public var body: String?
    public var title: String?
    public var sensitivity: Sensitivity
    public var sensitiveReason: String?
    public var sourceAppBundleId: String?
    public var sourceAppName: String?
    public var copiedAt: Date
    public var contentSizeBytes: Int64
    public var imageData: Data?
    public var htmlData: Data?
    public var fileURLs: [URL]
    public var linkUrl: String?
    public var linkHost: String?
    public var colorHex: String?
    public var enrichmentState: EnrichmentState

    public init(
        uuid: UUID = UUID(),
        contentType: ClipContentType,
        contentHash: String,
        body: String? = nil,
        title: String? = nil,
        sensitivity: Sensitivity = .none,
        sensitiveReason: String? = nil,
        sourceAppBundleId: String? = nil,
        sourceAppName: String? = nil,
        copiedAt: Date = Date(),
        contentSizeBytes: Int64 = 0,
        imageData: Data? = nil,
        htmlData: Data? = nil,
        fileURLs: [URL] = [],
        linkUrl: String? = nil,
        linkHost: String? = nil,
        colorHex: String? = nil,
        enrichmentState: EnrichmentState = .pending
    ) {
        self.uuid = uuid
        self.contentType = contentType
        self.contentHash = contentHash
        self.body = body
        self.title = title
        self.sensitivity = sensitivity
        self.sensitiveReason = sensitiveReason
        self.sourceAppBundleId = sourceAppBundleId
        self.sourceAppName = sourceAppName
        self.copiedAt = copiedAt
        self.contentSizeBytes = contentSizeBytes
        self.imageData = imageData
        self.htmlData = htmlData
        self.fileURLs = fileURLs
        self.linkUrl = linkUrl
        self.linkHost = linkHost
        self.colorHex = colorHex
        self.enrichmentState = enrichmentState
    }
}

/// What the UI holds, one per row. Small on purpose.
///
/// There is no `Data` field here and there must never be one. A view model holding `[Clip]` with
/// inline `thumbnailData` is the mechanism that makes a 10,000-clip timeline unusable: every
/// capture invalidates the array, SwiftUI diffs the whole thing, and hundreds of megabytes of
/// thumbnails sit resident. Thumbnails resolve lazily through a bounded cache, by URL.
public struct ClipSummary: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var uuid: UUID
    public var contentType: ClipContentType
    /// Truncated preview text. Never the full body.
    public var preview: String
    public var title: String?
    public var sourceAppBundleId: String?
    public var sourceAppName: String?
    public var copiedAt: Date
    public var contentSizeBytes: Int64
    public var repeatCount: Int
    public var isPinned: Bool
    public var isFavorite: Bool
    public var sensitivity: Sensitivity
    public var thumbnailPath: String?
    public var colorHex: String?
    public var shortcut: String?

    public init(
        id: Int64,
        uuid: UUID,
        contentType: ClipContentType,
        preview: String,
        title: String? = nil,
        sourceAppBundleId: String? = nil,
        sourceAppName: String? = nil,
        copiedAt: Date,
        contentSizeBytes: Int64 = 0,
        repeatCount: Int = 1,
        isPinned: Bool = false,
        isFavorite: Bool = false,
        sensitivity: Sensitivity = .none,
        thumbnailPath: String? = nil,
        colorHex: String? = nil,
        shortcut: String? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.contentType = contentType
        self.preview = preview
        self.title = title
        self.sourceAppBundleId = sourceAppBundleId
        self.sourceAppName = sourceAppName
        self.copiedAt = copiedAt
        self.contentSizeBytes = contentSizeBytes
        self.repeatCount = repeatCount
        self.isPinned = isPinned
        self.isFavorite = isFavorite
        self.sensitivity = sensitivity
        self.thumbnailPath = thumbnailPath
        self.colorHex = colorHex
        self.shortcut = shortcut
    }
}

/// Deltas the store publishes so the UI never has to re-query the whole timeline.
public enum ClipStoreChange: Sendable {
    case inserted(ClipSummary)
    case updated(ClipSummary)
    case deleted([Int64])
    /// A repeat of an existing clip: bump its timestamp and count rather than inserting a row.
    case promoted(ClipSummary)
}

/// The payload ClipRoid puts back on the pasteboard when the user pastes a clip.
public enum PasteboardPayload: Sendable {
    case text(String)
    case html(Data, plainTextFallback: String?)
    case image(Data)
    case files([URL])
}
