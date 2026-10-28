import Foundation
import Testing
@testable import AtlasCore

// MARK: - P0 gate: connected mode

@Suite("P0 · connected import")
struct ConnectedImportTests {

    @Test("connected import copies zero originals and indexes every fixture")
    func connectedCopiesZeroOriginals() throws {
        let workspace = try TemporaryWorkspace(label: "connected")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()

        let report = try library.importFolder(fixtures, mode: .connected)

        // The load-bearing P0 assertion.
        #expect(report.copiedOriginals == 0)
        #expect(report.mode == .connected)
        #expect(report.scanned == 4)
        #expect(report.imported == 4)
        #expect(report.updated == 0)

        // Belt and braces: nothing on disk under originals/.
        let originalsFileCount = DirectoryStats.fileCount(in: library.paths.originalsURL)
        #expect(originalsFileCount == 0)

        // Library lists at least the fixture count.
        let items = try library.items()
        #expect(items.count >= 4)
        #expect(items.count == 4)
        #expect(try library.itemCount() == 4)
        #expect(items.allSatisfy { $0.mode == .connected })
        #expect(items.allSatisfy { $0.sourcePath != nil })
        #expect(items.allSatisfy { $0.storedName == nil })
    }

    @Test("connected items point at their original in-place files")
    func connectedPointsAtOriginalFiles() throws {
        let workspace = try TemporaryWorkspace(label: "connected-paths")
        let fixtures = try workspace.makeFixtures(count: 3)
        let library = try workspace.makeLibrary()

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        #expect(items.count == 3)

        let fixtureDirectory = PathUtilities.canonicalPath(fixtures.path)
        for item in items {
            let path = try #require(item.sourcePath)
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(path.hasPrefix(fixtureDirectory))
            // Nothing was moved or renamed.
            #expect(item.fileName == (path as NSString).lastPathComponent)
        }

        let fixtureNames = Set(Fixtures.all.prefix(3).map(\.name))
        #expect(Set(items.map(\.fileName)) == fixtureNames)
    }

    @Test("the same file imported through two path spellings stays one item")
    func connectedIdentitySurvivesPathSpellings() throws {
        let workspace = try TemporaryWorkspace(label: "canonical")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()

        _ = try library.importFolder(fixtures, mode: .connected)

        // Same folder, reached through a non-canonical spelling (…/./fixtures/../fixtures).
        let indirect = workspace.url
            .appendingPathComponent("fixtures")
            .appendingPathComponent("..")
            .appendingPathComponent("fixtures")
        let report = try library.importFolder(indirect, mode: .connected)

        #expect(report.imported == 0)
        #expect(report.copiedOriginals == 0)
        #expect(try library.itemCount() == 2)
    }

    @Test("re-importing the same folder is idempotent and still copies nothing")
    func connectedReimportIsIdempotent() throws {
        let workspace = try TemporaryWorkspace(label: "connected-idem")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()

        _ = try library.importFolder(fixtures, mode: .connected)
        let second = try library.importFolder(fixtures, mode: .connected)

        #expect(second.imported == 0)
        #expect(second.updated == 4)
        #expect(second.copiedOriginals == 0)
        #expect(try library.itemCount() == 4)
        #expect(DirectoryStats.fileCount(in: library.paths.originalsURL) == 0)
    }

    @Test("connected import records pixel dimensions from image headers")
    func connectedRecordsDimensions() throws {
        let workspace = try TemporaryWorkspace(label: "dims")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()

        _ = try library.importFolder(fixtures, mode: .connected)

        let items = try library.items()
        let expected = Dictionary(uniqueKeysWithValues: Fixtures.all.map { ($0.name, "\($0.width)×\($0.height)") })
        for item in items {
            #expect(item.dimensionsDescription == expected[item.fileName])
            #expect(item.byteSize > 0)
            #expect(item.contentHash.count == 64) // SHA-256 hex
        }
    }

    @Test("unsupported files are skipped, not indexed")
    func unsupportedFilesAreSkipped() throws {
        let workspace = try TemporaryWorkspace(label: "skip")
        let fixtures = try workspace.makeFixtures(count: 2)
        try Data("not an image".utf8).write(to: fixtures.appendingPathComponent("notes.txt"))

        let library = try workspace.makeLibrary()
        let report = try library.importFolder(fixtures, mode: .connected)

        #expect(report.scanned == 3)
        #expect(report.imported == 2)
        #expect(report.skipped == 1)
        #expect(report.copiedOriginals == 0)
        #expect(try library.itemCount() == 2)
    }
}

// MARK: - Copy mode

@Suite("P0 · copy import")
struct CopyImportTests {

