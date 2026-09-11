import Testing
import Foundation
@testable import ClipRoidStore
import ClipRoidCore

/// Spec §13: "search returns results interactively with 10,000+ clips".
///
/// This is the test that validates the two decisions M0 rested on — SQLite with FTS5 rather than
/// SwiftData, and `ClipSummary` carrying a thumbnail *path* rather than image `Data`. If either
/// were wrong, it shows up here.
@Suite("Scale — 10,000 clips")
struct ScaleTests {

    private static let words = [
        "dashboard", "deployment", "runbook", "postgres", "connection", "migration",
        "invoice", "receipt", "keynote", "roadmap", "incident", "postmortem",
        "authentication", "middleware", "throughput", "latency", "rollback", "checksum",
    ]

    private func seed(_ store: ClipStore, count: Int) async throws {
        let apps = ["com.apple.Safari", "com.apple.dt.Xcode", "com.figma.Desktop", "com.apple.Terminal"]
        let types: [ClipContentType] = [.text, .code, .link, .color, .image]
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        var clips: [CapturedClip] = []
        clips.reserveCapacity(count)
        for i in 0..<count {
            let body = "\(Self.words[i % Self.words.count]) entry \(i) with some filler text"
            clips.append(CapturedClip(
                contentType: types[i % types.count],
                contentHash: Dedupe.hash(body),
                body: body,
                sourceAppBundleId: apps[i % apps.count],
                sourceAppName: apps[i % apps.count].components(separatedBy: ".").last,
                copiedAt: base.addingTimeInterval(Double(i)),
                contentSizeBytes: Int64(body.utf8.count),
                enrichmentState: .notApplicable))
        }
        try await store.insertBatch(clips)
    }

    @Test("Search stays interactive over 10,000 clips", .timeLimit(.minutes(2)))
    func searchAtScale() async throws {
        let scratch = ScratchDirectory()
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)

        let seedStart = Date()
        try await seed(store, count: 10_000)
        let seedElapsed = Date().timeIntervalSince(seedStart)
        #expect(try await store.count() == 10_000)

        // Full-text search.
        var slowest: TimeInterval = 0
        for term in ["dashboard", "runb", "postgres", "auth", "incident"] {
            let start = Date()
            let hits = try await store.search(term, limit: 50)
            let elapsed = Date().timeIntervalSince(start)
            slowest = max(slowest, elapsed)
            #expect(!hits.isEmpty, "\(term) should match something")
        }

        // A chips-only query, which skips FTS entirely and rides the composite indexes.
        let filterStart = Date()
        _ = try await store.search("", types: [.code], limit: 200)
        let filterElapsed = Date().timeIntervalSince(filterStart)

        // Deep pagination — the case OFFSET would make progressively worse and a cursor does not.
        var cursor: Date?
        var pageSlowest: TimeInterval = 0
        for _ in 0..<20 {
            let start = Date()
            let page = try await store.recent(limit: 200, before: cursor)
            pageSlowest = max(pageSlowest, Date().timeIntervalSince(start))
            cursor = page.last?.copiedAt
            if page.isEmpty { break }
        }

        print("""

        === scale: 10,000 clips ===
          seed (batched):        \(String(format: "%.2fs", seedElapsed))
          slowest FTS search:    \(String(format: "%.1fms", slowest * 1000))
          chips-only filter:     \(String(format: "%.1fms", filterElapsed * 1000))
          slowest page (of 20):  \(String(format: "%.1fms", pageSlowest * 1000))
        """)

        // 100ms is the threshold where typing stops feeling instant. Generous headroom against it
        // is the point; a tight pass would mean the design only just works.
        #expect(slowest < 0.1, "FTS search must stay under 100ms to feel interactive")
        #expect(filterElapsed < 0.1, "chip filtering must stay under 100ms")
        #expect(pageSlowest < 0.1, "deep pagination must not degrade")

        await store.close()
    }

    @Test("Deep pagination does not degrade with depth")
    func paginationStaysFlat() async throws {
        let scratch = ScratchDirectory()
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        try await seed(store, count: 5_000)

        var cursor: Date?
        var first: TimeInterval = 0
        var last: TimeInterval = 0
        for page in 0..<20 {
            let start = Date()
            let rows = try await store.recent(limit: 200, before: cursor)
            let elapsed = Date().timeIntervalSince(start)
            if page == 0 { first = elapsed }
            if !rows.isEmpty { last = elapsed }
            cursor = rows.last?.copiedAt
            if rows.isEmpty { break }
        }

        // The point of a cursor over OFFSET: page 20 costs the same as page 1, because it is one
        // index seek rather than a walk-and-discard of 4,000 rows.
        #expect(last < max(first * 5, 0.05), "page 20 must not be dramatically slower than page 1")
        await store.close()
    }
}
