import Foundation

/// An open AtlasOSS library.
///
/// P0 keeps this deliberately small: one SQLite connection, synchronous API, no
/// thumbnail generation. The public surface is the contract the future app target uses.
public final class AtlasLibrary {
    public let paths: LibraryPaths
    /// Module-internal so the collections/tags/Inbox extensions can share the connection.
    let database: SQLiteDatabase
    /// Shared with the `AtlasLibrary+Capture` extension, which expands dropped directory
    /// URLs and writes temp files for pasted bitmaps. Module-internal, not `private`.
    let fileManager: FileManager

    // MARK: - Lifecycle

    public init(paths: LibraryPaths, fileManager: FileManager = .default) throws {
        self.paths = paths
        self.fileManager = fileManager
        try paths.createDirectories(fileManager: fileManager)
        do {
            self.database = try SQLiteDatabase(path: paths.databaseURL.path)
        } catch {
            throw AtlasError.libraryCreationFailed("\(paths.databaseURL.path): \(error)")
        }
        try AtlasSchema.migrate(database)
    }

    public convenience init(url: URL, fileManager: FileManager = .default) throws {
        try self.init(paths: LibraryPaths(root: url), fileManager: fileManager)
    }

    public convenience init(path: String, fileManager: FileManager = .default) throws {
        try self.init(paths: LibraryPaths(path: path), fileManager: fileManager)
    }

    /// Opens (creating if needed) the default library at
    /// `~/Library/Application Support/AtlasOSS/default.atlaslibrary`.
    public static func openDefault() throws -> AtlasLibrary {
        try AtlasLibrary(paths: LibraryPaths(root: LibraryPaths.defaultRoot))
    }

    public func close() {
        database.close()
    }

    public var databasePath: String { paths.databaseURL.path }

    // MARK: - Import

    /// Imports a folder.
    ///
    /// - `.connected`: indexes files where they live. `originals/` is never written to
    ///   and `ImportReport.copiedOriginals` is always `0`.
    /// - `.copy`: copies files into `originals/` keyed by SHA-256, so identical content
    ///   is stored exactly once regardless of file name.
    @discardableResult
    public func importFolder(
        path: String,
        mode: ImportMode,
        collectionName: String? = nil
    ) throws -> ImportReport {
        try importFolder(
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            mode: mode,
            collectionName: collectionName
        )
    }

    @discardableResult
    public func importFolder(
        _ folderURL: URL,
        mode: ImportMode,
        collectionName: String? = nil
    ) throws -> ImportReport {
        let started = Date()
        // Canonicalise so repeated imports through different path spellings stay idempotent.
        let folder = PathUtilities.canonicalURL(folderURL.standardizedFileURL)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            throw AtlasError.pathNotFound(folder.path)
        }
        guard isDirectory.boolValue else {
            throw AtlasError.notADirectory(folder.path)
        }

        let collectionLabel = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCollection = (collectionLabel?.isEmpty == false ? collectionLabel! : folder.lastPathComponent)
        var report = ImportReport(folder: folder.path, mode: mode, collectionName: resolvedCollection)

        let files = try enumerateImportableFiles(in: folder)
        report.scanned = files.count

        try database.transaction {
            let collectionID = try upsertCollection(named: resolvedCollection)
            // Capture semantics: every import also lands in Inbox. Filing an item into a
            // real collection later (see `assignItems(_:toCollection:)`) clears it from
            // Inbox. See `AtlasLibrary+Inbox.swift` for the full rule.
            let inboxID = try ensureInboxCollectionID()

            for file in files {
                let ext = file.pathExtension.lowercased()
                let kind = MediaKind.detect(fromExtension: ext)

                guard kind == .image || kind == .video else {
                    report.skipped += 1
                    continue
                }

                do {
                    try importSingleFile(
                        file,
                        kind: kind,
                        mode: mode,
                        collectionID: collectionID,
                        inboxID: inboxID,
                        report: &report
                    )
                } catch {
                    report.skipped += 1
                    report.errors.append("\(file.lastPathComponent): \(error)")
                }
            }

            try touchCollection(collectionID)
        }

