import Foundation

// MARK: - Inbox

extension AtlasLibrary {

    /// Id of the system Inbox collection.
    ///
    /// `library_meta.inbox_collection_id` is the source of truth. If the key is missing
    /// (hand-edited database, v1 library opened before migration ran) the reserved name is
    /// used as a fallback, and `ensureInboxCollectionID()` recreates the row on demand.
    public func inboxCollectionID() throws -> UUID? {
        if let raw = try database.scalarText(
            "SELECT value FROM library_meta WHERE key = ?;",
            [.text(AtlasSchema.inboxMetaKey)]
        ), let id = UUID(uuidString: raw) {
            return id
        }
        if let raw = try database.scalarText(
            "SELECT id FROM collections WHERE name = ? AND parent_id IS NULL LIMIT 1;",
            [.text(AtlasSchema.inboxCollectionName)]
        ), let id = UUID(uuidString: raw) {
            return id
        }
        return nil
    }

    /// Returns the Inbox id, creating and recording the collection if it has gone missing.
    @discardableResult
    func ensureInboxCollectionID() throws -> UUID {
        if let id = try inboxCollectionID() { return id }

        let id = UUID()
        let now = Date().timeIntervalSince1970
        try database.run("""
        INSERT INTO collections (id, name, created_at, updated_at, parent_id, sort_order)
        VALUES (?, ?, ?, ?, NULL, ?);
        """, [
            .text(id.uuidString),
            .text(AtlasSchema.inboxCollectionName),
            .real(now),
            .real(now),
            .real(AtlasSchema.inboxSortOrder),
        ])
        try database.run(
            "INSERT OR REPLACE INTO library_meta (key, value) VALUES (?, ?);",
            [.text(AtlasSchema.inboxMetaKey), .text(id.uuidString)]
        )
        return id
    }

    /// Items currently sitting in the Inbox — the sidebar badge.
    public func inboxItemCount() throws -> Int {
        guard let id = try inboxCollectionID() else { return 0 }
        return try itemCount(inCollection: id)
    }

    /// The Inbox collection node (never `nil` on a migrated library).
    public func inboxCollection() throws -> LibraryCollection {
        let id = try ensureInboxCollectionID()
        guard let collection = try collection(id: id) else {
            throw AtlasError.database("Inbox collection \(id.uuidString) is missing")
        }
        return collection
    }
}

// MARK: - Reading the tree

extension AtlasLibrary {

    /// Every collection, flat, ordered by `(sort_order, name)`.
    public func allCollections() throws -> [LibraryCollection] {
        try collections(includingSystem: true)
    }

    public func collection(id: UUID) throws -> LibraryCollection? {
        try collections(includingSystem: true).first { $0.id == id }
    }

    /// Hierarchical collections: root nodes with `children` populated to any depth.
    ///
    /// Roots come back Inbox-first, then by `sortOrder`; siblings inside a node are ordered
    /// by `sortOrder` and finally by name. `totalItemCount` is the post-order rollup of a
    /// collection plus every descendant.
    ///
    /// - Parameter includingSystem: pass `false` to drop the Inbox from the roots.
    public func collectionTree(includingSystem: Bool = true) throws -> [LibraryCollection] {
        let flat = try allCollections()
        var childrenByParent: [UUID: [LibraryCollection]] = [:]
        var roots: [LibraryCollection] = []

        for node in flat {
            if let parentID = node.parentID {
                childrenByParent[parentID, default: []].append(node)
            } else {
                roots.append(node)
            }
        }

        func build(_ node: LibraryCollection) -> LibraryCollection {
            let children = (childrenByParent[node.id] ?? []).map(build)
            var copy = node
            copy.children = children
            if !children.isEmpty {
                let total = node.itemCount + children.reduce(0) { $0 + $1.totalItemCount }
                copy = LibraryCollection(
                    id: node.id,
                    name: node.name,
                    createdAt: node.createdAt,
                    updatedAt: node.updatedAt,
                    itemCount: node.itemCount,
                    parentID: node.parentID,
                    sortOrder: node.sortOrder,
                    isInbox: node.isInbox,
                    totalItemCount: total,
                    children: children
                )
            }
            return copy
        }

        roots.sort { lhs, rhs in
            if lhs.isInbox != rhs.isInbox { return lhs.isInbox }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let tree = roots.map(build)
        return includingSystem ? tree : tree.filter { !$0.isInbox }
    }
}

// MARK: - Mutating collections

extension AtlasLibrary {

