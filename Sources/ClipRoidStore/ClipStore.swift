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
