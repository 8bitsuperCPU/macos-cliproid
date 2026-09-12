import Foundation

/// How the Library orders clips.
///
/// A closed enum rather than a column name and direction, because the ordering ends up in SQL: a
/// fixed set of cases means no caller can ever route user input into an `ORDER BY`. The SQL itself
/// lives in `ClipStore`, which is the only place that knows column names.
public enum ClipSort: String, CaseIterable, Sendable, Hashable, Codable {
    /// Best matches first while searching, newest first otherwise.
    ///
    /// The default, and the behaviour the app had before sorting was configurable. Searching
    /// ranks by `bm25`, which is the whole reason the FTS index is weighted; forcing chronological
    /// order on a search would throw that away, and forcing relevance on an unsearched list would
    /// be meaningless since every row scores the same.
    case automatic
    case newest
    case oldest
    case largest
    case smallest
    case type
    case app

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .largest: "Largest first"
        case .smallest: "Smallest first"
        case .type: "Type"
        case .app: "App"
        }
    }

    public var symbolName: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .newest, .oldest: "calendar"
        case .largest, .smallest: "externaldrive"
        case .type: "square.grid.2x2"
        case .app: "app.badge"
        }
    }

    /// Whether this ordering can be paged with a `copied_at` cursor.
    ///
    /// Only newest-first can: the cursor is "everything older than the last row I have", which
    /// means nothing once rows are ordered by size, type or app. Everything else is served as one
    /// bounded page — see `LibraryViewModel.loadNextPage`.
    public var supportsTimestampCursor: Bool {
        self == .automatic || self == .newest
    }
}