    /// Creates one collection. Names are unique **per parent**, case-insensitively;
    /// the Inbox is not a valid parent because it is a flat capture bucket.
    ///
    /// - Returns: the new collection's id.
    @discardableResult
    public func createCollection(name: String, parentID: UUID? = nil) throws -> UUID {
        let trimmed = try validatedName(name)

        if let parentID {
            guard let parent = try collection(id: parentID) else {
                throw AtlasError.unsupported("No collection with id \(parentID.uuidString)")
            }
            if parent.isInbox {
                throw AtlasError.unsupported("Inbox cannot contain collections")
            }
        }

        let uniqueName = try availableName(trimmed, inParent: parentID)
        let id = UUID()
        let now = Date().timeIntervalSince1970
        try database.run("""
        INSERT INTO collections (id, name, created_at, updated_at, parent_id, sort_order)
        VALUES (?, ?, ?, ?, ?, ?);
        """, [
            .text(id.uuidString),
            .text(uniqueName),
            .real(now),
            .real(now),
            .maybe(parentID?.uuidString),
            .real(try nextSortOrder(inParent: parentID)),
        ])
        return id
    }

    /// Renames a collection. Throws when another sibling already holds the name, and
    /// refuses to touch the Inbox.
    public func renameCollection(id: UUID, name: String) throws {
        guard let existing = try collection(id: id) else {
            throw AtlasError.unsupported("No collection with id \(id.uuidString)")
        }
        if existing.isInbox {
            throw AtlasError.unsupported("Inbox cannot be renamed")
        }

        let trimmed = try validatedName(name)
        if let clash = try sibling(named: trimmed, inParent: existing.parentID, excluding: id) {
            throw AtlasError.unsupported("A collection named \"\(clash.name)\" already exists here")
        }

        try database.run(
            "UPDATE collections SET name = ?, updated_at = ? WHERE id = ?;",
            [.text(trimmed), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    /// Reparents and/or repositions one collection.
    ///
    /// - Parameters:
    ///   - id: collection to move.
    ///   - newParentID: destination parent, `nil` for root.
    ///   - newSortOrder: ordering among the new siblings. The Inbox keeps its pinned
    ///     `-1000` slot and user collections are renumbered around it.
    public func moveCollection(id: UUID, newParentID: UUID?, newSortOrder: Double) throws {
        guard let existing = try collection(id: id) else {
            throw AtlasError.unsupported("No collection with id \(id.uuidString)")
        }
        if existing.isInbox {
            throw AtlasError.unsupported("Inbox cannot be moved")
        }
        try validateDestination(parentID: newParentID, for: id)

        var name = existing.name
        if newParentID != existing.parentID {
            name = try availableName(existing.name, inParent: newParentID)
        }

        try database.run("""
        UPDATE collections SET parent_id = ?, sort_order = ?, name = ?, updated_at = ?
        WHERE id = ?;
        """, [
            .maybe(newParentID?.uuidString),
            .real(newSortOrder),
            .text(name),
            .real(Date().timeIntervalSince1970),
            .text(id.uuidString),
        ])
    }

    /// Drag-and-drop reorder: place `id` inside `parentID` immediately before `siblingID`
    /// (`nil` appends) and renumber the siblings `0…n-1`.
    public func reorderCollection(_ id: UUID, parentID: UUID?, before siblingID: UUID? = nil) throws {
        guard let existing = try collection(id: id) else {
            throw AtlasError.unsupported("No collection with id \(id.uuidString)")
        }
        if existing.isInbox {
            throw AtlasError.unsupported("Inbox is pinned and cannot be reordered")
        }
        try validateDestination(parentID: parentID, for: id)

        var name = existing.name
        if parentID != existing.parentID {
            name = try availableName(existing.name, inParent: parentID)
        }

        // Order the destination siblings, minus the node being moved, then splice back in.
        // The pinned Inbox is never renumbered.
        var siblings = try children(of: parentID).filter { $0.id != id && !$0.isInbox }
        if let siblingID, let index = siblings.firstIndex(where: { $0.id == siblingID }) {
            siblings.insert(existing, at: index)
        } else {
            siblings.append(existing)
        }

        let now = Date().timeIntervalSince1970
        for (index, sibling) in siblings.enumerated() {
            if sibling.id == id {
                try database.run("""
                UPDATE collections SET parent_id = ?, sort_order = ?, name = ?, updated_at = ?
                WHERE id = ?;
                """, [
                    .maybe(parentID?.uuidString),
                    .real(Double(index)),
                    .text(name),
                    .real(now),
                    .text(id.uuidString),
                ])
            } else {
                try database.run(
                    "UPDATE collections SET sort_order = ? WHERE id = ?;",
                    [.real(Double(index)), .text(sibling.id.uuidString)]
                )
            }
        }
    }

    /// Deletes a collection. The Inbox is protected; children are promoted to the root
    /// rather than cascaded away, and renamed when that would collide with a root sibling.
    public func deleteCollection(id: UUID) throws {
        guard let existing = try collection(id: id) else { return }
        if existing.isInbox {
            throw AtlasError.unsupported("Inbox cannot be deleted")
        }

        try database.transaction {
            for child in try children(of: id) {
                let promoted = try availableName(child.name, inParent: nil)
                try database.run("""
                UPDATE collections SET parent_id = NULL, sort_order = ?, name = ?, updated_at = ?
                WHERE id = ?;
                """, [
                    .real(try nextSortOrder(inParent: nil)),
                    .text(promoted),
                    .real(Date().timeIntervalSince1970),
                    .text(child.id.uuidString),
                ])
            }
            // `collection_items` rows disappear via ON DELETE CASCADE (foreign_keys = ON).
            try database.run("DELETE FROM collections WHERE id = ?;", [.text(id.uuidString)])
        }
    }

    /// Items linked directly to a collection.
    public func items(inCollection collectionID: UUID, limit: Int? = nil) throws -> [LibraryItem] {
        try items(limit: limit, collectionID: collectionID)
    }

    /// Direct membership count for a collection.
    public func itemCount(inCollection collectionID: UUID) throws -> Int {
        Int(try database.scalarInt(
            "SELECT COUNT(*) FROM collection_items WHERE collection_id = ?;",
            [.text(collectionID.uuidString)]
        ) ?? 0)
    }

    /// Collections each item is *directly* filed into (the Info panel's membership chips).
    ///
    /// One query pair instead of N: the membership rows are read in bulk, then joined
    /// against the flat collection list. Items with no membership map to an empty array.
    public func collections(forItemIDs itemIDs: [UUID]) throws -> [UUID: [LibraryCollection]] {
        guard !itemIDs.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: try allCollections().map { ($0.id, $0) })
        let wanted = Set(itemIDs)
        let ids = Array(wanted)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let statement = try database.prepare("""
        SELECT item_id, collection_id FROM collection_items
        WHERE item_id IN (\(placeholders));
        """)
        try statement.bind(ids.map { SQLiteValue.text($0.uuidString) })

        var result: [UUID: [LibraryCollection]] = Dictionary(
            uniqueKeysWithValues: itemIDs.map { ($0, []) }
        )
        while try statement.step() {
            guard let rawItem = statement.text(0), let itemID = UUID(uuidString: rawItem),
                  let rawCollection = statement.text(1), let collectionID = UUID(uuidString: rawCollection),
                  let collection = byID[collectionID] else { continue }
            result[itemID, default: []].append(collection)
        }
        // Sort after the scan: mutating the dictionary while walking `result.keys` would
        // be iterating a live view of storage we are writing to.
        return result.mapValues { memberships in
            memberships.sorted { lhs, rhs in
                // Inbox first, then manual order, then name.
                if lhs.isInbox != rhs.isInbox { return lhs.isInbox }
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Adds membership (many-to-many; items keep every collection they belong to).
    @discardableResult
    public func addItems(_ itemIDs: [UUID], toCollection collectionID: UUID) throws -> Int {
        let now = Date().timeIntervalSince1970
        var changed = 0
        try database.transaction {
            for itemID in itemIDs {
                try database.run(
                    "INSERT OR IGNORE INTO collection_items (collection_id, item_id, added_at) VALUES (?, ?, ?);",
                    [.text(collectionID.uuidString), .text(itemID.uuidString), .real(now)]
                )
                if database.changes > 0 { changed += 1 }
            }
            try touchCollection(collectionID)
            try touchCollections(itemIDs: itemIDs)
        }
        return changed
    }

    /// Removes membership. Items left with no non-Inbox home fall back into the Inbox so
    /// they never disappear from the sidebar.
    @discardableResult
    public func removeItems(_ itemIDs: [UUID], fromCollection collectionID: UUID) throws -> Int {
        var changed = 0
        try database.transaction {
            for itemID in itemIDs {
                try database.run(
                    "DELETE FROM collection_items WHERE collection_id = ? AND item_id = ?;",
                    [.text(collectionID.uuidString), .text(itemID.uuidString)]
                )
                if database.changes > 0 { changed += 1 }
                try restoreToInboxIfUnsorted(itemID)
            }
        }
        return changed
    }

    /// Drag-onto-collection semantics: **adds** membership and clears the item from the
    /// Inbox, because filing an item is what "sorted" means here.
    ///
    /// The Inbox itself is never unlinked from, and items already filed elsewhere stay in
    /// their other collections (drag adds, it never moves).
    @discardableResult
    public func assignItems(_ itemIDs: [UUID], toCollection collectionID: UUID) throws -> Int {
        let added = try addItems(itemIDs, toCollection: collectionID)
        guard let inboxID = try inboxCollectionID(), inboxID != collectionID else { return added }
        try database.transaction {
            for itemID in itemIDs {
                try database.run(
                    "DELETE FROM collection_items WHERE collection_id = ? AND item_id = ?;",
                    [.text(inboxID.uuidString), .text(itemID.uuidString)]
                )
            }
        }
        return added
    }

    // MARK: - Helpers

    /// Children of a parent (root when `nil`), ordered by `(sort_order, name)`.
    func children(of parentID: UUID?) throws -> [LibraryCollection] {
        let sql = parentID == nil
            ? "SELECT id FROM collections WHERE parent_id IS NULL ORDER BY sort_order ASC, name ASC;"
            : "SELECT id FROM collections WHERE parent_id = ? ORDER BY sort_order ASC, name ASC;"
        let bindings: [SQLiteValue] = parentID.map { [.text($0.uuidString)] } ?? []

        let statement = try database.prepare(sql)
        try statement.bind(bindings)
        var ids: [UUID] = []
        while try statement.step() {
            if let raw = statement.text(0), let id = UUID(uuidString: raw) { ids.append(id) }
        }
        let all = try allCollections()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// Set of a collection and every collection beneath it — used to reject cycles.
    func descendantIDs(of id: UUID) throws -> Set<UUID> {
        let all = try allCollections()
        var childrenByParent: [UUID: [UUID]] = [:]
        for node in all {
            if let parentID = node.parentID {
                childrenByParent[parentID, default: []].append(node.id)
            }
        }
        var result: Set<UUID> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for child in childrenByParent[next] ?? [] where result.insert(child).inserted {
                queue.append(child)
            }
        }
        return result
    }

    func sibling(named name: String, inParent parentID: UUID?, excluding excluded: UUID?) throws -> LibraryCollection? {
        try children(of: parentID).first {
            $0.id != excluded && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// `name` when free, otherwise `name 2`, `name 3`, … inside the given parent.
    func availableName(_ name: String, inParent parentID: UUID?) throws -> String {
        if try sibling(named: name, inParent: parentID, excluding: nil) == nil { return name }
        var suffix = 2
        while try sibling(named: "\(name) \(suffix)", inParent: parentID, excluding: nil) != nil {
            suffix += 1
        }
        return "\(name) \(suffix)"
    }

    private func validateDestination(parentID: UUID?, for id: UUID) throws {
        guard let parentID else { return }
        guard let parent = try collection(id: parentID) else {
            throw AtlasError.unsupported("No collection with id \(parentID.uuidString)")
        }
        if parent.isInbox {
            throw AtlasError.unsupported("Inbox cannot contain collections")
        }
        if try descendantIDs(of: id).contains(parentID) {
            throw AtlasError.unsupported("A collection cannot be nested inside itself")
        }
    }

    func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AtlasError.unsupported("Collection name cannot be empty")
        }
        return trimmed
    }

    private func touchCollections(itemIDs: [UUID]) throws {
        guard !itemIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ", ")
        try database.run("""
        UPDATE collections SET updated_at = ?
        WHERE id IN (SELECT DISTINCT collection_id FROM collection_items
                     WHERE item_id IN (\(placeholders)));
        """, [.real(Date().timeIntervalSince1970)] + itemIDs.map { .text($0.uuidString) })
    }
}

// MARK: - Inbox rule

/// The Inbox rule, stated once so the behaviour is checkable:
///
/// 1. **Import captures.** Every `importFolder` call links its items to the Inbox in
///    addition to the folder collection, so nothing enters the library unreachable. The
///    sidebar badge therefore equals *items not yet filed*.
/// 2. **Filing clears it.** `assignItems(_:toCollection:)` — what a drop onto a collection
///    row does — adds membership and unlinks the item from the Inbox. An item is "sorted"
///    once it belongs to at least one non-Inbox collection.
/// 3. **Removal restores it.** Removing an item from its last non-Inbox collection puts it
///    back in the Inbox, so the UI never loses it.
/// 4. **The Inbox itself is inert**: it cannot be renamed, nested under, reordered or
///    deleted, and `assignItems`/`addItems` targeting the Inbox only ever add.
extension AtlasLibrary {

    /// True when the item is currently in the Inbox.
    public func isInInbox(_ itemID: UUID) throws -> Bool {
        guard let inboxID = try inboxCollectionID() else { return false }
        return Int(try database.scalarInt(
            "SELECT COUNT(*) FROM collection_items WHERE collection_id = ? AND item_id = ?;",
            [.text(inboxID.uuidString), .text(itemID.uuidString)]
        ) ?? 0) > 0
    }

    /// Re-links the item to the Inbox when it no longer belongs to any user collection.
    func restoreToInboxIfUnsorted(_ itemID: UUID) throws {
        let inboxID = try ensureInboxCollectionID()
        if try isInInbox(itemID) { return }

        let homes = Int(try database.scalarInt(
            "SELECT COUNT(*) FROM collection_items WHERE item_id = ? AND collection_id <> ?;",
            [.text(itemID.uuidString), .text(inboxID.uuidString)]
        ) ?? 0)
        guard homes == 0 else { return }

        try database.run(
            "INSERT OR IGNORE INTO collection_items (collection_id, item_id, added_at) VALUES (?, ?, ?);",
            [.text(inboxID.uuidString), .text(itemID.uuidString), .real(Date().timeIntervalSince1970)]
        )
    }
}
