import Testing
import Foundation
@testable import ClipRoidCore

@Suite("Search query parsing")
struct SearchQueryParserTests {
    // A fixed clock and a fixed calendar, so date ranges are not a function of when CI runs.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func parse(_ s: String) -> SearchQuery {
        SearchQueryParser.parse(s, now: now, calendar: calendar)
    }

    @Test("Plain text is free text with no filters")
    func plainText() {
        let q = parse("quarterly dashboard")
        #expect(q.text == "quarterly dashboard")
        #expect(q.types.isEmpty)
        #expect(q.appTerms.isEmpty)
    }

    @Test("Type tokens are recognised and removed from the free text")
    func typeTokens() {
        let q = parse("dashboard @screenshot")
        #expect(q.text == "dashboard")
        #expect(q.types == [.screenshot])
    }

    @Test("Type token synonyms", arguments: [
        ("@img", ClipContentType.image), ("@images", .image),
        ("@colour", .color), ("@colours", .color),
        ("@url", .link), ("@links", .link),
        ("@snippet", .code), ("@shot", .screenshot),
    ])
    func typeSynonyms(token: String, expected: ClipContentType) {
        #expect(parse(token).types == [expected])
    }

    /// The example from spec §4.2, which has to work exactly as written.
    @Test("The spec's own example parses correctly")
    func specExample() {
        let q = parse("dashboard @screenshot @today")
        #expect(q.text == "dashboard")
        #expect(q.types == [.screenshot])
        #expect(q.from == calendar.startOfDay(for: now))
    }

    /// Resolution order is the whole game here. If `@image` were treated as an app name the user
    /// would get zero results with no indication why — a silent wrong answer, not an error.
    @Test("A type token is never mistaken for an app name")
    func typesBeatApps() {
        let q = parse("@image")
        #expect(q.types == [.image])
        #expect(q.appTerms.isEmpty)
    }

    @Test("A date token is never mistaken for an app name")
    func datesBeatApps() {
        let q = parse("@today")
        #expect(q.appTerms.isEmpty)
        #expect(q.from != nil)
    }

    @Test("Unrecognised tokens are app filters")
    func appTokens() {
        let q = parse("@Safari @Figma logo")
        #expect(q.appTerms == ["Safari", "Figma"])
        #expect(q.text == "logo")
    }

    @Test("A full bundle id works as an app filter")
    func bundleIdToken() {
        #expect(parse("@com.apple.dt.Xcode").appTerms == ["com.apple.dt.Xcode"])
    }

    @Test("yesterday spans exactly the previous day")
    func yesterday() {
        let q = parse("@yesterday")
        let startOfToday = calendar.startOfDay(for: now)
        #expect(q.to == startOfToday)
        #expect(q.from == calendar.date(byAdding: .day, value: -1, to: startOfToday))
    }

    /// "this week" cannot be found by splitting on whitespace, so it is lifted out before
    /// tokenising. Easy to get wrong, and the failure is silent.
    @Test("Multi-word date phrases are recognised")
    func multiWordDates() {
        let q = parse("receipts this week")
        #expect(q.from != nil)
        #expect(q.text == "receipts", "the phrase must not leak into the free text")
    }

    @Test("An explicit ISO date selects that single day")
    func isoDate() {
        let q = parse("@2023-11-01")
        let expected = calendar.date(from: DateComponents(year: 2023, month: 11, day: 1))
        #expect(q.from == expected)
        #expect(q.to == calendar.date(byAdding: .day, value: 1, to: expected!))
    }

    @Test("A malformed date is treated as an app filter, not silently dropped")
    func malformedDate() {
        #expect(parse("@2023-99-99").appTerms == ["2023-99-99"])
    }

    @Test("A bare date keyword works without the @ prefix")
    func bareDateKeyword() {
        let q = parse("screenshots today")
        #expect(q.from == calendar.startOfDay(for: now))
        #expect(q.text == "screenshots")
    }

    @Test("An inline shortcut typed into the field is recognised")
    func shortcutToken() {
        let q = parse(";welcome")
        #expect(q.shortcut == ";welcome")
        #expect(q.text.isEmpty)
    }

    @Test("Favourite and pinned filters")
    func flagTokens() {
        #expect(parse("@favourite").favoritesOnly)
        #expect(parse("@favorite").favoritesOnly)
        #expect(parse("@pinned").pinnedOnly)
    }

    @Test("Several filters compose")
    func composed() {
        let q = parse("logo @image @Figma @today")
        #expect(q.text == "logo")
        #expect(q.types == [.image])
        #expect(q.appTerms == ["Figma"])
        #expect(q.from != nil)
    }

    @Test("An empty or whitespace-only query is empty")
    func emptyQuery() {
        #expect(parse("").isEmpty)
        #expect(parse("   ").isEmpty)
    }

    @Test("A lone @ is free text, not a crash")
    func loneAt() {
        let q = parse("@")
        #expect(q.text == "@")
    }

    @Test("Tokens are case-insensitive")
    func caseInsensitive() {
        #expect(parse("@SCREENSHOT").types == [.screenshot])
        #expect(parse("@Today").from != nil)
    }
}
