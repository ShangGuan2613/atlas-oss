import Foundation

/// Versioned schema. `PRAGMA user_version` is the migration cursor.
///
/// | version | contents |
/// |---------|----------|
/// | 1       | `library_meta`, `collections` (flat), `items`, `collection_items` |
/// | 2       | nested collections (`parent_id`, `sort_order`), `tags`, `item_tags`, seeded **Inbox** |
/// | 3       | `item_colors`, `item_palette` — cached dominant colours (P1-C) |
/// | 4       | `item_positions` — Canvas board placement per scope (P2-A) |
public enum AtlasSchema {
    public static let currentVersion: Int32 = 4

    /// Reserved name of the system collection that every import lands in.
    public static let inboxCollectionName = "Inbox"

    /// `library_meta` key holding the Inbox collection id.
    public static let inboxMetaKey = "inbox_collection_id"

    /// Sort order given to the Inbox so it always sorts above user collections.
    public static let inboxSortOrder: Double = -1000

    public static func migrate(_ database: SQLiteDatabase) throws {
        let version = database.userVersion
        guard version < currentVersion else { return }

        if version < 1 {
            try database.transaction {
                try database.execute(v1)
                try database.run(
                    "INSERT OR IGNORE INTO library_meta (key, value) VALUES ('library_id', ?);",
                    [.text(UUID().uuidString)]
                )
                try database.run(
                    "INSERT OR IGNORE INTO library_meta (key, value) VALUES ('created_at', ?);",
                    [.real(Date().timeIntervalSince1970)]
                )
            }
            database.userVersion = 1
        }

        if version < 2 {
            try database.transaction {
                try database.execute(v2)
                try backfillCollectionSortOrder(database)
                try seedInboxCollection(database)
            }
            database.userVersion = 2
        }

        if version < 3 {
            // Purely additive: two empty tables. A v2 library keeps working with no
            // palette rows at all — colours are extracted lazily on first Info open.
            try database.transaction {
                try database.execute(v3)
            }
            database.userVersion = 3
        }

        if version < 4 {
            // Purely additive: one empty table. A v3 library keeps every item, collection
            // and tag; its Canvas simply has no explicit placement yet, so the board
            // auto-packs from the current sort order on first open and writes that layout
            // back. Nothing is rewritten or dropped here, so there is no data to lose.
            try database.transaction {
                try database.execute(v4)
            }
            database.userVersion = 4
        }
    }

    // MARK: - v1

    static let v1 = """
    CREATE TABLE IF NOT EXISTS library_meta (
        key   TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS collections (
        id         TEXT PRIMARY KEY NOT NULL,
        name       TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS ux_collections_name ON collections(name);

    -- `mode` decides item identity:
    --   connected -> identity is the absolute path (indexed in place)
    --   copy      -> identity is the content hash (dedupe across imports)
    CREATE TABLE IF NOT EXISTS items (
        id               TEXT PRIMARY KEY NOT NULL,
        kind             TEXT NOT NULL CHECK (kind IN ('image', 'video', 'other')),
        mode             TEXT NOT NULL CHECK (mode IN ('copy', 'connected')),
        file_name        TEXT NOT NULL,
        source_path      TEXT,
        stored_name      TEXT,
        width            INTEGER,
        height           INTEGER,
        byte_size        INTEGER NOT NULL DEFAULT 0,
        content_hash     TEXT NOT NULL,
        imported_at      REAL NOT NULL,
        file_created_at  REAL,
        file_modified_at REAL,
        CHECK (
            (mode = 'connected' AND source_path IS NOT NULL AND stored_name IS NULL) OR
            (mode = 'copy'      AND stored_name IS NOT NULL AND source_path IS NULL)
        )
    );
    CREATE UNIQUE INDEX IF NOT EXISTS ux_items_connected_path
        ON items(source_path) WHERE mode = 'connected';
    CREATE UNIQUE INDEX IF NOT EXISTS ux_items_copy_hash
        ON items(kind, content_hash) WHERE mode = 'copy';
    CREATE INDEX IF NOT EXISTS ix_items_hash ON items(content_hash);
    CREATE INDEX IF NOT EXISTS ix_items_imported_at ON items(imported_at);
    CREATE INDEX IF NOT EXISTS ix_items_kind ON items(kind);

    CREATE TABLE IF NOT EXISTS collection_items (
        collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
        item_id       TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        added_at      REAL NOT NULL,
        PRIMARY KEY (collection_id, item_id)
    );
    CREATE INDEX IF NOT EXISTS ix_collection_items_item ON collection_items(item_id);
    """

    // MARK: - v2

