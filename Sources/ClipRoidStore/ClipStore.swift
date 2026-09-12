import Foundation
import ClipRoidCore
import UniformTypeIdentifiers
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
    /// Set only during a bulk import; see `insertBatch(_:)`.
    private var isPublishingSuppressed = false

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
        guard !isPublishingSuppressed else { return }
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

        let thumbPath: String? = nil
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

        if !clip.fileURLs.isEmpty {
            try await recordFiles(clip.fileURLs, clipId: id)
        }

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

    /// Records a file clip's members, with the real size and type of each.
    ///
    /// The paths also live in `body` so they are searchable, but this is what makes a file clip
    /// something the app can reason about — size, kind, and whether the file is still there.
    private func recordFiles(_ urls: [URL], clipId: Int64) async throws {
        for (index, url) in urls.enumerated() {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .typeIdentifierKey])
            try await db.run(
                """
                INSERT OR REPLACE INTO files (clip_id, ordinal, path, size_bytes, uti)
                VALUES (?,?,?,?,?);
                """,
                [.int(clipId), .int(index), .text(url.path),
                 values?.fileSize.map { SQLValue.int(Int64($0)) } ?? .null,
                 .optional(values?.typeIdentifier)])
        }
    }

    public struct ClipFile: Sendable, Equatable {
        public var url: URL
        public var sizeBytes: Int64?
        public var uti: String?
    }

    /// The files belonging to a clip, in the order they were copied.
    public func files(forClip id: Int64) async throws -> [ClipFile] {
        try await db.query(
            "SELECT path, size_bytes, uti FROM files WHERE clip_id = ? ORDER BY ordinal;",
            [.int(id)]
        ).compactMap { row in
            guard let path = row.string(0) else { return nil }
            return ClipFile(url: URL(fileURLWithPath: path),
                            sizeBytes: row.isNull(1) ? nil : row.int64(1),
                            uti: row.string(2))
        }
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
    sensitivity, thumb_blob_path, color_hex, shortcut, image_width, image_height
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
            shortcut: row.string(15),
            imageSize: row.isNull(16) ? nil : (width: row.int(16), height: row.int(17))
        )
    }

    /// The `ORDER BY` body for a sort, with an optional table alias.
    ///
    /// Every fragment is a compile-time constant chosen by a closed enum — no caller-supplied
    /// string reaches this, which is what makes interpolating it into SQL safe. `copied_at DESC`
    /// is appended as a tiebreak so equal sizes, types or apps still come out newest-first
    /// instead of in whatever order the index happens to yield.
    /// `pinnedFirst` floats pinned clips to the top, and is only honoured for `.automatic`: a
    /// user who asked for largest-first means largest-first. It must stay off wherever the
    /// timestamp cursor is used, because a pinned old clip at the top of the list makes
    /// "everything older than my last row" skip rows that belong on the next page.
    static func orderClause(
        _ sort: ClipSort, alias: String = "", pinnedFirst: Bool = false
    ) -> String {
        let p = alias.isEmpty ? "" : "\(alias)."
        let pin = (pinnedFirst && sort == .automatic) ? "\(p)is_pinned DESC, " : ""
        switch sort {
        case .automatic, .newest: return pin + "\(p)copied_at DESC"
        case .oldest: return "\(p)copied_at ASC"
        case .largest: return "\(p)content_size_bytes DESC, \(p)copied_at DESC"
        case .smallest: return "\(p)content_size_bytes ASC, \(p)copied_at DESC"
        case .type: return "\(p)content_type, \(p)copied_at DESC"
        // NOCASE so "Figma" and "figma" are one group rather than two, and NULLS LAST so clips
        // with no attribution do not head the list.
        case .app: return "\(p)source_app_name IS NULL, \(p)source_app_name COLLATE NOCASE, \(p)copied_at DESC"
        }
    }

    public func recent(
        limit: Int = 200, before: Date? = nil, sort: ClipSort = .automatic
    ) async throws -> [ClipSummary] {
        let sql = """
        SELECT \(Self.summaryColumns) FROM clips
        WHERE (? IS NULL OR copied_at < ?)
        ORDER BY \(Self.orderClause(sort)) LIMIT ?;
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
    public func search(
        _ query: SearchQuery, limit: Int = 50, sort: ClipSort = .automatic
    ) async throws -> [ClipSummary] {
        // A shortcut is an exact lookup, not a search — typing ";welcome" should land on that one
        // clip immediately rather than ranking it among fuzzy matches (spec §4.5).
        if let shortcut = query.shortcut {
            return try await db.query(
                "SELECT \(Self.summaryColumns) FROM clips WHERE shortcut = ? LIMIT 1;",
                [.text(shortcut)]).map(decodeSummary)
        }
        return try await runSearch(query, limit: limit, sort: sort)
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

    private func runSearch(
        _ query: SearchQuery, limit: Int, sort: ClipSort = .automatic
    ) async throws -> [ClipSummary] {
        let types = query.types
        let from = query.from
        let to = query.to
        let term = Self.ftsQuery(from: query.text)

        // With no free-text term there is nothing to MATCH against, so skip FTS entirely and let
        // the composite indexes serve the filters directly.
        guard let term else {
            return try await filtered(query, limit: limit, sort: sort)
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
        // bm25 ranking is what the weighted FTS index exists for, so it leads under .automatic.
        // An explicit sort replaces it outright: a user who picked "Oldest first" while searching
        // wants oldest matches, not the best match that happens to be old.
        sql += sort == .automatic
            ? " ORDER BY bm25(clip_fts, 10.0, 3.0, 5.0), c.copied_at DESC LIMIT ?;"
            : " ORDER BY \(Self.orderClause(sort, alias: "c")) LIMIT ?;"

        values.append(.int(limit))

        // The joined query selects from `clips` aliased as c, so the shared column list needs the
        // alias applied.
        sql = sql.replacingOccurrences(of: "SELECT \(Self.summaryColumns) FROM clip_fts",
                                       with: "SELECT \(Self.aliasedSummaryColumns) FROM clip_fts")
        return try await db.query(sql, values).map(decodeSummary)
    }

    /// Chips-only queries skip FTS entirely — there is nothing to MATCH against, and the composite
    /// `(filter, copied_at DESC)` indexes serve these directly with no sort step.
    private func filtered(
        _ query: SearchQuery, limit: Int, sort: ClipSort = .automatic
    ) async throws -> [ClipSummary] {
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
        sql += " ORDER BY \(Self.orderClause(sort, pinnedFirst: true)) LIMIT ?;"
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

    /// Resolves a stored relative path to a file URL, so views can load a thumbnail lazily by URL
    /// rather than the view model holding image bytes.
    public func thumbnailURL(relativePath: String) async -> URL? {
        await blobs.absoluteURL(relativePath: relativePath)
    }

    /// The full-resolution image for a clip, for previews large enough that a thumbnail would show.
    ///
    /// Thumbnails are capped at 256px. Displaying one in a window half the height of the screen
    /// upscales it several times over, which is exactly the blur.
    public func fullImageURL(forClip id: Int64) async throws -> URL? {
        guard let path = try await imageBlobPath(forClip: id) else { return nil }
        return await blobs.absoluteURL(relativePath: path)
    }

    /// Text Vision recognised inside an image (spec §4.8).
    ///
    /// Populated asynchronously by the enrichment pipeline, so a very recently captured screenshot
    /// may not have it yet — callers should be able to ask for it to be produced on demand rather
    /// than reporting "no text" when the answer is really "not yet".
    public func ocrText(forClip id: Int64) async throws -> String? {
        let text = try await db.query(
            "SELECT ocr_text FROM clips WHERE id = ?;", [.int(id)]).first?.string(0)
        return (text?.isEmpty ?? true) ? nil : text
    }

    public func imageBlobPath(forClip id: Int64) async throws -> String? {
        try await db.query(
            "SELECT image_blob_path FROM clips WHERE id = ?;", [.int(id)]).first?.string(0)
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
        try? await pruneOrphanTags()
        return doomed
    }

    /// Surfaced in Settings so the user can see what the history is costing them (spec §4.19).
    public func storageSizeBytes() async -> Int64 {
        await blobs.totalSizeBytes()
    }


    // MARK: - Mutations

    /// Edits a text clip's content (spec §4.11).
    ///
    /// `body` is an FTS-indexed column, so this UPDATE is seen by the `clips_au` trigger and the
    /// index is rewritten for this row: the clip becomes findable by its new text and stops being
    /// findable by its old. Doing this through raw SQL elsewhere would silently desynchronise the
    /// index, which is why `ClipStore` exposes no raw SQL at all.
    public func updateText(id: Int64, to newText: String) async throws {
        // Long text lives in a blob with only the indexed prefix inline, so both have to move
        // together or a search hit would open a clip showing different content.
        var body = newText
        var blobPath: String?
        if newText.utf8.count > SizeLimits.textBlobThreshold {
            let uuid = try await self.uuid(for: id) ?? UUID()
            blobPath = try await blobs.write(
                Data(newText.utf8), uuid: uuid, ext: "txt",
                maxBytes: SizeLimits.maxCaptureBytesCeiling)
            body = String(newText.prefix(SizeLimits.maxIndexedBodyBytes))
        }

        try await db.run(
            """
            UPDATE clips SET body = ?, text_blob_path = ?, content_hash = ?, content_size_bytes = ?
            WHERE id = ?;
            """,
            [.text(body), .optional(blobPath), .text(Dedupe.hash(newText)),
             .int(Int64(newText.utf8.count)), .int(id)])

        if let summary = try await summary(id: id) { publish(.updated(summary)) }
    }

    private func uuid(for id: Int64) async throws -> UUID? {
        try await db.query("SELECT uuid FROM clips WHERE id = ?;", [.int(id)])
            .first.flatMap { $0.string(0) }.flatMap(UUID.init(uuidString:))
    }

    public func setPinned(_ pinned: Bool, ids: [Int64]) async throws {
        try await setFlag("is_pinned", pinned, ids: ids)
    }

    public func setFavorite(_ favorite: Bool, ids: [Int64]) async throws {
        try await setFlag("is_favorite", favorite, ids: ids)
    }

    public func setSensitivity(_ sensitivity: Sensitivity, id: Int64) async throws {
        try await db.run(
            "UPDATE clips SET sensitivity = ? WHERE id = ?;",
            [.int(sensitivity.rawValue), .int(id)])
        if let summary = try await summary(id: id) { publish(.updated(summary)) }
    }

    /// Column name is interpolated, never bound — PRAGMA-style identifiers cannot be parameters.
    /// Only ever called with the two literals above, never with user input.
    private func setFlag(_ column: String, _ value: Bool, ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        // Not an FTS column, so this deliberately does not touch the index — which is exactly why
        // the clips_au trigger is scoped with UPDATE OF.
        try await db.run(
            "UPDATE clips SET \(column) = ? WHERE id IN (\(placeholders));",
            [.bool(value)] + ids.map { .int($0) })
        for id in ids {
            if let summary = try await summary(id: id) { publish(.updated(summary)) }
        }
    }

    // MARK: - Facets

    /// An app that has produced clips, for the Library's app filter.
    ///
    /// A struct rather than a labelled tuple. Tuples returned across an actor boundary are fragile
    /// — adding a second such method caused this one to crash inside the runtime's tuple handling
    /// with a bogus "Double cannot be converted to Int64", in code that had not been touched. A
    /// struct is clearer at the call site anyway.
    public struct SourceApp: Sendable, Equatable {
        public var bundleId: String
        public var name: String
        public var count: Int
    }

    /// Apps that have actually produced clips, most prolific first, for the Library's app filter.
    /// Served by `idx_clips_app_time`.
    public func sourceApps() async throws -> [SourceApp] {
        try await db.query(
            """
            SELECT source_app_bundle_id, COALESCE(MAX(source_app_name), ''), COUNT(*)
            FROM clips WHERE source_app_bundle_id IS NOT NULL
            GROUP BY source_app_bundle_id ORDER BY COUNT(*) DESC;
            """
        ).map { SourceApp(bundleId: $0.string(0) ?? "", name: $0.string(1) ?? "", count: $0.int(2)) }
    }

    /// Counts per content type, for the filter chips.
    public func typeCounts() async throws -> [ClipContentType: Int] {
        var counts: [ClipContentType: Int] = [:]
        for row in try await db.query("SELECT content_type, COUNT(*) FROM clips GROUP BY content_type;") {
            if let type = ClipContentType(rawValue: row.int(0)) { counts[type] = row.int(1) }
        }
        return counts
    }

    public struct Counts: Sendable, Equatable {
        public var total: Int
        public var pinned: Int
        public var favorites: Int
        public var secrets: Int
    }

    public func counts() async throws -> Counts {
        let row = try await db.query("""
            SELECT COUNT(*),
                   SUM(is_pinned), SUM(is_favorite),
                   SUM(CASE WHEN sensitivity = 2 THEN 1 ELSE 0 END)
            FROM clips;
            """).first
        return Counts(total: row?.int(0) ?? 0, pinned: row?.int(1) ?? 0,
                      favorites: row?.int(2) ?? 0, secrets: row?.int(3) ?? 0)
    }

    /// Bulk insert for fixtures and backfills.
    ///
    /// Publishing is suppressed for the duration: emitting 10,000 individual UI deltas would cost
    /// far more than the single reload the caller does afterwards, and would make the timeline
    /// thrash while the import ran. `Task.yield()` between chunks keeps the actor from monopolising
    /// the cooperative pool.
    public func insertBatch(_ clips: [CapturedClip]) async throws {
        isPublishingSuppressed = true
        defer { isPublishingSuppressed = false }

        for chunk in stride(from: 0, to: clips.count, by: 500) {
            for clip in clips[chunk..<min(chunk + 500, clips.count)] {
                _ = try await insert(clip)
            }
            await Task.yield()
        }
    }


    // MARK: - Categories

    public func categories() async throws -> [ClipCategory] {
        try await db.query(
            "SELECT id, uuid, name, color_hex, icon_name, sort_order, is_smart FROM categories ORDER BY sort_order, name;"
        ).map { row in
            ClipCategory(
                id: row.int64(0),
                uuid: UUID(uuidString: row.string(1) ?? "") ?? UUID(),
                name: row.string(2) ?? "",
                colorHex: row.string(3),
                iconName: row.string(4),
                sortOrder: row.int(5),
                isSmart: row.bool(6))
        }
    }

    @discardableResult
    public func createCategory(name: String, colorHex: String? = nil, iconName: String? = nil) async throws -> ClipCategory {
        let uuid = UUID()
        let order = try await db.query("SELECT COALESCE(MAX(sort_order), 0) + 1 FROM categories;")
            .first?.int(0) ?? 0
        let id = try await db.run(
            "INSERT INTO categories (uuid, name, color_hex, icon_name, sort_order) VALUES (?,?,?,?,?);",
            [.text(uuid.uuidString), .text(name), .optional(colorHex), .optional(iconName), .int(order)])
        return ClipCategory(id: id, uuid: uuid, name: name, colorHex: colorHex,
                        iconName: iconName, sortOrder: order)
    }

    public func renameCategory(id: Int64, to name: String) async throws {
        try await db.run("UPDATE categories SET name = ? WHERE id = ?;", [.text(name), .int(id)])
    }

    /// Deleting a category removes its assignments via ON DELETE CASCADE but never the clips
    /// themselves — a category is a label, and losing clips because a label was tidied away would
    /// be indefensible.
    public func deleteCategory(id: Int64) async throws {
        try await db.run("DELETE FROM categories WHERE id = ?;", [.int(id)])
    }

    public func assign(clipIds: [Int64], toCategory categoryId: Int64) async throws {
        guard !clipIds.isEmpty else { return }
        for id in clipIds {
            try await db.run(
                "INSERT OR IGNORE INTO clip_categories (clip_id, category_id) VALUES (?,?);",
                [.int(id), .int(categoryId)])
        }
    }

    public func unassign(clipIds: [Int64], fromCategory categoryId: Int64) async throws {
        for id in clipIds {
            try await db.run(
                "DELETE FROM clip_categories WHERE clip_id = ? AND category_id = ?;",
                [.int(id), .int(categoryId)])
        }
    }

    public func categoryIds(forClip clipId: Int64) async throws -> Set<Int64> {
        Set(try await db.query(
            "SELECT category_id FROM clip_categories WHERE clip_id = ?;", [.int(clipId)]
        ).map { $0.int64(0) })
    }

    public func categoryCounts() async throws -> [Int64: Int] {
        var counts: [Int64: Int] = [:]
        for row in try await db.query(
            "SELECT category_id, COUNT(*) FROM clip_categories GROUP BY category_id;") {
            counts[row.int64(0)] = row.int(1)
        }
        return counts
    }

    public func clips(inCategory categoryId: Int64, limit: Int = 200) async throws -> [ClipSummary] {
        try await db.query(
            """
            SELECT \(Self.aliasedSummaryColumns) FROM clips c
            JOIN clip_categories cc ON cc.clip_id = c.id
            WHERE cc.category_id = ? ORDER BY c.is_pinned DESC, c.copied_at DESC LIMIT ?;
            """, [.int(categoryId), .int(limit)]).map(decodeSummary)
    }

    // MARK: - Smart filter rules

    public func smartFilterRules() async throws -> [SmartFilterRule] {
        try await db.query(
            """
            SELECT id, uuid, name, category_id, enabled, content_type,
                   source_app_bundle_id, text_pattern, is_regex, sort_order
            FROM smart_filter_rules ORDER BY sort_order, id;
            """
        ).map { row in
            SmartFilterRule(
                id: row.int64(0),
                uuid: UUID(uuidString: row.string(1) ?? "") ?? UUID(),
                name: row.string(2) ?? "",
                categoryId: row.int64(3),
                enabled: row.bool(4),
                contentType: row.isNull(5) ? nil : ClipContentType(rawValue: row.int(5)),
                sourceAppBundleId: row.string(6),
                textPattern: row.string(7),
                isRegex: row.bool(8),
                sortOrder: row.int(9))
        }
    }

    @discardableResult
    public func createRule(_ rule: SmartFilterRule) async throws -> Int64 {
        try await db.run(
            """
            INSERT INTO smart_filter_rules
              (uuid, name, category_id, enabled, content_type, source_app_bundle_id,
               text_pattern, is_regex, sort_order)
            VALUES (?,?,?,?,?,?,?,?,?);
            """,
            [.text(rule.uuid.uuidString), .text(rule.name), .int(rule.categoryId),
             .bool(rule.enabled),
             rule.contentType.map { SQLValue.int($0.rawValue) } ?? .null,
             .optional(rule.sourceAppBundleId), .optional(rule.textPattern),
             .bool(rule.isRegex), .int(rule.sortOrder)])
    }

    public func updateRule(_ rule: SmartFilterRule) async throws {
        try await db.run(
            """
            UPDATE smart_filter_rules SET name = ?, category_id = ?, enabled = ?, content_type = ?,
              source_app_bundle_id = ?, text_pattern = ?, is_regex = ? WHERE id = ?;
            """,
            [.text(rule.name), .int(rule.categoryId), .bool(rule.enabled),
             rule.contentType.map { SQLValue.int($0.rawValue) } ?? .null,
             .optional(rule.sourceAppBundleId), .optional(rule.textPattern),
             .bool(rule.isRegex), .int(rule.id)])
    }

    public func deleteRule(id: Int64) async throws {
        try await db.run("DELETE FROM smart_filter_rules WHERE id = ?;", [.int(id)])
    }

    /// Everything a rule needs to be evaluated against, for retroactive application.
    public struct RuleCandidate: Sendable {
        public var id: Int64
        public var candidate: SmartFilterEngine.Candidate
    }

    public func ruleCandidates(limit: Int, after id: Int64) async throws -> [RuleCandidate] {
        try await db.query(
            """
            SELECT id, content_type, source_app_bundle_id, source_app_name, body, ocr_text
            FROM clips WHERE id > ? ORDER BY id LIMIT ?;
            """, [.int(id), .int(limit)]
        ).map { row in
            RuleCandidate(
                id: row.int64(0),
                candidate: SmartFilterEngine.Candidate(
                contentType: ClipContentType(rawValue: row.int(1)) ?? .unknown,
                sourceAppBundleId: row.string(2),
                sourceAppName: row.string(3),
                // OCR text counts: "everything mentioning invoice" should catch a photographed
                // receipt, not only typed text.
                text: [row.string(4), row.string(5)].compactMap { $0 }.joined(separator: "\n")))
        }
    }

    // MARK: - Tags

    public func addTags(_ names: Set<String>, toClip clipId: Int64) async throws {
        for name in names {
            let clean = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !clean.isEmpty, clean.count <= 40 else { continue }
            try await db.run("INSERT OR IGNORE INTO tags (name) VALUES (?);", [.text(clean)])
            guard let tagId = try await db.query(
                "SELECT id FROM tags WHERE name = ?;", [.text(clean)]).first?.int64(0) else { continue }
            try await db.run(
                "INSERT OR IGNORE INTO clip_tags (clip_id, tag_id) VALUES (?,?);",
                [.int(clipId), .int(tagId)])
        }
    }

    public func removeTag(_ name: String, fromClip clipId: Int64) async throws {
        try await db.run(
            """
            DELETE FROM clip_tags WHERE clip_id = ?
              AND tag_id = (SELECT id FROM tags WHERE name = ?);
            """, [.int(clipId), .text(name.lowercased())])
    }

    public func tags(forClip clipId: Int64) async throws -> [String] {
        try await db.query(
            """
            SELECT t.name FROM tags t JOIN clip_tags ct ON ct.tag_id = t.id
            WHERE ct.clip_id = ? ORDER BY t.name;
            """, [.int(clipId)]).compactMap { $0.string(0) }
    }

    /// Tag frequencies for the cloud (spec §4.6), most used first.
    public struct TagCount: Sendable, Equatable {
        public var name: String
        public var count: Int
    }

    public func tagCounts(limit: Int = 40) async throws -> [TagCount] {
        try await db.query(
            """
            SELECT t.name, COUNT(*) FROM tags t JOIN clip_tags ct ON ct.tag_id = t.id
            GROUP BY t.id ORDER BY COUNT(*) DESC, t.name LIMIT ?;
            """, [.int(limit)]
        ).map { TagCount(name: $0.string(0) ?? "", count: $0.int(1)) }
    }

    public func clips(withTag name: String, limit: Int = 200) async throws -> [ClipSummary] {
        try await db.query(
            """
            SELECT \(Self.aliasedSummaryColumns) FROM clips c
            JOIN clip_tags ct ON ct.clip_id = c.id
            JOIN tags t ON t.id = ct.tag_id
            WHERE t.name = ? ORDER BY c.is_pinned DESC, c.copied_at DESC LIMIT ?;
            """, [.text(name.lowercased()), .int(limit)]).map(decodeSummary)
    }

    /// Removes tags no clip references any more, so the cloud does not accumulate dead entries
    /// after a retention sweep.
    public func pruneOrphanTags() async throws {
        try await db.run(
            "DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM clip_tags);")
    }

    // MARK: - Inline shortcuts

    /// shortcut text → clip id, for the matcher.
    public func shortcuts() async throws -> [String: Int64] {
        var map: [String: Int64] = [:]
        for row in try await db.query(
            "SELECT shortcut, id FROM clips WHERE shortcut IS NOT NULL;") {
            if let shortcut = row.string(0) { map[shortcut] = row.int64(1) }
        }
        return map
    }

    /// Assigns or clears a clip's shortcut.
    ///
    /// A unique partial index enforces one clip per shortcut at the database level, so a race
    /// between two assignment sheets cannot produce two clips claiming the same expansion.
    public func setShortcut(_ shortcut: String?, id: Int64) async throws {
        try await db.run(
            "UPDATE clips SET shortcut = ? WHERE id = ?;", [.optional(shortcut), .int(id)])
        if let summary = try await summary(id: id) { publish(.updated(summary)) }
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