    @Test("copy mode stores one original per file and reports the copy count")
    func copyModeStoresOriginals() throws {
        let workspace = try TemporaryWorkspace(label: "copy")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()

        let report = try library.importFolder(fixtures, mode: .copy)

        #expect(report.copiedOriginals == 4)
        #expect(report.imported == 4)
        #expect(report.duplicates == 0)
        #expect(DirectoryStats.fileCount(in: library.paths.originalsURL) == 4)

        let items = try library.items()
        #expect(items.count == 4)
        #expect(items.allSatisfy { $0.mode == .copy })
        #expect(items.allSatisfy { $0.sourcePath == nil })
        #expect(items.allSatisfy { $0.storedName != nil })

        for item in items {
            let storedName = try #require(item.storedName)
            let storedURL = library.paths.url(forStoredName: storedName)
            #expect(FileManager.default.fileExists(atPath: storedURL.path))
            // Stored name is content-addressed: <sha256>.<ext>
            #expect(storedName == "\(item.contentHash).png")
        }
    }

    @Test("re-importing identical content copies nothing new (hash dedupe)")
    func copyModeReimportDedupes() throws {
        let workspace = try TemporaryWorkspace(label: "copy-dedupe")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()

        _ = try library.importFolder(fixtures, mode: .copy)
        let second = try library.importFolder(fixtures, mode: .copy)

        #expect(second.copiedOriginals == 0)
        #expect(second.imported == 0)
        #expect(second.duplicates == 4)
        #expect(try library.itemCount() == 4)
        #expect(DirectoryStats.fileCount(in: library.paths.originalsURL) == 4)
    }

    @Test("identical bytes under different names collapse to a single stored original")
    func copyModeDedupesAcrossFileNames() throws {
        let workspace = try TemporaryWorkspace(label: "copy-across-names")
        let fixtures = try workspace.makeFixtures(count: 1)
        let original = fixtures.appendingPathComponent(Fixtures.all[0].name)
        let renamed = fixtures.appendingPathComponent("renamed-copy.png")
        try FileManager.default.copyItem(at: original, to: renamed)

        let library = try workspace.makeLibrary()
        let report = try library.importFolder(fixtures, mode: .copy)

        #expect(report.scanned == 2)
        #expect(report.imported == 1)
        #expect(report.duplicates == 1)
        #expect(report.copiedOriginals == 1)
        #expect(try library.itemCount() == 1)
        #expect(DirectoryStats.fileCount(in: library.paths.originalsURL) == 1)
    }

    @Test("a deleted stored original is restored on the next import")
    func copyModeRestoresMissingOriginal() throws {
        let workspace = try TemporaryWorkspace(label: "copy-restore")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()

        _ = try library.importFolder(fixtures, mode: .copy)
        let items = try library.items()
        let storedName = try #require(items.first?.storedName)
        let storedURL = library.paths.url(forStoredName: storedName)
        try FileManager.default.removeItem(at: storedURL)
        #expect(DirectoryStats.fileCount(in: library.paths.originalsURL) == 1)

        let report = try library.importFolder(fixtures, mode: .copy)
        #expect(report.copiedOriginals == 1) // only the one that went missing
        #expect(DirectoryStats.fileCount(in: library.paths.originalsURL) == 2)
    }
}

// MARK: - Layout, schema and metadata

@Suite("P0 · library layout")
struct LibraryLayoutTests {

    @Test("library package has sqlite + originals/ + thumbnails/")
    func layoutIsCreated() throws {
        let workspace = try TemporaryWorkspace(label: "layout")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        #expect(fileManager.fileExists(atPath: library.paths.root.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(fileManager.fileExists(atPath: library.paths.databaseURL.path))
        #expect(fileManager.fileExists(atPath: library.paths.originalsURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(fileManager.fileExists(atPath: library.paths.thumbnailsURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(library.paths.root.pathExtension == "atlaslibrary")
        #expect(library.paths.root.lastPathComponent == "main.atlaslibrary")
    }

    @Test("info reports schema version, counts and zero originals for connected")
    func infoReflectsConnectedImport() throws {
        let workspace = try TemporaryWorkspace(label: "info")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()

        _ = try library.importFolder(fixtures, mode: .connected)
        let info = try library.info()

        #expect(info.schemaVersion == Int(AtlasSchema.currentVersion))
        #expect(info.itemCount == 4)
        #expect(info.connectedCount == 4)
        #expect(info.copiedCount == 0)
        #expect(info.originalsFileCount == 0)
        #expect(info.thumbnailsFileCount == 0)
        #expect(info.collectionCount == 1)
        #expect(info.totalBytes > 0)
        #expect(info.databaseByteSize > 0)
        #expect(info.libraryID.isEmpty == false)
        #expect(info.kindBreakdown["image"] == 4)
    }

