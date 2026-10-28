import Foundation

/// Canvas board placement — the spatial side of the P2-A pillar (PureRef board, tldraw
/// culling, no Excalidraw full-scene cost).
///
/// One table, one row per `(scope, item)`. The board itself is stateless: the app owns the
/// camera, this type owns the truth about *where a tile is*. Everything here is scoped by
/// `collectionID` (`nil` == the whole library), which is the API shape the app and the CLI
/// both call.
extension AtlasLibrary {

    // MARK: - Read

    /// Every persisted placement for a board, ordered back-to-front.
    ///
    /// - Parameter collectionID: a collection, or `nil` for the All board.
    /// - Returns: placements in paint order (`z_order`, then item id for stability). Items
    ///   that have never been placed are simply absent — the caller auto-packs them.
    public func canvasPositions(collectionID: UUID? = nil) throws -> [CanvasItemPosition] {
        try canvasPositions(scope: CanvasScope(collectionID: collectionID))
    }

    public func canvasPositions(scope: CanvasScope) throws -> [CanvasItemPosition] {
        let statement = try database.prepare("""
        SELECT item_id, x, y, z_order, scale
        FROM item_positions
        WHERE scope = ?
        ORDER BY z_order ASC, item_id ASC;
        """)
        try statement.bind([.text(scope.storageKey)])

        var results: [CanvasItemPosition] = []
        while try statement.step() {
            guard let raw = statement.text(0), let itemID = UUID(uuidString: raw) else { continue }
            results.append(
                CanvasItemPosition(
                    itemID: itemID,
                    x: statement.double(1) ?? 0,
                    y: statement.double(2) ?? 0,
                    z: statement.double(3) ?? 0,
                    scale: statement.double(4) ?? 1
                )
            )
        }
        return results
    }

    /// How many tiles a board has an explicit placement for. Zero means "never opened on the
    /// Canvas", which is how the app decides to seed the packed layout.
    public func canvasPositionCount(collectionID: UUID? = nil) throws -> Int {
        Int(try database.scalarInt(
            "SELECT COUNT(*) FROM item_positions WHERE scope = ?;",
            [.text(CanvasScope(collectionID: collectionID).storageKey)]
        ) ?? 0)
    }

    // MARK: - Write

    /// Moves (or scales, or restacks) one tile. Upsert: the second call for the same item
    /// moves it rather than adding a row.
    public func setCanvasPosition(
        itemID: UUID,
        collectionID: UUID? = nil,
        x: Double,
        y: Double,
        z: Double = 0,
        scale: Double = 1
    ) throws {
        try setCanvasPositions(
            [CanvasPlacement(itemID: itemID, x: x, y: y, z: z, scale: scale)],
            collectionID: collectionID
        )
    }

    /// Batch upsert in **one** transaction — a multi-select drag is one write, not N.
    public func setCanvasPositions(
        _ placements: [CanvasPlacement],
        collectionID: UUID? = nil
    ) throws {
        guard !placements.isEmpty else { return }
        for placement in placements {
            try validate(placement)
        }

        let scope = CanvasScope(collectionID: collectionID).storageKey
        let now = Date().timeIntervalSince1970

        try database.transaction {
            let statement = try database.prepare("""
            INSERT OR REPLACE INTO item_positions
                (scope, item_id, x, y, z_order, scale, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            for placement in placements {
                statement.reset()
                try statement.bind([
                    .text(scope),
                    .text(placement.itemID.uuidString),
                    .real(placement.x),
                    .real(placement.y),
                    .real(placement.z),
                    .real(CanvasLayout.clampScale(placement.scale)),
                    .real(now),
                ])
                try statement.step()
            }
        }
    }

    /// Drops explicit placements, leaving the items themselves alone. Used when tiles leave
    /// the board (a collection loses an item) and by the app when it prunes ghost rows.
    @discardableResult
    public func removeCanvasPositions(
        itemIDs: [UUID],
        collectionID: UUID? = nil
    ) throws -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        let scope = CanvasScope(collectionID: collectionID).storageKey
        var removed = 0
        try database.transaction {
            for itemID in itemIDs {
                try database.run(
                    "DELETE FROM item_positions WHERE scope = ? AND item_id = ?;",
                    [.text(scope), .text(itemID.uuidString)]
                )
                removed += Int(database.changes)
            }
        }
        return removed
    }

    // MARK: - Reset

    /// **Reset layout**: repacks the board as a grid in the current sort order.
    ///
    /// "Current sort" is the same order the Grid shows (`imported_at DESC, file_name ASC`,
    /// see `items(...)`), so resetting a board reproduces the grid the user can see behind
    /// it. The block is centred on the origin and square-ish (`CanvasLayout.columns`), so the
    /// camera can simply return to identity afterwards.
    ///
    /// - Returns: how many tiles were placed.
    @discardableResult
    public func resetCanvasLayout(collectionID: UUID? = nil) throws -> Int {
        let scope = CanvasScope(collectionID: collectionID)
        // `items(collectionID:)` is the grid's own query — same ordering, same membership.
        let itemIDs = try items(collectionID: collectionID).map(\.id)
        let placements = CanvasLayout.placements(forItemIDs: itemIDs)

        try database.transaction {
            try database.run(
                "DELETE FROM item_positions WHERE scope = ?;",
                [.text(scope.storageKey)]
            )
            guard !placements.isEmpty else { return }
            let now = Date().timeIntervalSince1970
            let statement = try database.prepare("""
            INSERT OR REPLACE INTO item_positions
                (scope, item_id, x, y, z_order, scale, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            for placement in placements {
                statement.reset()
                try statement.bind([
                    .text(scope.storageKey),
                    .text(placement.itemID.uuidString),
                    .real(placement.x),
                    .real(placement.y),
                    .real(placement.z),
                    .real(placement.scale),
                    .real(now),
                ])
                try statement.step()
            }
        }
        return placements.count
    }

    // MARK: - Internals

    /// Non-finite coordinates would poison every downstream rect intersection (a `NaN` frame
    /// never intersects, so the tile would vanish and never come back). Reject at the edge.
    private func validate(_ placement: CanvasPlacement) throws {
        let finite = [placement.x, placement.y, placement.z, placement.scale]
        guard finite.allSatisfy({ $0.isFinite }) else {
            throw AtlasError.unsupported(
                "Canvas position must be finite (item \(placement.itemID.uuidString))"
            )
        }
    }
}