    /// Nested collections + tags.
    ///
    /// **Name uniqueness.** v1 had a global `UNIQUE(name)`. v2 needs siblings under
    /// different parents to share a name, so the v1 index is dropped and recreated under
    /// the *same name* as an expression index over `(COALESCE(parent_id, ''), name)`.
    /// Root collections are treated as siblings of one another via the `''` sentinel for
    /// a `NULL` parent. Keeping the index name means v1 tooling (`SchemaTests`,
    /// external `.sqlite` inspection) still finds `ux_collections_name`.
    static let v2 = """
    ALTER TABLE collections ADD COLUMN parent_id TEXT REFERENCES collections(id) ON DELETE SET NULL;
    ALTER TABLE collections ADD COLUMN sort_order REAL NOT NULL DEFAULT 0;

    DROP INDEX IF EXISTS ux_collections_name;
    CREATE UNIQUE INDEX IF NOT EXISTS ux_collections_name
        ON collections(COALESCE(parent_id, ''), name);
    CREATE INDEX IF NOT EXISTS ix_collections_parent ON collections(parent_id, sort_order);

    CREATE TABLE IF NOT EXISTS tags (
        id         TEXT PRIMARY KEY NOT NULL,
        name       TEXT NOT NULL,
        created_at REAL NOT NULL,
        color      TEXT
    );
    CREATE UNIQUE INDEX IF NOT EXISTS ux_tags_name ON tags(name);

    CREATE TABLE IF NOT EXISTS item_tags (
        tag_id   TEXT NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
        item_id  TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        added_at REAL NOT NULL,
        PRIMARY KEY (tag_id, item_id)
    );
    CREATE INDEX IF NOT EXISTS ix_item_tags_item ON item_tags(item_id);
    """

    // MARK: - v3

    /// Cached dominant colours.
    ///
    /// `item_colors` is the palette itself — one row per ranked swatch, `rank` 0 being the
    /// most prominent. It is *derived* data: drop the table and the next probe rebuilds it,
    /// so no user-visible information lives here.
    ///
    /// `item_palette` is the one-row-per-item fingerprint that decides whether the cache is
    /// still valid. It has to exist separately from `item_colors` because a legitimately
    /// palette-less item (a video, a fully transparent PNG) has zero colour rows and would
    /// otherwise be re-probed on every Info open.
    static let v3 = """
    CREATE TABLE IF NOT EXISTS item_palette (
        item_id      TEXT PRIMARY KEY NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        signature    TEXT NOT NULL,
        extracted_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS item_colors (
        item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        rank    INTEGER NOT NULL,
        hex     TEXT NOT NULL,
        weight  REAL NOT NULL,
        PRIMARY KEY (item_id, rank)
    );
    CREATE INDEX IF NOT EXISTS ix_item_colors_hex ON item_colors(hex);
    """

    // MARK: - v4

    /// Canvas board placement (P2-A).
    ///
    /// **One row per (scope, item).** A board is either the whole library ("All") or one
    /// collection, and the spec asks for both while allowing `collection_id` to be null for
    /// All. A genuinely `NULL` scope column would not work here: SQLite treats NULLs in a
    /// PRIMARY KEY as distinct, so `(NULL, item)` would accept duplicate rows and
    /// `INSERT OR REPLACE` would silently pile them up instead of moving the tile. `'all'`
    /// is the null-free encoding of "no collection" — see `CanvasScope.storageKey`.
    ///
    /// `x`/`y` are world points of the tile's **top-left corner**, `z_order` is the paint
    /// order (higher paints later) and `scale` is a per-item size multiplier. Deleting an
    /// item cascades its placement away, so a board can never reference a ghost row.
    static let v4 = """
    CREATE TABLE IF NOT EXISTS item_positions (
        scope      TEXT NOT NULL,
        item_id    TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        x          REAL NOT NULL,
        y          REAL NOT NULL,
        z_order    REAL NOT NULL DEFAULT 0,
        scale      REAL NOT NULL DEFAULT 1,
        updated_at REAL NOT NULL,
        PRIMARY KEY (scope, item_id)
    );
    CREATE INDEX IF NOT EXISTS ix_item_positions_item ON item_positions(item_id);
    """

    /// v1 collections all sit at root with `sort_order = 0`, which would make the sibling
    /// order depend on SQLite's row order. Backfill a deterministic sequence from
    /// `created_at` so a migrated library has a stable, drag-editable order from day one.
    private static func backfillCollectionSortOrder(_ database: SQLiteDatabase) throws {
        let statement = try database.prepare(
            "SELECT id FROM collections ORDER BY created_at ASC, name ASC;"
        )
        var ordered: [String] = []
        while try statement.step() {
            if let id = statement.text(0) { ordered.append(id) }
        }
        for (index, id) in ordered.enumerated() {
            try database.run(
                "UPDATE collections SET sort_order = ? WHERE id = ?;",
                [.real(Double(index)), .text(id)]
            )
        }
    }

    /// Seeds the Inbox and records its id in `library_meta`.
    ///
    /// A v1 library that already has a root collection literally named `Inbox` adopts it
    /// instead of creating a duplicate, so the migration never fails on the unique index.
    private static func seedInboxCollection(_ database: SQLiteDatabase) throws {
        let now = Date().timeIntervalSince1970

        if let existing = try database.scalarText(
            "SELECT id FROM collections WHERE name = ? AND parent_id IS NULL LIMIT 1;",
            [.text(inboxCollectionName)]
        ) {
            try database.run(
                "UPDATE collections SET sort_order = ? WHERE id = ?;",
                [.real(inboxSortOrder), .text(existing)]
            )
            try recordInbox(existing, database)
            return
        }

        let id = UUID().uuidString
        try database.run("""
        INSERT INTO collections (id, name, created_at, updated_at, parent_id, sort_order)
        VALUES (?, ?, ?, ?, NULL, ?);
        """, [.text(id), .text(inboxCollectionName), .real(now), .real(now), .real(inboxSortOrder)])
        try recordInbox(id, database)
    }

    private static func recordInbox(_ id: String, _ database: SQLiteDatabase) throws {
        try database.run(
            "INSERT OR REPLACE INTO library_meta (key, value) VALUES (?, ?);",
            [.text(inboxMetaKey), .text(id)]
        )
    }
}
