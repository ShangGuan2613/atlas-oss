import Foundation
import Testing
@testable import AtlasCore

/// P1-C migration gate: schema v3 is additive, so a v1 *or* v2 library must land on
/// `AtlasSchema.currentVersion` (v3, then v4 with P2-A) with every P0/P1-B row intact and no
/// palette data invented.
@Suite("P1-C · schema v3")
struct SchemaV3Tests {

    /// Builds a real v2 library on disk: v1 + v2 DDL, a seeded Inbox, one connected item.
    private func makeV2Library(in workspace: TemporaryWorkspace, itemID: UUID = UUID()) throws -> LibraryPaths {
        let paths = workspace.libraryPaths
        try paths.createDirectories()
        let database = try SQLiteDatabase(path: paths.databaseURL.path)
        try database.execute(AtlasSchema.v1)
        try database.run("INSERT INTO library_meta (key, value) VALUES ('library_id', 'v2-legacy');")
        try database.execute(AtlasSchema.v2)

        let inboxID = UUID()
        try database.run("""
        INSERT INTO collections (id, name, created_at, updated_at, parent_id, sort_order)
        VALUES (?, 'Inbox', 0, 0, NULL, ?);
        """, [.text(inboxID.uuidString), .real(AtlasSchema.inboxSortOrder)])
        try database.run(
            "INSERT INTO library_meta (key, value) VALUES (?, ?);",
            [.text(AtlasSchema.inboxMetaKey), .text(inboxID.uuidString)]
        )
        try database.run("""
        INSERT INTO items (id, kind, mode, file_name, source_path, byte_size, content_hash, imported_at)
        VALUES (?, 'image', 'connected', 'legacy.png', '/tmp/legacy.png', 42, 'hash-legacy', 0);
        """, [.text(itemID.uuidString)])
        try database.run(
            "INSERT INTO collection_items (collection_id, item_id, added_at) VALUES (?, ?, 0);",
            [.text(inboxID.uuidString), .text(itemID.uuidString)]
        )

        database.userVersion = 2
        #expect(Int(database.userVersion) == 2)
        database.close()
        return paths
    }

    /// Builds a real v1 library (no Inbox, flat collections).
    private func makeV1Library(in workspace: TemporaryWorkspace) throws -> LibraryPaths {
        let paths = workspace.libraryPaths
        try paths.createDirectories()
        let database = try SQLiteDatabase(path: paths.databaseURL.path)
        try database.execute(AtlasSchema.v1)
        try database.run("INSERT INTO library_meta (key, value) VALUES ('library_id', 'v1-legacy');")
        try database.run(
            "INSERT INTO collections (id, name, created_at, updated_at) VALUES (?, 'Moodboard', 0, 0);",
            [.text(UUID().uuidString)]
        )
        database.userVersion = 1
        database.close()
        return paths
    }

    @Test("a v2 library gains the palette tables and keeps its rows")
    func v2MigratesToV3() throws {
        let workspace = try TemporaryWorkspace(label: "v2-to-v3")
        let itemID = UUID()
        let paths = try makeV2Library(in: workspace, itemID: itemID)

        let library = try AtlasLibrary(paths: paths)
        defer { library.close() }

        let database = try SQLiteDatabase(path: library.paths.databaseURL.path)
        defer { database.close() }

        #expect(Int(database.userVersion) == Int(AtlasSchema.currentVersion))
        #expect(AtlasSchema.currentVersion >= 3)
        #expect(try library.info().schemaVersion == Int(AtlasSchema.currentVersion))

        let tables = try objectNames(database, type: "table")
        #expect(tables.isSuperset(of: ["item_colors", "item_palette"]))
        let indexes = try objectNames(database, type: "index")
        #expect(indexes.contains("ix_item_colors_hex"))

        // Migration is additive: existing data untouched, no palette invented.
        #expect(try library.itemCount() == 1)
        #expect(try library.item(id: itemID)?.fileName == "legacy.png")
        #expect(try library.inboxItemCount() == 1)
        #expect(try library.cachedColors(forItemID: itemID).isEmpty)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM item_colors;") == 0)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM item_palette;") == 0)
    }

    @Test("a v1 library migrates straight through to v3")
    func v1MigratesToV3() throws {
        let workspace = try TemporaryWorkspace(label: "v1-to-v3")
        let paths = try makeV1Library(in: workspace)

        let library = try AtlasLibrary(paths: paths)
        defer { library.close() }

        let database = try SQLiteDatabase(path: library.paths.databaseURL.path)
        defer { database.close() }

        #expect(Int(database.userVersion) == Int(AtlasSchema.currentVersion))
        #expect(try objectNames(database, type: "table").isSuperset(of: ["tags", "item_tags", "item_colors", "item_palette"]))
        // The v2 step still ran: Inbox exists and the v1 folder survived as a root node.
        #expect(try library.inboxCollection().isInbox)
        #expect(try library.collectionTree().map(\.name) == ["Inbox", "Moodboard"])
    }

    @Test("v3 migration is idempotent — reopening neither reseeds nor renumbers")
    func migrationIsIdempotent() throws {
        let workspace = try TemporaryWorkspace(label: "v3-idempotent")
        let paths = try makeV2Library(in: workspace)

        let first = try AtlasLibrary(paths: paths)
        let inboxID = try first.inboxCollection().id
        let tree = try first.collectionTree().map(\.name)
        let itemID = try #require(try first.items().first).id
        // The legacy row points at a file that is not on disk: probing stores an empty
        // palette plus its fingerprint instead of re-probing forever.
        #expect(try first.dominantColors(for: itemID).isEmpty)
        first.close()

        let second = try AtlasLibrary(paths: paths)
        defer { second.close() }
        let database = try SQLiteDatabase(path: second.paths.databaseURL.path)
        defer { database.close() }

        #expect(Int(database.userVersion) == Int(AtlasSchema.currentVersion))
        #expect(try second.inboxCollection().id == inboxID)
        #expect(try second.collectionTree().map(\.name) == tree)
        #expect(try second.hasCurrentPalette(for: itemID))
        #expect(try database.scalarInt("SELECT COUNT(*) FROM item_palette;") == 1)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM item_colors;") == 0)
    }

    // MARK: - Helpers

    private func objectNames(_ database: SQLiteDatabase, type: String) throws -> Set<String> {
        let statement = try database.prepare("SELECT name FROM sqlite_master WHERE type = ?;")
        try statement.bind([.text(type)])
        var names: Set<String> = []
        while try statement.step() {
            if let name = statement.text(0) { names.insert(name) }
        }
        return names
    }
}
