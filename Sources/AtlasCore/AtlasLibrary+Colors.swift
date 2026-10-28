import Foundation

/// Dominant-colour probing and the cached palette behind the Info panel (P1-C).
///
/// The cache is *derived* data: `dominantColors(for:)` extracts lazily on first use and
/// stores the result in `item_colors`, keyed by a cheap fingerprint (`item_palette`). If
/// the file changes underneath us — in-place edit, re-import, mtime bump — the fingerprint
/// stops matching and the palette is re-probed. Nothing user-authored lives in these
/// tables, so they can be dropped and rebuilt at any time.
extension AtlasLibrary {

    // MARK: - Item lookup

    /// One item by id, or `nil` when it no longer exists.
    public func item(id: UUID) throws -> LibraryItem? {
        try items(itemIDs: [id]).first
    }

    /// Absolute file backing an item: `originals/<storedName>` for copied items,
    /// `sourcePath` for connected ones.
    public func fileURL(for item: LibraryItem) -> URL? {
        if let storedName = item.storedName {
            return paths.url(forStoredName: storedName)
        }
        if let sourcePath = item.sourcePath {
            return URL(fileURLWithPath: sourcePath)
        }
        return nil
    }

    // MARK: - Extraction + cache

    /// Dominant colours of one item, extracted lazily and cached.
    ///
    /// - Parameters:
    ///   - itemID: the item to probe.
    ///   - refresh: ignore the cache and re-probe the file.
    /// - Returns: up to `ColorProbe.defaultMaxColors` swatches, most prominent first.
    ///   Videos, unreadable files and fully transparent images return `[]`.
    @discardableResult
    public func dominantColors(for itemID: UUID, refresh: Bool = false) throws -> [Swatch] {
        guard let item = try item(id: itemID) else {
            throw AtlasError.unsupported("No item with id \(itemID.uuidString)")
        }

        let signature = paletteSignature(for: item)
        if !refresh, try storedSignature(forItemID: itemID) == signature {
            return try cachedColors(forItemID: itemID)
        }

        let colors = extractPalette(for: item)
        try storePalette(colors, signature: signature, forItemID: itemID)
        return colors
    }

    /// Palette already in the cache, most prominent first. Empty when never probed.
    public func cachedColors(forItemID itemID: UUID) throws -> [Swatch] {
        try cachedColors(forItemIDs: [itemID])[itemID] ?? []
    }

    /// Palettes for many items in one query. Items without a cached palette are absent
    /// from the result (they were either never probed or are palette-less).
    public func cachedColors(forItemIDs itemIDs: [UUID]) throws -> [UUID: [Swatch]] {
        guard !itemIDs.isEmpty else { return [:] }
        let ids = itemIDs.map(\.uuidString)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let statement = try database.prepare("""
        SELECT item_id, hex, weight FROM item_colors
        WHERE item_id IN (\(placeholders))
        ORDER BY item_id ASC, rank ASC;
        """)
        try statement.bind(ids.map { SQLiteValue.text($0) })

        var result: [UUID: [Swatch]] = [:]
        while try statement.step() {
            guard let raw = statement.text(0), let itemID = UUID(uuidString: raw),
                  let hex = statement.text(1) else { continue }
            result[itemID, default: []].append(
                Swatch(hex: hex, weight: statement.double(2) ?? 0)
            )
        }
        return result
    }

    /// Cache fingerprint for an item's palette.
    ///
    /// Content hash (import identity) + live modification time + byte size. Using the
    /// *live* mtime rather than the imported one is what makes an in-place edit invalidate
    /// the cache without a re-import.
    public func paletteSignature(for item: LibraryItem) -> String {
        var modified = item.fileModifiedAt?.timeIntervalSince1970 ?? 0
        if let url = fileURL(for: item) {
            if let live = MediaProbe.fileAttributes(of: url).modifiedAt {
                modified = live.timeIntervalSince1970
            }
        }
        // Milliseconds: NTFS/HFS+ style 1s mtimes would miss quick successive edits.
        return "\(item.contentHash)|\(Int64((modified * 1000).rounded()))|\(item.byteSize)"
    }

    /// True when the cache holds a palette for this exact file version.
    public func hasCurrentPalette(for itemID: UUID) throws -> Bool {
        guard let item = try item(id: itemID) else { return false }
        return try storedSignature(forItemID: itemID) == paletteSignature(for: item)
    }

    // MARK: - Colour filter

    /// Items with at least one cached swatch within `tolerance` of `hex`.
    ///
    /// Distance is Euclidean in sRGB (see `ColorProbe.distance`) — `40` is the documented
    /// default: same colour family, visibly different shade allowed. `0` means exact.
    ///
    /// Only **cached** palettes participate, so the caller decides when to spend the
    /// extraction: the app warms the palettes of the visible grid, the CLI does it lazily.
    public func itemIDs(
        matchingColor hex: String,
        tolerance: Int = ColorProbe.defaultTolerance
    ) throws -> [UUID] {
        guard let target = ColorProbe.rgbComponents(fromHex: hex) else { return [] }
        let limit = Double(max(0, tolerance))

        let statement = try database.prepare("SELECT DISTINCT item_id, hex FROM item_colors;")
        var matched: [UUID] = []
        var seen = Set<UUID>()
        while try statement.step() {
            guard let raw = statement.text(0), let itemID = UUID(uuidString: raw),
                  !seen.contains(itemID),
                  let swatchHex = statement.text(1),
                  let rgb = ColorProbe.rgbComponents(fromHex: swatchHex) else { continue }
            if ColorProbe.distance(target, rgb) <= limit {
                seen.insert(itemID)
                matched.append(itemID)
            }
        }
        return matched
    }

    /// Convenience wrapper: the items themselves, in the library's standard order.
    public func items(
        matchingColor hex: String,
        tolerance: Int = ColorProbe.defaultTolerance,
        limit: Int? = nil
    ) throws -> [LibraryItem] {
        let ids = try itemIDs(matchingColor: hex, tolerance: tolerance)
        guard !ids.isEmpty else { return [] }
        return try items(limit: limit, itemIDs: Set(ids))
    }

    // MARK: - Internals

    /// Probes the file for an image item; everything else is palette-less by definition.
    private func extractPalette(for item: LibraryItem) -> [Swatch] {
        guard item.kind == .image, let url = fileURL(for: item) else { return [] }
        return ColorProbe.swatches(for: url)
    }

    private func storedSignature(forItemID itemID: UUID) throws -> String? {
        try database.scalarText(
            "SELECT signature FROM item_palette WHERE item_id = ?;",
            [.text(itemID.uuidString)]
        )
    }

    /// Replaces the cached palette in one transaction. An empty palette still records the
    /// fingerprint, so a video is not re-probed on every Info open.
    func storePalette(_ colors: [Swatch], signature: String, forItemID itemID: UUID) throws {
        let now = Date().timeIntervalSince1970
        try database.transaction {
            try database.run(
                "DELETE FROM item_colors WHERE item_id = ?;",
                [.text(itemID.uuidString)]
            )
            for (rank, swatch) in colors.enumerated() {
                try database.run("""
                INSERT OR REPLACE INTO item_colors (item_id, rank, hex, weight)
                VALUES (?, ?, ?, ?);
                """, [
                    .text(itemID.uuidString),
                    .integer(Int64(rank)),
                    .text(swatch.hex),
                    .real(swatch.weight),
                ])
            }
            try database.run("""
            INSERT OR REPLACE INTO item_palette (item_id, signature, extracted_at)
            VALUES (?, ?, ?);
            """, [.text(itemID.uuidString), .text(signature), .real(now)])
        }
    }
}