    @Test("importing a folder creates a collection named after the folder")
    func importCreatesCollection() throws {
        let workspace = try TemporaryWorkspace(label: "collections")
        let fixtures = try workspace.makeFixtures(count: 3, named: "moodboard")
        let library = try workspace.makeLibrary()

        let report = try library.importFolder(fixtures, mode: .connected)
        #expect(report.collectionName == "moodboard")

        let collections = try library.collections()
        #expect(collections.count == 1)
        #expect(collections.first?.name == "moodboard")
        #expect(collections.first?.itemCount == 3)

        let filtered = try library.items(collectionName: "moodboard")
        #expect(filtered.count == 3)
    }

    @Test("an explicit --collection name overrides the folder name")
    func explicitCollectionName() throws {
        let workspace = try TemporaryWorkspace(label: "named-collection")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()

        _ = try library.importFolder(fixtures, mode: .connected, collectionName: "References")
        let collections = try library.collections()
        #expect(collections.map(\.name) == ["References"])
    }

    @Test("limit and mode filters narrow the item query")
    func itemQueryFilters() throws {
        let workspace = try TemporaryWorkspace(label: "filters")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()

        _ = try library.importFolder(fixtures, mode: .connected)
        #expect(try library.items(limit: 2).count == 2)
        #expect(try library.items(mode: .connected).count == 4)
        #expect(try library.items(mode: .copy).count == 0)
    }

    @Test("default library path lives under Application Support")
    func defaultPathConvention() {
        let root = LibraryPaths.defaultRoot
        #expect(root.lastPathComponent == "default.atlaslibrary")
        #expect(root.deletingLastPathComponent().lastPathComponent == "AtlasOSS")
        #expect(root.path.contains("Library/Application Support"))
    }
}

// MARK: - Error handling

@Suite("P0 · errors")
struct ImportErrorTests {

    @Test("importing a missing folder throws pathNotFound")
    func missingFolderThrows() throws {
        let workspace = try TemporaryWorkspace(label: "missing")
        let library = try workspace.makeLibrary()
        let missing = workspace.url.appendingPathComponent("does-not-exist").path

        #expect(throws: AtlasError.pathNotFound(missing)) {
            try library.importFolder(path: missing, mode: .connected)
        }
    }

    @Test("importing a file instead of a folder throws notADirectory")
    func fileInsteadOfFolderThrows() throws {
        let workspace = try TemporaryWorkspace(label: "not-a-dir")
        let library = try workspace.makeLibrary()
        let file = workspace.url.appendingPathComponent("single.png")
        try Fixtures.all[0].data.write(to: file)

        #expect(throws: AtlasError.notADirectory(PathUtilities.canonicalPath(file.path))) {
            try library.importFolder(path: file.path, mode: .connected)
        }
    }

    @Test("an empty folder imports zero items without error")
    func emptyFolderIsFine() throws {
        let workspace = try TemporaryWorkspace(label: "empty")
        let empty = workspace.url.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let library = try workspace.makeLibrary()

        let report = try library.importFolder(empty, mode: .connected)
        #expect(report.scanned == 0)
        #expect(report.imported == 0)
        #expect(report.copiedOriginals == 0)
        #expect(try library.itemCount() == 0)
    }
}

// MARK: - Schema surface

@Suite("P0 · schema")
struct SchemaTests {

    @Test("schema v1 creates the documented tables and indexes")
    func v1ObjectsExist() throws {
        let workspace = try TemporaryWorkspace(label: "schema")
        let library = try workspace.makeLibrary()
        let database = try SQLiteDatabase(path: library.paths.databaseURL.path)
        defer { database.close() }

        #expect(Int(database.userVersion) == Int(AtlasSchema.currentVersion))

        let tables = try objectNames(database, type: "table")
        #expect(tables.isSuperset(of: ["items", "collections", "collection_items", "library_meta"]))

        let indexes = try objectNames(database, type: "index")
        #expect(indexes.isSuperset(of: [
            "ux_items_connected_path",
            "ux_items_copy_hash",
            "ix_items_hash",
            "ux_collections_name",
        ]))

        // items carries the columns required by the P0 spec.
        let columns = try columnNames(database, table: "items")
        #expect(columns.isSuperset(of: [
            "id", "kind", "source_path", "stored_name", "width", "height",
            "content_hash", "imported_at",
        ]))
    }

    @Test("reopening an existing library preserves items")
    func reopeningPreservesItems() throws {
        let workspace = try TemporaryWorkspace(label: "reopen")
        let fixtures = try workspace.makeFixtures(count: 3)

        do {
            let library = try workspace.makeLibrary()
            _ = try library.importFolder(fixtures, mode: .connected)
            library.close()
        }

        let reopened = try workspace.makeLibrary()
        #expect(try reopened.itemCount() == 3)
        let info = try reopened.info()
        #expect(info.originalsFileCount == 0)
    }

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
