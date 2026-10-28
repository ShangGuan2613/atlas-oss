import Foundation
import Testing
@testable import AtlasCore

// MARK: - v1 → v2 migration

@Suite("P1-B · schema v2 migration")
struct SchemaV2MigrationTests {

    /// Builds a real v1 library on disk: v1 DDL, v1 `user_version`, v1-shaped rows.
    private func makeV1Library(in workspace: TemporaryWorkspace, collectionNames: [String]) throws -> LibraryPaths {
        let paths = workspace.libraryPaths
        try paths.createDirectories()
        let database = try SQLiteDatabase(path: paths.databaseURL.path)
        try database.execute(AtlasSchema.v1)
        try database.run("INSERT INTO library_meta (key, value) VALUES ('library_id', 'legacy');")

        for (index, name) in collectionNames.enumerated() {
            try database.run(
                "INSERT INTO collections (id, name, created_at, updated_at) VALUES (?, ?, ?, ?);",
                [.text(UUID().uuidString), .text(name), .real(Double(index)), .real(Double(index))]
            )
        }
        database.userVersion = 1
        #expect(Int(database.userVersion) == 1)
        database.close()
        return paths
    }

    @Test("a v1 library migrates in place to v2 and gains the Inbox")
    func v1MigratesInPlace() throws {
        let workspace = try TemporaryWorkspace(label: "v1-migrate")
        let paths = try makeV1Library(in: workspace, collectionNames: ["Moodboard", "References"])

        let library = try AtlasLibrary(paths: paths)
        defer { library.close() }

        let database = try SQLiteDatabase(path: library.paths.databaseURL.path)
        defer { database.close() }

        #expect(Int(database.userVersion) == Int(AtlasSchema.currentVersion))
        #expect(AtlasSchema.currentVersion >= 2)

        // v2 columns landed.
        let columns = try columnNames(database, table: "collections")
        #expect(columns.isSuperset(of: ["parent_id", "sort_order"]))

        // v2 tables landed.
        let tables = try objectNames(database, type: "table")
        #expect(tables.isSuperset(of: ["tags", "item_tags"]))

        // The v1 index name survives (recreated as a per-parent unique index).
        let indexes = try objectNames(database, type: "index")
        #expect(indexes.contains("ux_collections_name"))
        #expect(indexes.contains("ix_collections_parent"))
        #expect(indexes.contains("ux_tags_name"))

        // Inbox seeded and pinned above the legacy collections.
        let inbox = try library.inboxCollection()
        #expect(inbox.name == "Inbox")
        #expect(inbox.isInbox)
        #expect(inbox.parentID == nil)
        #expect(inbox.itemCount == 0)

        let tree = try library.collectionTree()
        #expect(tree.first?.isInbox == true)
        #expect(tree.map(\.name) == ["Inbox", "Moodboard", "References"])

        // Legacy rows kept their data and became root nodes with a deterministic order.
        let legacy = tree.dropFirst()
        #expect(legacy.allSatisfy { $0.parentID == nil })
        #expect(legacy.map(\.sortOrder) == [0, 1])

        // User-facing listing still excludes the system Inbox.
        #expect(try library.collections().map(\.name) == ["Moodboard", "References"])
    }

    @Test("items and memberships survive the migration")
    func itemsSurviveMigration() throws {
        let workspace = try TemporaryWorkspace(label: "v1-items")
        let paths = workspace.libraryPaths
        try paths.createDirectories()

        let collectionID = UUID()
        let itemID = UUID()
        do {
            let database = try SQLiteDatabase(path: paths.databaseURL.path)
            try database.execute(AtlasSchema.v1)
            try database.run("INSERT INTO library_meta (key, value) VALUES ('library_id', 'legacy');")
            try database.run(
                "INSERT INTO collections (id, name, created_at, updated_at) VALUES (?, 'Legacy', 0, 0);",
                [.text(collectionID.uuidString)]
            )
            try database.run("""
            INSERT INTO items (id, kind, mode, file_name, source_path, byte_size, content_hash, imported_at)
            VALUES (?, 'image', 'connected', 'a.png', '/tmp/a.png', 10, 'hash', 0);
            """, [.text(itemID.uuidString)])
            try database.run(
                "INSERT INTO collection_items (collection_id, item_id, added_at) VALUES (?, ?, 0);",
                [.text(collectionID.uuidString), .text(itemID.uuidString)]
            )
            database.userVersion = 1
            database.close()
        }

        let library = try AtlasLibrary(paths: paths)
        defer { library.close() }

        #expect(try library.itemCount() == 1)
        #expect(try library.items(collectionID: collectionID).map(\.id) == [itemID])
        // Legacy items are NOT retro-filed into the Inbox; only new imports are.
        #expect(try library.inboxCollection().itemCount == 0)
        #expect(try library.items().count == 1)
    }

    @Test("an existing root collection named Inbox is adopted, not duplicated")
    func existingInboxNameIsAdopted() throws {
        let workspace = try TemporaryWorkspace(label: "v1-inbox-name")
        let paths = try makeV1Library(in: workspace, collectionNames: ["Inbox", "Other"])

        let library = try AtlasLibrary(paths: paths)
        defer { library.close() }

        let inbox = try library.inboxCollection()
        let tree = try library.collectionTree()
        #expect(tree.filter(\.isInbox).count == 1)
        #expect(tree.count == 2)
        #expect(try library.collections().map(\.name) == ["Other"])
        #expect(try library.collection(id: inbox.id)?.isInbox == true)
    }

    @Test("migration is idempotent — reopening does not reseed or renumber")
    func migrationIsIdempotent() throws {
        let workspace = try TemporaryWorkspace(label: "v2-idempotent")
        let fixtures = try workspace.makeFixtures(count: 2)

        let first = try workspace.makeLibrary()
        try first.createCollection(name: "Alpha")
        try first.createCollection(name: "Beta")
        _ = try first.importFolder(fixtures, mode: .connected)
        let beforeTree = try first.collectionTree()
        let beforeInbox = try first.inboxCollection().id
        first.close()

        let second = try workspace.makeLibrary()
        defer { second.close() }
        #expect(try second.collectionTree().map(\.name) == beforeTree.map(\.name))
        #expect(try second.inboxCollection().id == beforeInbox)
        #expect(try second.itemCount() == 2)

        let database = try SQLiteDatabase(path: second.paths.databaseURL.path)
        defer { database.close() }
        #expect(Int(database.userVersion) == Int(AtlasSchema.currentVersion))
    }

    @Test("info reports v2 with the Inbox counted separately from user collections")
    func infoReportsV2() throws {
        let workspace = try TemporaryWorkspace(label: "v2-info")
        let fixtures = try workspace.makeFixtures(count: 3)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let info = try library.info()

        #expect(info.schemaVersion == Int(AtlasSchema.currentVersion))
        #expect(info.collectionCount == 1)   // "fixtures" only — Inbox is system
        #expect(info.inboxItemCount == 3)    // everything lands in Inbox on import
        #expect(info.tagCount == 0)
        #expect(info.originalsFileCount == 0)
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

    private func columnNames(_ database: SQLiteDatabase, table: String) throws -> Set<String> {
        let statement = try database.prepare("PRAGMA table_info(\(table));")
        var names: Set<String> = []
        while try statement.step() {
            if let name = statement.text(1) { names.insert(name) }
        }
        return names
    }
}
