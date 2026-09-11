import Foundation
import ClipRoidCore
import os.log

/// The only way anything reaches the clip database.
///
/// Callers get no raw SQL. That is not fussiness: `clips.body`, `ocr_text` and `title` are the
/// external-content source for the FTS index, and mutating them outside a statement the triggers
/// see silently desynchronises the index from the table. Keeping SQL private is what enforces the
/// invariant the triggers depend on.
public actor ClipStore {
    private let db: Database
    private let blobs: BlobStore
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "ClipStore")

    private var continuations: [UUID: AsyncStream<ClipStoreChange>.Continuation] = [:]

    public init(db: Database, blobs: BlobStore) {
        self.db = db
        self.blobs = blobs
    }

    public static func makeDefault(root: URL) -> ClipStore {
        ClipStore(
            db: Database(path: root.appendingPathComponent("ClipRoid.sqlite").path),
            blobs: BlobStore(root: root.appendingPathComponent("clips", isDirectory: true))
        )
    }

    public func open(backupDirectory: URL?) async throws {
        try await blobs.prepare()
        try await db.open()
        if try await !db.quickCheck() {
            logger.error("Database failed quick_check on open")
        }
        try await Migrations.run(on: db, backupDirectory: backupDirectory)
    }

    public func close() async {
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
        await db.close()
    }

    // MARK: - Change stream

    /// Deltas, so the UI applies one row rather than re-querying the timeline on every capture.
    public func changes() -> AsyncStream<ClipStoreChange> {
        AsyncStream { continuation in
            let key = UUID()
            continuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(key) }
            }
        }
    }

    private func removeContinuation(_ key: UUID) {
        continuations[key] = nil
    }

    private func publish(_ change: ClipStoreChange) {
        for (_, c) in continuations { c.yield(change) }
    }

    // MARK: - Insert

    /// One copy is one INSERT, written immediately rather than batched.
    ///
    /// Batching the interactive path would be a pessimisation: the user copies and 200ms later hits
    /// Ctrl+Cmd+V, and the clip has to already be there. Under WAL with synchronous=NORMAL a single
    /// insert is sub-millisecond and there is no fsync, so there is nothing to save. Bulk paths
    /// (retention sweeps, retroactive rules, OCR backfill) get their own batched API.
    @discardableResult
    public func insert(_ clip: CapturedClip) async throws -> ClipSummary {
        // A repeat of the most recent clip becomes a promotion, not a new row (spec §4.1).
        if let head = try await headSummary(),
           let existing = try await findByHash(clip.contentHash, appBundleId: clip.sourceAppBundleId),
           existing.id == head.id,
           Dedupe.isRepeat(
                candidateHash: clip.contentHash,
                candidateApp: clip.sourceAppBundleId,
                candidateAt: clip.copiedAt,
                headHash: clip.contentHash,
                headApp: existing.sourceAppBundleId,
                headAt: existing.copiedAt
           ) {
            return try await promote(id: existing.id, at: clip.copiedAt)
        }

        var thumbPath: String?
        var imagePath: String?
        var textBlobPath: String?
        var body = clip.body

        if let imageData = clip.imageData {
            imagePath = try await blobs.write(
                imageData, uuid: clip.uuid, ext: "png", maxBytes: SizeLimits.maxCaptureBytesCeiling)
        }
        // Long text still gets stored whole on disk; only the indexed prefix stays in the row, so
        // ordinary rows stay small and the timeline query stays fast.
        if let text = clip.body, text.utf8.count > SizeLimits.textBlobThreshold {
            textBlobPath = try await blobs.write(
                Data(text.utf8), uuid: clip.uuid, ext: "txt", maxBytes: SizeLimits.maxCaptureBytesCeiling)
            body = String(text.prefix(SizeLimits.maxIndexedBodyBytes))
        }

        let now = Date()
        let id = try await db.run(
            """
            INSERT INTO clips (
              uuid, content_type, content_hash, body, title,
              text_blob_path, image_blob_path, thumb_blob_path,
              color_hex, link_url, link_host,
              source_app_bundle_id, source_app_name,
              copied_at, stored_at, content_size_bytes,
              sensitivity, sensitive_reason, enrichment_state
            ) VALUES (?,?,?,?,?, ?,?,?, ?,?,?, ?,?, ?,?,?, ?,?,?);
            """,
            [
                .text(clip.uuid.uuidString), .int(clip.contentType.rawValue), .text(clip.contentHash),
                .optional(body), .optional(clip.title),
                .optional(textBlobPath), .optional(imagePath), .optional(thumbPath),
                .optional(clip.colorHex), .optional(clip.linkUrl), .optional(clip.linkHost),
                .optional(clip.sourceAppBundleId), .optional(clip.sourceAppName),
                .date(clip.copiedAt), .date(now), .int(clip.contentSizeBytes),
                .int(clip.sensitivity.rawValue), .optional(clip.sensitiveReason),
                .int(clip.enrichmentState.rawValue),
            ]
        )

        let summary = ClipSummary(
            id: id,
            uuid: clip.uuid,
            contentType: clip.contentType,
            preview: (body ?? clip.title ?? "").clipPreview(),
            title: clip.title,
            sourceAppBundleId: clip.sourceAppBundleId,
            sourceAppName: clip.sourceAppName,
            copiedAt: clip.copiedAt,
            contentSizeBytes: clip.contentSizeBytes,
            sensitivity: clip.sensitivity,
            thumbnailPath: thumbPath,
            colorHex: clip.colorHex
        )
        publish(.inserted(summary))
        return summary
    }

    @discardableResult
    private func promote(id: Int64, at date: Date) async throws -> ClipSummary {
        try await db.run(
            "UPDATE clips SET copied_at = ?, repeat_count = repeat_count + 1 WHERE id = ?;",
            [.date(date), .int(id)]
        )
        guard let summary = try await summary(id: id) else {
            throw DatabaseError.stepFailed(sql: "promote", message: "clip \(id) vanished")
        }
        publish(.promoted(summary))
        return summary
    }

    // MARK: - Reads

    private static let summaryColumns = """
    id, uuid, content_type, body, title, source_app_bundle_id, source_app_name,
    copied_at, content_size_bytes, repeat_count, is_pinned, is_favorite,
    sensitivity, thumb_blob_path, color_hex, shortcut
    """

    /// The same columns qualified for the FTS join, where `clips` is aliased to `c`.
    private static let aliasedSummaryColumns = summaryColumns
        .split(separator: ",")
        .map { "c.\($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
        .joined(separator: ", ")

    private func decodeSummary(_ row: Row) -> ClipSummary {
        ClipSummary(
            id: row.int64(0),
            uuid: UUID(uuidString: row.string(1) ?? "") ?? UUID(),
            contentType: ClipContentType(rawValue: row.int(2)) ?? .unknown,
            preview: (row.string(3) ?? row.string(4) ?? "").clipPreview(),
            title: row.string(4),
            sourceAppBundleId: row.string(5),
            sourceAppName: row.string(6),
            copiedAt: row.date(7) ?? Date(),
            contentSizeBytes: row.int64(8),
            repeatCount: row.int(9),
            isPinned: row.bool(10),
            isFavorite: row.bool(11),
            sensitivity: Sensitivity(rawValue: row.int(12)) ?? .none,
            thumbnailPath: row.string(13),
            colorHex: row.string(14),
            shortcut: row.string(15)
        )
    }

    public func recent(limit: Int = 200, before: Date? = nil) async throws -> [ClipSummary] {
        let sql = """
        SELECT \(Self.summaryColumns) FROM clips
        WHERE (? IS NULL OR copied_at < ?)
        ORDER BY copied_at DESC LIMIT ?;
        """
        let cursor: SQLValue = before.map { .date($0) } ?? .null
        return try await db.query(sql, [cursor, cursor, .int(limit)]).map(decodeSummary)
    }

    public func summary(id: Int64) async throws -> ClipSummary? {
        try await db.query("SELECT \(Self.summaryColumns) FROM clips WHERE id = ?;", [.int(id)])
            .first.map(decodeSummary)
    }

    private func headSummary() async throws -> ClipSummary? {
        try await db.query("SELECT \(Self.summaryColumns) FROM clips ORDER BY copied_at DESC LIMIT 1;")
            .first.map(decodeSummary)
    }

    private func findByHash(_ hash: String, appBundleId: String?) async throws -> ClipSummary? {
        try await db.query(
            """
            SELECT \(Self.summaryColumns) FROM clips
            WHERE content_hash = ? AND (source_app_bundle_id IS ?)
            ORDER BY copied_at DESC LIMIT 1;
            """,
            [.text(hash), .optional(appBundleId)]
        ).first.map(decodeSummary)
    }

    /// Full text of a clip, pulled from the blob file when the body was too long to keep inline.
    public func fullText(id: Int64) async throws -> String? {
        guard let row = try await db.query(
            "SELECT body, text_blob_path FROM clips WHERE id = ?;", [.int(id)]).first else { return nil }
        if let path = row.string(1), let data = await blobs.read(relativePath: path) {
            return String(data: data, encoding: .utf8)
        }
        return row.string(0)
    }

    public func count() async throws -> Int {
        try await db.query("SELECT COUNT(*) FROM clips;").first?.int(0) ?? 0
    }



    // MARK: - Search

    /// Runs a parsed query. This is the entry point the Quick Paste window uses.
    public func search(_ query: SearchQuery, limit: Int = 50) async throws -> [ClipSummary] {
        // A shortcut is an exact lookup, not a search — typing ";welcome" should land on that one
        // clip immediately rather than ranking it among fuzzy matches (spec §4.5).
        if let shortcut = query.shortcut {
            return try await db.query(
                "SELECT \(Self.summaryColumns) FROM clips WHERE shortcut = ? LIMIT 1;",
                [.text(shortcut)]).map(decodeSummary)
        }
        return try await runSearch(query, limit: limit)
    }


    /// Full-text search across body, OCR text and title.
    ///
    /// Ranking is `bm25(clip_fts, 10.0, 3.0, 5.0)` — body 10, ocr_text 3, title 5. OCR text is
    /// weighted lowest because it is noisy: a screenshot that happens to contain the word should
    /// not outrank a clip whose actual content is that word.
    ///
    /// `bm25()` returns *negative* scores where more negative is better, so plain ascending order
    /// is correct. This reads like a bug and is not one.
    public func search(
        _ text: String, types: Set<ClipContentType> = [], appBundleId: String? = nil,
        from: Date? = nil, to: Date? = nil, limit: Int = 50
    ) async throws -> [ClipSummary] {
        var query = SearchQuery()
        query.text = text
        query.types = types
        if let appBundleId { query.appTerms = [appBundleId] }
        query.from = from
        query.to = to
        return try await runSearch(query, limit: limit)
    }

    private func runSearch(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary] {
        let types = query.types
        let from = query.from
        let to = query.to
        let term = Self.ftsQuery(from: query.text)

        // With no free-text term there is nothing to MATCH against, so skip FTS entirely and let
        // the composite indexes serve the filters directly.
        guard let term else {
            return try await filtered(query, limit: limit)
        }

        var sql = """
        SELECT \(Self.summaryColumns) FROM clip_fts f JOIN clips c ON c.id = f.rowid
        WHERE clip_fts MATCH ?
        """
        var values: [SQLValue] = [.text(term)]

        if !types.isEmpty {
            sql += " AND c.content_type IN (\(types.map { _ in "?" }.joined(separator: ",")))"
            values += types.map { .int($0.rawValue) }
        }
        // The user types `@Safari`, not `@com.apple.Safari`, so an app term has to match either the
        // bundle id or the human-readable name — and by prefix, since `@Xcode` should find
        // `com.apple.dt.Xcode`.
        for term in query.appTerms {
            sql += " AND (c.source_app_bundle_id LIKE ? OR c.source_app_name LIKE ?)"
            values.append(.text("%\(term)%"))
            values.append(.text("%\(term)%"))
        }
        if let from {
            sql += " AND c.copied_at >= ?"
            values.append(.date(from))
        }
        if let to {
            sql += " AND c.copied_at <= ?"
            values.append(.date(to))
        }
        if query.favoritesOnly { sql += " AND c.is_favorite = 1" }
        if query.pinnedOnly { sql += " AND c.is_pinned = 1" }
        sql += " ORDER BY bm25(clip_fts, 10.0, 3.0, 5.0), c.copied_at DESC LIMIT ?;"
        values.append(.int(limit))

        // The joined query selects from `clips` aliased as c, so the shared column list needs the
        // alias applied.
        sql = sql.replacingOccurrences(of: "SELECT \(Self.summaryColumns) FROM clip_fts",
                                       with: "SELECT \(Self.aliasedSummaryColumns) FROM clip_fts")
        return try await db.query(sql, values).map(decodeSummary)
    }

    /// Chips-only queries skip FTS entirely — there is nothing to MATCH against, and the composite
    /// `(filter, copied_at DESC)` indexes serve these directly with no sort step.
    private func filtered(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary] {
        var sql = "SELECT \(Self.summaryColumns) FROM clips WHERE 1=1"
        var values: [SQLValue] = []
        if !query.types.isEmpty {
            sql += " AND content_type IN (\(query.types.map { _ in "?" }.joined(separator: ",")))"
            values += query.types.map { .int($0.rawValue) }
        }
        for term in query.appTerms {
            sql += " AND (source_app_bundle_id LIKE ? OR source_app_name LIKE ?)"
            values.append(.text("%\(term)%"))
            values.append(.text("%\(term)%"))
        }
        if let from = query.from { sql += " AND copied_at >= ?"; values.append(.date(from)) }
        if let to = query.to { sql += " AND copied_at <= ?"; values.append(.date(to)) }
        if query.favoritesOnly { sql += " AND is_favorite = 1" }
        if query.pinnedOnly { sql += " AND is_pinned = 1" }
        sql += " ORDER BY is_pinned DESC, copied_at DESC LIMIT ?;"
        values.append(.int(limit))
        return try await db.query(sql, values).map(decodeSummary)
    }

    /// Turns user input into an FTS5 MATCH expression.
    ///
    /// Every token is quoted, because FTS5's query syntax treats `"`, `*`, `:`, `^`, `-`, `(`, `)`
    /// and `NEAR` as operators — so a user searching for `foo:bar` or a lone `-` gets a syntax
    /// error from SQLite rather than a search. Quoting makes the input inert, and a trailing `*` is
    /// then added deliberately for prefix matching so search-as-you-type still works.
    static func ftsQuery(from text: String) -> String? {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0)\"" + ($0.count >= 2 ? "*" : "") }
            .joined(separator: " ")
    }

    // MARK: - Enrichment

    /// A clip awaiting asynchronous work: a thumbnail, OCR text, a link title.
    public struct EnrichmentJob: Sendable {
        public var id: Int64
        public var uuid: UUID
        public var contentType: ClipContentType
        public var imageBlobPath: String?
        public var linkUrl: String?
    }

    /// The backlog, served by `idx_clips_pending` — a partial index over `enrichment_state = 0`, so
    /// this stays cheap however large the table grows.
    public func pendingEnrichment(limit: Int = 20) async throws -> [EnrichmentJob] {
        try await db.query(
            """
            SELECT id, uuid, content_type, image_blob_path, link_url
            FROM clips WHERE enrichment_state = 0 ORDER BY id DESC LIMIT ?;
            """, [.int(limit)]
        ).map { row in
            EnrichmentJob(
                id: row.int64(0),
                uuid: UUID(uuidString: row.string(1) ?? "") ?? UUID(),
                contentType: ClipContentType(rawValue: row.int(2)) ?? .unknown,
                imageBlobPath: row.string(3),
                linkUrl: row.string(4)
            )
        }
    }

    public func imageData(forBlobPath path: String) async -> Data? {
        await blobs.read(relativePath: path)
    }

    public func writeThumbnail(_ data: Data, uuid: UUID) async throws -> String {
        try await blobs.write(data, uuid: uuid, ext: "thumb.png", maxBytes: SizeLimits.maxCaptureBytesCeiling)
    }

    /// Applies the result of enrichment to one row.
    ///
    /// `ocr_text` is an FTS-indexed column, so this UPDATE is seen by the `clips_au` trigger and the
    /// index is rewritten for this row only. That is the whole reason OCR can land minutes after
    /// capture and still become searchable without a reindex.
    public func applyEnrichment(
        id: Int64, ocrText: String?, thumbnailPath: String?, title: String?, state: EnrichmentState
    ) async throws {
        try await db.run(
            """
            UPDATE clips SET
              ocr_text = COALESCE(?, ocr_text),
              thumb_blob_path = COALESCE(?, thumb_blob_path),
              title = COALESCE(?, title),
              enrichment_state = ?
            WHERE id = ?;
            """,
            [.optional(ocrText), .optional(thumbnailPath), .optional(title),
             .int(state.rawValue), .int(id)]
        )
        if let summary = try await summary(id: id) {
            publish(.updated(summary))
        }
    }

    public func setImageDimensions(id: Int64, width: Int, height: Int) async throws {
        // Not an FTS column, so this deliberately does not touch the index.
        try await db.run(
            "UPDATE clips SET image_width = ?, image_height = ? WHERE id = ?;",
            [.int(width), .int(height), .int(id)])
    }

    // MARK: - Retention

    /// Applies a retention policy, returning the ids removed.
    ///
    /// Evaluation happens in `ClipRoidCore` on plain values rather than in SQL: the rules involve
    /// pins, favourites, a count budget and two different clocks, and they are far easier to get
    /// right — and to test — as a pure function than as a DELETE with four subqueries.
    @discardableResult
    public func applyRetention(policy: RetentionPolicy, now: Date = Date()) async throws -> [Int64] {
        guard !policy.isUnlimited else { return [] }

        let candidates = try await db.query(
            "SELECT id, copied_at, is_pinned, is_favorite, sensitivity FROM clips;"
        ).map { row in
            RetentionEvaluator.Candidate(
                id: row.int64(0),
                copiedAt: row.date(1) ?? Date(),
                isPinned: row.bool(2),
                isFavorite: row.bool(3),
                sensitivity: Sensitivity(rawValue: row.int(4)) ?? .none
            )
        }

        let doomed = RetentionEvaluator.idsToPurge(candidates: candidates, policy: policy, now: now)
        guard !doomed.isEmpty else { return [] }

        // Chunked so one sweep of a large history cannot hold a write lock for an unbounded time,
        // and so the UI keeps getting delete deltas as it progresses.
        for chunk in stride(from: 0, to: doomed.count, by: 500) {
            let slice = Array(doomed[chunk..<min(chunk + 500, doomed.count)])
            try await delete(ids: slice)
            await Task.yield()
        }

        // FTS5 leaves its index fragmented after bulk deletes; this compacts it.
        try? await db.execute("INSERT INTO clip_fts(clip_fts) VALUES('optimize');")
        return doomed
    }

    /// Surfaced in Settings so the user can see what the history is costing them (spec §4.19).
    public func storageSizeBytes() async -> Int64 {
        await blobs.totalSizeBytes()
    }

    // MARK: - Delete

    public func delete(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let values = ids.map { SQLValue.int($0) }

        // Collect blob paths before deleting the rows: once the rows are gone, so is any record of
        // which files belonged to them, and the bytes leak.
        let paths = try await db.query(
            """
            SELECT text_blob_path, image_blob_path, thumb_blob_path, html_blob_path, favicon_blob_path
            FROM clips WHERE id IN (\(placeholders));
            """, values
        ).flatMap { row in (0..<5).compactMap { row.string($0) } }

        try await db.run("DELETE FROM clips WHERE id IN (\(placeholders));", values)
        await blobs.delete(relativePaths: paths)
        publish(.deleted(ids))
    }
}
