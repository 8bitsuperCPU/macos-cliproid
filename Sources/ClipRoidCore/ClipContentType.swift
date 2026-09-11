import Foundation

/// Stored as an INTEGER in SQLite. Raw values are part of the on-disk format: append only,
/// never renumber, or every existing database misreads its own rows.
public enum ClipContentType: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case text = 1
    case richText = 2
    case image = 3
    case file = 4
    case color = 5
    case code = 6
    case link = 7
    case screenshot = 8
    case multiClip = 9
    case note = 10
}

/// Tiered rather than boolean, deliberately. A flat "sensitive/not" that fires on every email
/// address blurs most ordinary clips, turns the badge into noise, and gets the feature switched
/// off — which is worse than not having it. See spec §4.7.
public enum Sensitivity: Int, Sendable, Codable, Comparable {
    /// Nothing detected.
    case none = 0
    /// Email addresses, phone numbers, IPs. Recorded and filterable; not blurred, not hidden.
    case personal = 1
    /// Private keys, JWTs, API-key shapes, Luhn-valid cards, `org.nspasteboard.ConcealedType`.
    /// Blurred until revealed, excluded from the shelf, eligible for auto-deletion.
    case secret = 2

    public static func < (lhs: Sensitivity, rhs: Sensitivity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Drives the asynchronous enrichment worklist (thumbnails, OCR, link titles). `pending` rows are
/// found via a partial index, so the backlog query stays cheap no matter how large the table gets.
public enum EnrichmentState: Int, Sendable, Codable {
    case pending = 0
    case done = 1
    case failed = 2
    case notApplicable = 3
}
