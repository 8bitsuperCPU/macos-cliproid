import Testing
import Foundation
@testable import ClipRoidStore
import ClipRoidCore

/// Self-deleting temp directory, duplicated from the Kit test target because test targets cannot
/// import one another.
final class ScratchDirectory {
    let url: URL
    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClipRoidStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("Clip store")
struct ClipStoreTests {

    private func open(_ scratch: ScratchDirectory) async throws -> ClipStore {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        return store
    }

    private func clip(_ body: String, app: String = "com.apple.Safari") -> CapturedClip {
        CapturedClip(
            contentType: .text,
            contentHash: Dedupe.hash(body),
            body: body,
            sourceAppBundleId: app,
            sourceAppName: "Safari",
            contentSizeBytes: Int64(body.utf8.count)
        )
    }

    @Test("Migration brings a fresh database to the current version")
    func migrates() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let db = Database(path: scratch.url.appendingPathComponent("ClipRoid.sqlite").path)
        await store.close()
        try await db.open()
        #expect(try await db.userVersion() == Migrations.current)
        #expect(try await db.quickCheck())
        await db.close()
    }

    @Test("Insert round-trips and appears newest-first")
    func insertsAndReads() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        try await store.insert(clip("first"))
        try await Task.sleep(for: .milliseconds(5))
        try await store.insert(clip("second"))

        let clips = try await store.recent()
        #expect(clips.count == 2)
        #expect(clips.first?.preview == "second")
        await store.close()
    }

    @Test("Deleting a clip removes the row and its blob file")
    func deleteRemovesBlobs() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)

        // Long enough to be spilled to a blob file rather than kept inline.
        let long = String(repeating: "x", count: SizeLimits.textBlobThreshold + 1024)
        let summary = try await store.insert(clip(long))

        let blobRoot = scratch.url.appendingPathComponent("clips")
        let before = FileManager.default.enumerator(at: blobRoot, includingPropertiesForKeys: nil)?
            .allObjects.count ?? 0
        #expect(before > 0, "long text should have been written to a blob")

        try await store.delete(ids: [summary.id])
        #expect(try await store.count() == 0)

        let after = FileManager.default.enumerator(at: blobRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "txt" }.count ?? 0
        #expect(after == 0, "pruning a clip must remove its bytes, not just its row")
        await store.close()
    }

    @Test("Long text is retrievable in full even though only a prefix is indexed")
    func fullTextRoundTrips() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let long = String(repeating: "y", count: SizeLimits.textBlobThreshold + 512)
        let summary = try await store.insert(clip(long))
        let recovered = try await store.fullText(id: summary.id)
        #expect(recovered == long)
        await store.close()
    }

    @Test("The change stream publishes an insert")
    func publishesChanges() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let stream = await store.changes()

        let received = Task { () -> ClipSummary? in
            for await change in stream {
                if case .inserted(let summary) = change { return summary }
            }
            return nil
        }
        try await store.insert(clip("streamed"))
        let summary = await received.value
        #expect(summary?.preview == "streamed")
        await store.close()
    }
}

@Suite("FTS5 index")
struct FTSTests {
    private func open(_ scratch: ScratchDirectory) async throws -> Database {
        let db = Database(path: scratch.url.appendingPathComponent("fts.sqlite").path)
        try await db.open()
        try await Migrations.run(on: db, backupDirectory: nil)
        return db
    }

    private func insert(_ db: Database, body: String, title: String? = nil) async throws {
        try await db.run(
            """
            INSERT INTO clips (uuid, content_type, content_hash, body, title, copied_at, stored_at)
            VALUES (?,?,?,?,?,?,?);
            """,
            [.text(UUID().uuidString), .int(1), .text(UUID().uuidString),
             .text(body), .optional(title), .date(Date()), .date(Date())]
        )
    }

    @Test("Inserted clips become searchable through the trigger")
    func indexesOnInsert() async throws {
        let scratch = ScratchDirectory()
        let db = try await open(scratch)
        try await insert(db, body: "the quarterly dashboard numbers")

        let rows = try await db.query(
            "SELECT c.body FROM clip_fts f JOIN clips c ON c.id = f.rowid WHERE clip_fts MATCH ?;",
            [.text("dashboard")])
        #expect(rows.count == 1)
        await db.close()
    }

    /// External-content FTS is only correct if every mutation of an indexed column goes through the
    /// triggers with the OLD values available. This is the test that catches a desynchronised index.
    @Test("Editing a clip's text updates the index in both directions")
    func reindexesOnUpdate() async throws {
        let scratch = ScratchDirectory()
        let db = try await open(scratch)
        try await insert(db, body: "aardvark")

        try await db.run("UPDATE clips SET body = ? WHERE body = ?;", [.text("zebra"), .text("aardvark")])

        let old = try await db.query("SELECT rowid FROM clip_fts WHERE clip_fts MATCH ?;", [.text("aardvark")])
        let new = try await db.query("SELECT rowid FROM clip_fts WHERE clip_fts MATCH ?;", [.text("zebra")])
        #expect(old.isEmpty, "the old term must no longer match")
        #expect(new.count == 1, "the new term must match")
        await db.close()
    }

    @Test("Deleting a clip removes it from the index")
    func reindexesOnDelete() async throws {
        let scratch = ScratchDirectory()
        let db = try await open(scratch)
        try await insert(db, body: "ephemeral")
        try await db.run("DELETE FROM clips;")
        let rows = try await db.query("SELECT rowid FROM clip_fts WHERE clip_fts MATCH ?;", [.text("ephemeral")])
        #expect(rows.isEmpty)
        #expect(try await db.quickCheck())
        await db.close()
    }

    @Test("Prefix queries are supported, for search-as-you-type")
    func supportsPrefixSearch() async throws {
        let scratch = ScratchDirectory()
        let db = try await open(scratch)
        try await insert(db, body: "authentication middleware")
        let rows = try await db.query(
            "SELECT rowid FROM clip_fts WHERE clip_fts MATCH ?;", [.text("auth*")])
        #expect(rows.count == 1)
        await db.close()
    }

    @Test("Diacritics are folded, so café matches cafe")
    func foldsDiacritics() async throws {
        let scratch = ScratchDirectory()
        let db = try await open(scratch)
        try await insert(db, body: "meet me at the café")
        let rows = try await db.query("SELECT rowid FROM clip_fts WHERE clip_fts MATCH ?;", [.text("cafe")])
        #expect(rows.count == 1)
        await db.close()
    }

    @Test("bm25 ranks more-negative first, so plain ascending order is correct")
    func ranksByBM25() async throws {
        let scratch = ScratchDirectory()
        let db = try await open(scratch)
        try await insert(db, body: "dashboard")
        try await insert(db, body: "a long passage of text that mentions dashboard exactly once amid many other words")

        let rows = try await db.query(
            """
            SELECT c.body FROM clip_fts f JOIN clips c ON c.id = f.rowid
            WHERE clip_fts MATCH ? ORDER BY bm25(clip_fts, 10.0, 3.0, 5.0);
            """, [.text("dashboard")])
        #expect(rows.first?.string(0) == "dashboard", "the tighter match should rank first")
        await db.close()
    }
}
