import Foundation

/// Tags are a flat, many-to-many label space. Deliberately *not* smart folders: a tag
/// stores no query, only membership.
extension AtlasLibrary {

    // MARK: - Reading

    /// Every tag, ordered by name.
    public func tags() throws -> [LibraryTag] {
        let statement = try database.prepare("""
        SELECT t.id, t.name, t.created_at, t.color,
               (SELECT COUNT(*) FROM item_tags it WHERE it.tag_id = t.id)
        FROM tags t
        ORDER BY t.name COLLATE NOCASE ASC;
        """)
        var results: [LibraryTag] = []
        while try statement.step() {
            guard let raw = statement.text(0), let id = UUID(uuidString: raw) else { continue }
            results.append(
                LibraryTag(
                    id: id,
                    name: statement.text(1) ?? "",
                    createdAt: statement.date(2) ?? Date(timeIntervalSince1970: 0),
                    color: statement.text(3),
                    itemCount: Int(statement.int(4) ?? 0)
                )
            )
        }
        return results
    }

    public func tag(id: UUID) throws -> LibraryTag? {
        try tags().first { $0.id == id }
    }

    /// Tags on one item, ordered by name.
    public func tags(forItemID itemID: UUID) throws -> [LibraryTag] {
        let tagged = Set(try itemTagIDs(forItemID: itemID))
        return try tags().filter { tagged.contains($0.id) }
    }

    /// Tags for many items at once — one query pair instead of N. Each item's tags are
    /// ordered by name, matching `tags(forItemID:)`.
    public func tags(forItemIDs itemIDs: [UUID]) throws -> [UUID: [LibraryTag]] {
        guard !itemIDs.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: try tags().map { ($0.id, $0) })
        var result: [UUID: [LibraryTag]] = [:]
        for itemID in itemIDs {
            let ids = try itemTagIDs(forItemID: itemID)
            result[itemID] = ids
                .compactMap { byID[$0] }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return result
    }

    /// Items carrying a tag.
    public func items(tagID: UUID, limit: Int? = nil) throws -> [LibraryItem] {
        try items(limit: limit, tagID: tagID)
    }

    public func itemCount(tagID: UUID) throws -> Int {
        Int(try database.scalarInt(
            "SELECT COUNT(*) FROM item_tags WHERE tag_id = ?;",
            [.text(tagID.uuidString)]
        ) ?? 0)
    }

    // MARK: - Mutating

    /// Creates a tag.
    ///
    /// Idempotent on name (case-insensitive), mirroring `upsertCollection`: re-creating an
    /// existing tag returns its id so the "New Tag" field can be typed twice without
    /// producing duplicates.
    @discardableResult
    public func createTag(name: String, color: String? = nil) throws -> UUID {
        let trimmed = try validatedTagName(name)

        if let existing = try tags().first(where: {
            $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return existing.id
        }

        let id = UUID()
        try database.run(
            "INSERT INTO tags (id, name, created_at, color) VALUES (?, ?, ?, ?);",
            [.text(id.uuidString), .text(trimmed), .real(Date().timeIntervalSince1970), .maybe(color)]
        )
        return id
    }

    /// Renames a tag. `color` of `nil` leaves the existing colour untouched.
    public func renameTag(id: UUID, name: String, color: String? = nil) throws {
        guard try tag(id: id) != nil else {
            throw AtlasError.unsupported("No tag with id \(id.uuidString)")
        }
        let trimmed = try validatedTagName(name)
        let clash = try tags().first {
            $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if let clash {
            throw AtlasError.unsupported("A tag named \"\(clash.name)\" already exists")
        }

        try database.run(
            "UPDATE tags SET name = ?, color = COALESCE(?, color) WHERE id = ?;",
            [.text(trimmed), .maybe(color), .text(id.uuidString)]
        )
    }

    /// Deletes a tag and every membership row (`ON DELETE CASCADE`).
    public func deleteTag(id: UUID) throws {
        try database.run("DELETE FROM tags WHERE id = ?;", [.text(id.uuidString)])
    }

    /// Batch assign tags to items.
    ///
    /// - Parameters:
    ///   - itemIDs: items to touch.
    ///   - tagIDs: tags to add, remove or set.
    ///   - mode: `.add` unions, `.remove` subtracts, `.replace` makes each item carry
    ///     exactly `tagIDs`.
    /// - Returns: the number of membership rows actually written.
    @discardableResult
    public func setTags(
        itemIDs: [UUID],
        tagIDs: [UUID],
        mode: TagAssignmentMode = .add
    ) throws -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        var written = 0
        let now = Date().timeIntervalSince1970

        try database.transaction {
            for itemID in itemIDs {
                if mode == .replace {
                    try database.run(
                        "DELETE FROM item_tags WHERE item_id = ?;",
                        [.text(itemID.uuidString)]
                    )
                }
                for tagID in tagIDs {
                    switch mode {
                    case .add, .replace:
                        try database.run("""
                        INSERT OR IGNORE INTO item_tags (tag_id, item_id, added_at) VALUES (?, ?, ?);
                        """, [.text(tagID.uuidString), .text(itemID.uuidString), .real(now)])
                        if database.changes > 0 { written += 1 }
                    case .remove:
                        try database.run(
                            "DELETE FROM item_tags WHERE tag_id = ? AND item_id = ?;",
                            [.text(tagID.uuidString), .text(itemID.uuidString)]
                        )
                        if database.changes > 0 { written += 1 }
                    }
                }
            }
        }
        return written
    }

    // MARK: - Helpers

    private func itemTagIDs(forItemID itemID: UUID) throws -> [UUID] {
        let statement = try database.prepare(
            "SELECT tag_id FROM item_tags WHERE item_id = ?;"
        )
        try statement.bind([.text(itemID.uuidString)])
        var ids: [UUID] = []
        while try statement.step() {
            if let raw = statement.text(0), let id = UUID(uuidString: raw) { ids.append(id) }
        }
        return ids
    }

    private func validatedTagName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AtlasError.unsupported("Tag name cannot be empty")
        }
        return trimmed
    }
}
