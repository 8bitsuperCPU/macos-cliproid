import Foundation
import os.log

/// Ascending `PRAGMA user_version` migrations, same shape as
/// ~/projects/Mail-Export/Sources/MailExport/Database/Migrations.swift.
///
/// Rules that keep this safe as the schema grows:
///  - migrations only ever go up, one step at a time, and never change an already-shipped step;
///  - anything altering `clips`' column set takes a `VACUUM INTO` snapshot first (spec §10).
public enum Migrations {
    public static let current = 1

    private static let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Migrations")

    public static func run(on db: Database, backupDirectory: URL?) async throws {
        let version = try await db.userVersion()
        guard version < current else { return }

        if version > 0, let backupDirectory {
            try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = backupDirectory.appendingPathComponent("ClipRoid-v\(version)-\(stamp).sqlite")
            try await db.backup(to: url)
            logger.info("Pre-migration snapshot written")
        }

        if version < 1 {
            try await db.execute(migration1)
            try await db.setUserVersion(1)
            logger.info("Applied migration 1")
        }
    }

    // MARK: - Migration 1

    /// Note on column naming: `body`, `ocr_text` and `title` are named to match the FTS5 column
    /// names exactly. FTS5 external-content tables require that correspondence, which is why these
    /// are not called `content_text` / `link_title`. Small ugliness, and the alternative is a view
    /// plus hand-written trigger bodies.
    static let migration1 = """
    CREATE TABLE clips (
      id                 INTEGER PRIMARY KEY,
      uuid               TEXT    NOT NULL UNIQUE,
      content_type       INTEGER NOT NULL,
      content_hash       TEXT    NOT NULL,

      body               TEXT,
      ocr_text           TEXT,
      title              TEXT,

      text_blob_path     TEXT,
      image_blob_path    TEXT,
      thumb_blob_path    TEXT,
      html_blob_path     TEXT,
      favicon_blob_path  TEXT,
      image_width        INTEGER,
      image_height       INTEGER,
      exif_json          TEXT,

      color_hex          TEXT,
      link_url           TEXT,
      link_host          TEXT,

      source_app_bundle_id TEXT,
      source_app_name      TEXT,
      source_window_title  TEXT,
      source_url           TEXT,

      copied_at          INTEGER NOT NULL,
      stored_at          INTEGER NOT NULL,
      content_size_bytes INTEGER NOT NULL DEFAULT 0,
      repeat_count       INTEGER NOT NULL DEFAULT 1,

      is_pinned          INTEGER NOT NULL DEFAULT 0,
      is_favorite        INTEGER NOT NULL DEFAULT 0,
      is_local_only      INTEGER NOT NULL DEFAULT 0,
      sensitivity        INTEGER NOT NULL DEFAULT 0,
      sensitive_reason   TEXT,
      shortcut           TEXT,
      reminder_at        INTEGER,
      reminder_type      INTEGER,
      reminder_bundle_id TEXT,
      notes              TEXT,
      enrichment_state   INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE files (
      clip_id   INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
      ordinal   INTEGER NOT NULL,
      path      TEXT    NOT NULL,
      bookmark  BLOB,
      size_bytes INTEGER,
      uti       TEXT,
      icon_blob_path TEXT,
      PRIMARY KEY (clip_id, ordinal)
    );

    CREATE TABLE categories (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      color_hex TEXT,
      icon_name TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0,
      is_smart INTEGER NOT NULL DEFAULT 0,
      smart_rule_id INTEGER
    );

    CREATE TABLE clip_categories (
      clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
      category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
      PRIMARY KEY (clip_id, category_id)
    );
    CREATE INDEX idx_clip_categories_rev ON clip_categories(category_id, clip_id);

    CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
    CREATE TABLE clip_tags (
      clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
      tag_id  INTEGER NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
      PRIMARY KEY (clip_id, tag_id)
    );
    CREATE INDEX idx_clip_tags_rev ON clip_tags(tag_id, clip_id);

    CREATE TABLE smart_filter_rules (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
      enabled INTEGER NOT NULL DEFAULT 1,
      content_type INTEGER,
      source_app_bundle_id TEXT,
      text_pattern TEXT,
      is_regex INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0
    );

    -- The (filter, copied_at DESC) pairs let the common browse queries — "images, newest first",
    -- "everything from Figma, newest first" — be answered entirely from an index, with no sort step.
    CREATE INDEX idx_clips_time      ON clips(copied_at DESC);
    CREATE INDEX idx_clips_type_time ON clips(content_type, copied_at DESC);
    CREATE INDEX idx_clips_app_time  ON clips(source_app_bundle_id, copied_at DESC);
    CREATE INDEX idx_clips_hash      ON clips(content_hash, copied_at DESC);

    -- Partial indexes: near-free, because the qualifying sets are tiny.
    CREATE INDEX idx_clips_pinned   ON clips(copied_at DESC) WHERE is_pinned   = 1;
    CREATE INDEX idx_clips_favorite ON clips(copied_at DESC) WHERE is_favorite = 1;
    CREATE INDEX idx_clips_secret   ON clips(copied_at)      WHERE sensitivity = 2;
    CREATE INDEX idx_clips_pending  ON clips(id)             WHERE enrichment_state = 0;
    CREATE UNIQUE INDEX idx_clips_shortcut ON clips(shortcut) WHERE shortcut IS NOT NULL;

    -- External content, not contentless: snippet() and highlight() have to re-read the source
    -- text, and search results in this app are cards showing the matched region. Contentless would
    -- mean re-implementing snippet in Swift over the full body.
    --
    -- source_app_name is deliberately NOT an FTS column. App filtering is an exact predicate served
    -- by idx_clips_app_time; indexing the name would make every clip from Safari match a free-text
    -- search for "safari". The @Safari token is parsed into a WHERE clause, never a MATCH term.
    CREATE VIRTUAL TABLE clip_fts USING fts5(
      body,
      ocr_text,
      title,
      content='clips',
      content_rowid='id',
      tokenize='unicode61 remove_diacritics 2',
      prefix='2 3 4'
    );

    CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
      INSERT INTO clip_fts(rowid, body, ocr_text, title)
      VALUES (new.id, new.body, new.ocr_text, new.title);
    END;

    -- The 'delete' command form is mandatory for an external-content table, and it must be given
    -- the OLD values. A plain DELETE FROM clip_fts corrupts the index.
    CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
      INSERT INTO clip_fts(clip_fts, rowid, body, ocr_text, title)
      VALUES ('delete', old.id, old.body, old.ocr_text, old.title);
    END;

    -- Scoped to the indexed columns with UPDATE OF. Without that scoping, every pin or favourite
    -- toggle would rewrite the row's FTS entry.
    CREATE TRIGGER clips_au AFTER UPDATE OF body, ocr_text, title ON clips BEGIN
      INSERT INTO clip_fts(clip_fts, rowid, body, ocr_text, title)
      VALUES ('delete', old.id, old.body, old.ocr_text, old.title);
      INSERT INTO clip_fts(rowid, body, ocr_text, title)
      VALUES (new.id, new.body, new.ocr_text, new.title);
    END;
    """
}
