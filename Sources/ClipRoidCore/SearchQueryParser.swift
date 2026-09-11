import Foundation

/// A parsed search, ready to be turned into SQL.
public struct SearchQuery: Sendable, Equatable {
    /// The free-text remainder, after tokens are stripped. Empty means "filters only".
    public var text: String = ""
    public var types: Set<ClipContentType> = []
    /// Matched against bundle id *or* app name — the user types `@Safari`, not `@com.apple.Safari`.
    public var appTerms: Set<String> = []
    public var from: Date?
    public var to: Date?
    /// `;welcome` in the search field jumps straight to that clip (spec §4.5).
    public var shortcut: String?
    public var favoritesOnly = false
    public var pinnedOnly = false

    public init() {}

    public var isEmpty: Bool {
        text.isEmpty && types.isEmpty && appTerms.isEmpty
            && from == nil && to == nil && shortcut == nil
            && !favoritesOnly && !pinnedOnly
    }
}

/// Parses the search syntax from spec §4.2: `dashboard @screenshot @today`.
///
/// Kept pure and in Core because it is the single highest-value thing to unit test in the app —
/// every ambiguity in the syntax is decided here, and getting one wrong silently returns the wrong
/// clips rather than failing.
public enum SearchQueryParser {

    /// `@image` and `@screenshot` are distinct: a screenshot is an image the user took, and being
    /// able to search only those is most of the point of the type chips.
    private static let typeNames: [String: ClipContentType] = [
        "text": .text, "txt": .text,
        "rich": .richText, "richtext": .richText,
        "image": .image, "img": .image, "images": .image,
        "screenshot": .screenshot, "screenshots": .screenshot, "shot": .screenshot,
        "file": .file, "files": .file,
        "color": .color, "colour": .color, "colors": .color, "colours": .color,
        "code": .code, "snippet": .code,
        "link": .link, "links": .link, "url": .link, "urls": .link,
        "note": .note, "notes": .note,
        "multi": .multiClip, "multiclip": .multiClip,
    ]

    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> SearchQuery {
        var query = SearchQuery()
        var freeText: [String] = []

        // "this week" is two words, so it cannot be found by splitting on whitespace. Lift the
        // multi-word phrases out first, then tokenise what remains.
        var working = input
        for (phrase, resolver) in multiWordRanges {
            guard let range = working.range(of: phrase, options: [.caseInsensitive]) else { continue }
            let (from, to) = resolver(now, calendar)
            query.from = from
            query.to = to
            working.removeSubrange(range)
        }

        for token in working.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.hasPrefix("@"), token.count > 1 {
                apply(token: String(token.dropFirst()), to: &query, now: now, calendar: calendar)
                continue
            }
            // A bare shortcut typed into the search field, e.g. ";welcome".
            if token.count > 1, let first = token.first, !first.isLetter, !first.isNumber,
               token.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                query.shortcut = token
                continue
            }
            // A bare date keyword, so "screenshots today" works as well as "@today".
            if let (from, to) = dateKeyword(token.lowercased(), now: now, calendar: calendar) {
                query.from = from
                query.to = to
                continue
            }
            freeText.append(token)
        }

        query.text = freeText.joined(separator: " ")
        return query
    }

    /// Resolution order matters. `@image` must be a type before it is ever considered an app name,
    /// and `@today` a date before an app — otherwise a user searching `@today` gets clips from an
    /// app that does not exist, i.e. nothing, with no indication why.
    private static func apply(
        token: String, to query: inout SearchQuery, now: Date, calendar: Calendar
    ) {
        let lower = token.lowercased()

        if let type = typeNames[lower] {
            query.types.insert(type)
            return
        }
        if lower == "favorite" || lower == "favourite" || lower == "starred" {
            query.favoritesOnly = true
            return
        }
        if lower == "pinned" || lower == "pin" {
            query.pinnedOnly = true
            return
        }
        if let (from, to) = dateKeyword(lower, now: now, calendar: calendar) {
            query.from = from
            query.to = to
            return
        }
        if let day = isoDate(lower, calendar: calendar) {
            query.from = calendar.startOfDay(for: day)
            query.to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            return
        }
        // Anything left is an app: `@Safari`, `@Figma`, `@com.apple.dt.Xcode`.
        query.appTerms.insert(token)
    }

    private static func dateKeyword(
        _ token: String, now: Date, calendar: Calendar
    ) -> (Date, Date)? {
        let startOfToday = calendar.startOfDay(for: now)
        switch token {
        case "today":
            return (startOfToday, calendar.date(byAdding: .day, value: 1, to: startOfToday)!)
        case "yesterday":
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            return (start, startOfToday)
        case "week", "thisweek":
            return (calendar.date(byAdding: .day, value: -7, to: startOfToday)!, now)
        case "month", "thismonth":
            return (calendar.date(byAdding: .month, value: -1, to: startOfToday)!, now)
        case "hour", "lasthour":
            return (now.addingTimeInterval(-3600), now)
        default:
            return nil
        }
    }

    private static let multiWordRanges: [(String, @Sendable (Date, Calendar) -> (Date, Date))] = [
        ("this week", { now, cal in
            let start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
            return (start, now)
        }),
        ("this month", { now, cal in
            let start = cal.date(byAdding: .month, value: -1, to: cal.startOfDay(for: now))!
            return (start, now)
        }),
        ("last hour", { now, _ in (now.addingTimeInterval(-3600), now) }),
    ]

    private static func isoDate(_ token: String, calendar: Calendar) -> Date? {
        let parts = token.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }
}
