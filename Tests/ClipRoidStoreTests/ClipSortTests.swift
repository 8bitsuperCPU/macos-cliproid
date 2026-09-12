import Testing
import Foundation
@testable import ClipRoidStore
import ClipRoidCore

@Suite("Sorting")
struct ClipSortTests {

    private func makeStore() async throws -> ClipStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ClipStore.makeDefault(root: dir)
        try await store.open(backupDirectory: nil)
        return store
    }

    /// Deliberately mismatched orders: newest is smallest, oldest is largest. A sort that quietly
    /// fell back to chronological would still pass a test where size and time agree.
    private func seed(_ store: ClipStore) async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows: [(String, ClipContentType, Int64, String, Double)] = [
            ("oldest big",  .text,   9_000, "Safari", 0),
            ("middle",      .image,  5_000, "Figma",  60),
            ("newest tiny", .code,     100, "Xcode",  120),
        ]
        for (body, type, size, app, offset) in rows {
            try await store.insert(CapturedClip(
                contentType: type, contentHash: Dedupe.hash(body), body: body,
                sourceAppBundleId: "com.test.\(app)", sourceAppName: app,
                copiedAt: base.addingTimeInterval(offset), contentSizeBytes: size))
        }
    }

    private func order(_ clips: [ClipSummary]) -> [String] { clips.map(\.preview) }

    @Test("Newest and oldest are exact opposites")
    func chronological() async throws {
        let store = try await makeStore()
        try await seed(store)
        #expect(order(try await store.recent(sort: .newest)).first == "newest tiny")
        #expect(order(try await store.recent(sort: .oldest)).first == "oldest big")
        #expect(order(try await store.recent(sort: .oldest))
                == order(try await store.recent(sort: .newest)).reversed())
        await store.close()
    }

    /// The seed data makes the newest clip the smallest, so a size sort that silently ordered by
    /// time would come out backwards here.
    @Test("Size sorts by bytes, not by date")
    func bySize() async throws {
        let store = try await makeStore()
        try await seed(store)
        #expect(order(try await store.recent(sort: .largest)) == ["oldest big", "middle", "newest tiny"])
        #expect(order(try await store.recent(sort: .smallest)) == ["newest tiny", "middle", "oldest big"])
        await store.close()
    }

    @Test("Type groups clips by content type")
    func byType() async throws {
        let store = try await makeStore()
        try await seed(store)
        let types = (try await store.recent(sort: .type)).map(\.contentType)
        #expect(types == types.sorted { $0.rawValue < $1.rawValue })
        await store.close()
    }

    @Test("App groups clips by source app, case-insensitively")
    func byApp() async throws {
        let store = try await makeStore()
        try await seed(store)
        #expect((try await store.recent(sort: .app)).compactMap(\.sourceAppName)
                == ["Figma", "Safari", "Xcode"])
        await store.close()
    }

    /// Clips with no attribution must not head the list — NULLS LAST is why the clause tests
    /// `source_app_name IS NULL` first.
    @Test("Clips with no app sort last, not first")
    func unattributedLast() async throws {
        let store = try await makeStore()
        try await seed(store)
        try await store.insert(CapturedClip(
            contentType: .text, contentHash: Dedupe.hash("orphan"), body: "orphan"))

        let names = (try await store.recent(sort: .app)).map(\.preview)
        #expect(names.last == "orphan")
        await store.close()
    }

    /// Pinning floats a clip under Automatic, where the user expressed no opinion — but not under
    /// an explicit sort, where they did.
    @Test("Pinning only floats clips under Automatic")
    func pinningRespectsExplicitSort() async throws {
        let store = try await makeStore()
        try await seed(store)
        let oldest = try #require((try await store.recent(sort: .oldest)).first)
        try await store.setPinned(true, ids: [oldest.id])

        var query = SearchQuery()
        query.types = [.text, .image, .code]
        #expect((try await store.search(query, sort: .automatic)).first?.preview == "oldest big",
                "pinned floats when the user has not chosen an order")
        #expect((try await store.search(query, sort: .smallest)).first?.preview == "newest tiny",
                "an explicit sort wins over pinning")
        await store.close()
    }

    /// Searching ranks by bm25 under Automatic — that weighting is the reason the FTS index
    /// exists — but an explicit sort must replace it rather than merely tie-break it.
    @Test("An explicit sort overrides relevance ranking while searching")
    func explicitSortOverridesRelevance() async throws {
        let store = try await makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // "widget" once, versus "widget widget widget" — bm25 ranks the latter higher.
        try await store.insert(CapturedClip(
            contentType: .text, contentHash: Dedupe.hash("a"), body: "widget",
            copiedAt: base, contentSizeBytes: 6))
        try await store.insert(CapturedClip(
            contentType: .text, contentHash: Dedupe.hash("b"), body: "widget widget widget",
            copiedAt: base.addingTimeInterval(60), contentSizeBytes: 20))

        var query = SearchQuery()
        query.text = "widget"
        #expect((try await store.search(query, sort: .automatic)).first?.preview == "widget widget widget")
        #expect((try await store.search(query, sort: .oldest)).first?.preview == "widget")
        #expect((try await store.search(query, sort: .smallest)).first?.preview == "widget")
        await store.close()
    }

    /// Only newest-first may use the timestamp cursor: "older than my last row" is meaningless
    /// once rows are ordered by size or type, and paging on it would skip and repeat clips.
    @Test("Only chronological sorts claim cursor pagination")
    func cursorSupport() {
        #expect(ClipSort.automatic.supportsTimestampCursor)
        #expect(ClipSort.newest.supportsTimestampCursor)
        for sort: ClipSort in [.oldest, .largest, .smallest, .type, .app] {
            #expect(!sort.supportsTimestampCursor, "\(sort) cannot page on copied_at")
        }
    }

    /// Paging must not lose or repeat a clip at the page boundary.
    @Test("Cursor pagination covers every clip exactly once")
    func cursorPagesCleanly() async throws {
        let store = try await makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<25 {
            try await store.insert(CapturedClip(
                contentType: .text, contentHash: Dedupe.hash("clip \(i)"), body: "clip \(i)",
                copiedAt: base.addingTimeInterval(Double(i))))
        }

        var seen: [String] = []
        var cursor: Date?
        while true {
            let page = try await store.recent(limit: 10, before: cursor, sort: .newest)
            if page.isEmpty { break }
            seen += page.map(\.preview)
            cursor = page.last?.copiedAt
        }
        #expect(seen.count == 25)
        #expect(Set(seen).count == 25, "no clip appears on two pages")
        await store.close()
    }
}