        report.durationSeconds = Date().timeIntervalSince(started)
        return report
    }

    /// One file, one row. Shared with `importURLs(_:mode:target:)` so a drop and a folder
    /// import can never disagree about duplicate detection or originals accounting.
    func importSingleFile(
        _ file: URL,
        kind: MediaKind,
        mode: ImportMode,
        collectionID: UUID,
        inboxID: UUID,
        report: inout ImportReport
    ) throws {
        let attributes = MediaProbe.fileAttributes(of: file)
        let hashed = try ContentHasher.sha256Hex(of: file)
        report.bytesHashed += hashed.byteCount
        let dimensions = MediaProbe.pixelSize(of: file)
        let now = Date()

        switch mode {
        case .connected:
            // Index in place. No filesystem writes of any kind.
            let absolutePath = file.path
            if let existingID = try findItemID(mode: .connected, sourcePath: absolutePath) {
                try updateItem(
                    id: existingID,
                    fileName: file.lastPathComponent,
                    sourcePath: absolutePath,
                    storedName: nil,
                    width: dimensions?.width,
                    height: dimensions?.height,
                    attributes: attributes,
                    contentHash: hashed.hexDigest,
                    importedAt: now
                )
                report.updated += 1
                try linkItem(existingID, to: collectionID, alsoLinkingTo: inboxID)
            } else {
                let id = UUID()
                try insertItem(
                    id: id,
                    kind: kind,
                    mode: .connected,
                    fileName: file.lastPathComponent,
                    sourcePath: absolutePath,
                    storedName: nil,
                    width: dimensions?.width,
                    height: dimensions?.height,
                    attributes: attributes,
                    contentHash: hashed.hexDigest,
                    importedAt: now
                )
                report.imported += 1
                try linkItem(id, to: collectionID, alsoLinkingTo: inboxID)
            }

        case .copy:
            // Identity is the content hash -> identical bytes are stored exactly once.
            let fileExtension = file.pathExtension.isEmpty ? "bin" : file.pathExtension.lowercased()
            let contentAddressedName = "\(hashed.hexDigest).\(fileExtension)"

            if let existingID = try findItemID(mode: .copy, kind: kind, contentHash: hashed.hexDigest) {
                let existingStoredName = try storedName(forItemID: existingID) ?? contentAddressedName
                let destination = paths.url(forStoredName: existingStoredName)
                if !fileManager.fileExists(atPath: destination.path) {
                    // Stored original was removed out-of-band; restore it.
                    try copyOriginal(from: file, to: destination)
                    report.copiedOriginals += 1
                }
                try updateItem(
                    id: existingID,
                    fileName: file.lastPathComponent,
                    sourcePath: nil,
                    storedName: existingStoredName,
                    width: dimensions?.width,
                    height: dimensions?.height,
                    attributes: attributes,
                    contentHash: hashed.hexDigest,
                    importedAt: now
                )
                report.duplicates += 1
                try linkItem(existingID, to: collectionID, alsoLinkingTo: inboxID)
            } else {
                let destination = paths.url(forStoredName: contentAddressedName)
                if !fileManager.fileExists(atPath: destination.path) {
                    try copyOriginal(from: file, to: destination)
                    report.copiedOriginals += 1
                }
                let id = UUID()
                try insertItem(
                    id: id,
                    kind: kind,
                    mode: .copy,
                    fileName: file.lastPathComponent,
                    sourcePath: nil,
                    storedName: contentAddressedName,
                    width: dimensions?.width,
                    height: dimensions?.height,
                    attributes: attributes,
                    contentHash: hashed.hexDigest,
                    importedAt: now
                )
                report.imported += 1
                try linkItem(id, to: collectionID, alsoLinkingTo: inboxID)
            }
        }
    }

    private func copyOriginal(from source: URL, to destination: URL) throws {
        do {
            try fileManager.createDirectory(
                at: paths.originalsURL,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw AtlasError.io("copy \(source.lastPathComponent) -> originals/: \(error)")
        }
    }

    /// Recursively collects regular files, deterministically ordered.
    func enumerateImportableFiles(in folder: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AtlasError.unsupported("cannot enumerate \(folder.path)")
        }

        var files: [URL] = []
        for case let candidate as URL in enumerator {
            let isRegular = (try? candidate.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            if isRegular == true {
                files.append(candidate)
            }
        }
        files.sort { $0.path < $1.path }
        return files
    }

    // MARK: - Queries

    public func items(
        limit: Int? = nil,
        mode: ImportMode? = nil,
        collectionName: String? = nil,
        collectionID: UUID? = nil,
        tagID: UUID? = nil,
        itemIDs: Set<UUID>? = nil
    ) throws -> [LibraryItem] {
        // An empty id set can never match: short-circuit instead of emitting `IN ()`.
        if let itemIDs, itemIDs.isEmpty { return [] }

        var sql = """
        SELECT id, kind, mode, file_name, source_path, stored_name, width, height,
               byte_size, content_hash, imported_at, file_created_at, file_modified_at
        FROM items
        """
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []

        if let mode {
            conditions.append("mode = ?")
            bindings.append(.text(mode.rawValue))
        }
        if let collectionName {
            conditions.append("""
            EXISTS (SELECT 1 FROM collection_items ci
                    JOIN collections c ON c.id = ci.collection_id
                    WHERE ci.item_id = items.id AND c.name = ?)
            """)
            bindings.append(.text(collectionName))
        }
        if let collectionID {
            // Direct membership only: a nested child collection does not inherit its
            // parent's items. Use `collectionTree()` + `totalItemCount` for rollups.
            conditions.append("""
            EXISTS (SELECT 1 FROM collection_items ci
                    WHERE ci.item_id = items.id AND ci.collection_id = ?)
            """)
            bindings.append(.text(collectionID.uuidString))
        }
        if let tagID {
            conditions.append("""
            EXISTS (SELECT 1 FROM item_tags it
                    WHERE it.item_id = items.id AND it.tag_id = ?)
            """)
            bindings.append(.text(tagID.uuidString))
        }
        if let itemIDs {
            // Used by the P1-C colour filter: the distance scan happens in Swift, then the
            // surviving ids come back here so ordering/limits stay in one place.
            let ids = Array(itemIDs)
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            conditions.append("id IN (\(placeholders))")
            bindings.append(contentsOf: ids.map { SQLiteValue.text($0.uuidString) })
        }

        if !conditions.isEmpty {
            sql += "\nWHERE " + conditions.joined(separator: "\n  AND ")
        }
        sql += "\nORDER BY imported_at DESC, file_name ASC"
        if let limit {
            sql += "\nLIMIT \(max(0, limit))"
        }

        let statement = try database.prepare(sql)
        try statement.bind(bindings)

        var results: [LibraryItem] = []
        while try statement.step() {
            guard let idString = statement.text(0), let id = UUID(uuidString: idString) else { continue }
            let kind = MediaKind(rawValue: statement.text(1) ?? "") ?? .other
            let mode = ImportMode(rawValue: statement.text(2) ?? "") ?? .connected
            results.append(
                LibraryItem(
                    id: id,
                    kind: kind,
                    mode: mode,
                    fileName: statement.text(3) ?? "",
                    sourcePath: statement.text(4),
                    storedName: statement.text(5),
                    width: statement.int(6).map { Int($0) },
                    height: statement.int(7).map { Int($0) },
                    byteSize: statement.int(8) ?? 0,
                    contentHash: statement.text(9) ?? "",
                    importedAt: statement.date(10) ?? Date(timeIntervalSince1970: 0),
                    fileCreatedAt: statement.date(11),
                    fileModifiedAt: statement.date(12)
                )
            )
        }
        return results
    }

    public func itemCount(mode: ImportMode? = nil) throws -> Int {
        if let mode {
            return Int(try database.scalarInt("SELECT COUNT(*) FROM items WHERE mode = ?;", [.text(mode.rawValue)]) ?? 0)
        }
        return Int(try database.scalarInt("SELECT COUNT(*) FROM items;") ?? 0)
    }

    /// Flat, user-facing collection list.
    ///
    /// - Parameter includingSystem: when `true`, the system Inbox is included. Defaults to
    ///   `false` so `collections()` means "collections the user made" — which is what the
    ///   P0 `collectionCount` assertions and the CLI listing expect.
    public func collections(includingSystem: Bool = false) throws -> [LibraryCollection] {
        let inboxID = try? inboxCollectionID()
        let statement = try database.prepare("""
        SELECT c.id, c.name, c.created_at, c.updated_at,
               (SELECT COUNT(*) FROM collection_items ci WHERE ci.collection_id = c.id),
               c.parent_id, c.sort_order
        FROM collections c
        ORDER BY c.sort_order ASC, c.name ASC
        """)
        var results: [LibraryCollection] = []
        while try statement.step() {
            guard let idString = statement.text(0), let id = UUID(uuidString: idString) else { continue }
            let isInbox = (id == inboxID)
            if isInbox && !includingSystem { continue }
            results.append(
                LibraryCollection(
                    id: id,
                    name: statement.text(1) ?? "",
                    createdAt: statement.date(2) ?? Date(timeIntervalSince1970: 0),
                    updatedAt: statement.date(3) ?? Date(timeIntervalSince1970: 0),
                    itemCount: Int(statement.int(4) ?? 0),
                    parentID: statement.text(5).flatMap(UUID.init(uuidString:)),
                    sortOrder: statement.double(6) ?? 0,
                    isInbox: isInbox
                )
            )
        }
        return results
    }

    public func info() throws -> LibraryInfo {
        var breakdown: [String: Int] = [:]
        let breakdownStatement = try database.prepare("SELECT kind, COUNT(*) FROM items GROUP BY kind;")
        while try breakdownStatement.step() {
            breakdown[breakdownStatement.text(0) ?? "other"] = Int(breakdownStatement.int(1) ?? 0)
        }

        return LibraryInfo(
            rootPath: paths.root.path,
            databasePath: paths.databaseURL.path,
            libraryID: try database.scalarText("SELECT value FROM library_meta WHERE key = 'library_id';") ?? "",
            schemaVersion: Int(database.userVersion),
            itemCount: try itemCount(),
            // System collections are infrastructure, not user content: the Inbox is
            // reported separately as `inboxItemCount`.
            collectionCount: Int(try database.scalarInt("SELECT COUNT(*) FROM collections WHERE id <> ?;", [.text((try? inboxCollectionID())?.uuidString ?? "")]) ?? 0),
            connectedCount: try itemCount(mode: .connected),
            copiedCount: try itemCount(mode: .copy),
            totalBytes: try database.scalarInt("SELECT COALESCE(SUM(byte_size), 0) FROM items;") ?? 0,
            originalsFileCount: DirectoryStats.fileCount(in: paths.originalsURL, fileManager: fileManager),
            thumbnailsFileCount: DirectoryStats.fileCount(in: paths.thumbnailsURL, fileManager: fileManager),
            databaseByteSize: DirectoryStats.fileSize(at: paths.databaseURL, fileManager: fileManager),
            kindBreakdown: breakdown,
            tagCount: Int(try database.scalarInt("SELECT COUNT(*) FROM tags;") ?? 0),
            inboxItemCount: Int(try database.scalarInt(
                "SELECT COUNT(*) FROM collection_items WHERE collection_id = ?;",
                [.text((try? inboxCollectionID())?.uuidString ?? "")]
            ) ?? 0)
        )
    }

    // MARK: - Item persistence

    private func findItemID(mode: ImportMode, sourcePath: String) throws -> UUID? {
        let statement = try database.prepare(
            "SELECT id FROM items WHERE mode = 'connected' AND source_path = ? LIMIT 1;"
        )
        try statement.bind([.text(sourcePath)])
        guard try statement.step(), let idString = statement.text(0) else { return nil }
        return UUID(uuidString: idString)
    }

    private func findItemID(mode: ImportMode, kind: MediaKind, contentHash: String) throws -> UUID? {
        let statement = try database.prepare(
            "SELECT id FROM items WHERE mode = 'copy' AND kind = ? AND content_hash = ? LIMIT 1;"
        )
        try statement.bind([.text(kind.rawValue), .text(contentHash)])
        guard try statement.step(), let idString = statement.text(0) else { return nil }
        return UUID(uuidString: idString)
    }

    private func storedName(forItemID id: UUID) throws -> String? {
        let statement = try database.prepare("SELECT stored_name FROM items WHERE id = ? LIMIT 1;")
        try statement.bind([.text(id.uuidString)])
        guard try statement.step() else { return nil }
        return statement.text(0)
    }

    private func insertItem(
        id: UUID,
        kind: MediaKind,
        mode: ImportMode,
        fileName: String,
        sourcePath: String?,
        storedName: String?,
        width: Int?,
        height: Int?,
        attributes: MediaProbe.FileAttributes,
        contentHash: String,
        importedAt: Date
    ) throws {
        try database.run("""
        INSERT INTO items (id, kind, mode, file_name, source_path, stored_name, width, height,
                           byte_size, content_hash, imported_at, file_created_at, file_modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .text(id.uuidString),
            .text(kind.rawValue),
            .text(mode.rawValue),
            .text(fileName),
            .maybe(sourcePath),
            .maybe(storedName),
            .maybe(width),
            .maybe(height),
            .integer(attributes.byteSize),
            .text(contentHash),
            .real(importedAt.timeIntervalSince1970),
            .maybe(attributes.createdAt),
            .maybe(attributes.modifiedAt),
        ])
    }

    private func updateItem(
        id: UUID,
        fileName: String,
        sourcePath: String?,
        storedName: String?,
        width: Int?,
        height: Int?,
        attributes: MediaProbe.FileAttributes,
        contentHash: String,
        importedAt: Date
    ) throws {
        try database.run("""
        UPDATE items
        SET file_name = ?, source_path = ?, stored_name = ?, width = ?, height = ?,
            byte_size = ?, content_hash = ?, imported_at = ?, file_created_at = ?, file_modified_at = ?
        WHERE id = ?;
        """, [
            .text(fileName),
            .maybe(sourcePath),
            .maybe(storedName),
            .maybe(width),
            .maybe(height),
            .integer(attributes.byteSize),
            .text(contentHash),
            .real(importedAt.timeIntervalSince1970),
            .maybe(attributes.createdAt),
            .maybe(attributes.modifiedAt),
            .text(id.uuidString),
        ])
    }

    // MARK: - Collections

    /// Imports resolve a collection by name **at the root level**. Nested collections are
    /// created explicitly through `createCollection(name:parentID:)`.
    @discardableResult
    private func upsertCollection(named name: String) throws -> UUID {
        if let existing = try database.scalarText(
            "SELECT id FROM collections WHERE name = ? AND parent_id IS NULL LIMIT 1;",
            [.text(name)]
        ), let id = UUID(uuidString: existing) {
            return id
        }
        let id = UUID()
        let now = Date().timeIntervalSince1970
        let nextSortOrder = try nextSortOrder(inParent: nil)
        try database.run(
            "INSERT INTO collections (id, name, created_at, updated_at, parent_id, sort_order) VALUES (?, ?, ?, ?, NULL, ?);",
            [.text(id.uuidString), .text(name), .real(now), .real(now), .real(nextSortOrder)]
        )
        return id
    }

    func touchCollection(_ collectionID: UUID) throws {
        try database.run(
            "UPDATE collections SET updated_at = ? WHERE id = ?;",
            [.real(Date().timeIntervalSince1970), .text(collectionID.uuidString)]
        )
    }

    private func linkItem(_ itemID: UUID, to collectionID: UUID, alsoLinkingTo inboxID: UUID? = nil) throws {
        let now = Date().timeIntervalSince1970
        try database.run(
            "INSERT OR IGNORE INTO collection_items (collection_id, item_id, added_at) VALUES (?, ?, ?);",
            [.text(collectionID.uuidString), .text(itemID.uuidString), .real(now)]
        )
        if let inboxID, inboxID != collectionID {
            try database.run(
                "INSERT OR IGNORE INTO collection_items (collection_id, item_id, added_at) VALUES (?, ?, ?);",
                [.text(inboxID.uuidString), .text(itemID.uuidString), .real(now)]
            )
        }
    }

    /// Next `sort_order` that appends below every sibling of `parent`. Exposed internally
    /// so the collections extension and the import path agree on spacing.
    ///
    /// The Inbox is excluded so it keeps its pinned `-1000` slot and user collections
    /// number from `0` instead of inheriting negative values from the system row.
    func nextSortOrder(inParent parentID: UUID?) throws -> Double {
        let sql = parentID == nil
            ? """
              SELECT COALESCE(MAX(sort_order), -1) FROM collections
              WHERE parent_id IS NULL
                AND id NOT IN (SELECT value FROM library_meta WHERE key = '\(AtlasSchema.inboxMetaKey)');
              """
            : "SELECT COALESCE(MAX(sort_order), -1) FROM collections WHERE parent_id = ?;"
        let bindings: [SQLiteValue] = parentID.map { [.text($0.uuidString)] } ?? []
        let current = try database.scalarInt(sql, bindings) ?? 0
        return Double(current) + 1
    }
}
