import Foundation
import Testing
@testable import AtlasCore

/// P2-A gate: schema v4 is additive, and the Canvas board's truth (positions, packed reset,
/// scope isolation) survives a close/reopen.
@Suite("P2-A · canvas layout")
struct CanvasLayoutTests {

    // MARK: - Fixtures

    /// Builds a real v3 library on disk: v1+v2+v3 DDL, a seeded Inbox, three collections and
    /// five connected items. No `item_positions` — this is exactly what a P1 library is.
    private func makeV3Library(
        in workspace: TemporaryWorkspace,
        itemCount: Int = 5
    ) throws -> (paths: LibraryPaths, itemIDs: [UUID], collectionIDs: [UUID]) {
        let paths = workspace.libraryPaths
        try paths.createDirectories()
        let database = try SQLiteDatabase(path: paths.databaseURL.path)
        try database.execute(AtlasSchema.v1)
        try database.run("INSERT INTO library_meta (key, value) VALUES ('library_id', 'v3-legacy');")
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

        var collectionIDs: [UUID] = []
        for (index, name) in ["Moodboard", "Type"].enumerated() {
            let id = UUID()
            collectionIDs.append(id)
            try database.run("""
            INSERT INTO collections (id, name, created_at, updated_at, parent_id, sort_order)
            VALUES (?, ?, ?, ?, NULL, ?);
            """, [.text(id.uuidString), .text(name), .real(Double(index)), .real(Double(index)), .real(Double(index))])
        }

        try database.execute(AtlasSchema.v3)

        var itemIDs: [UUID] = []
        for index in 0 ..< itemCount {
            let id = UUID()
            itemIDs.append(id)
            try database.run("""
            INSERT INTO items (id, kind, mode, file_name, source_path, byte_size, content_hash,
                               imported_at, width, height)
            VALUES (?, 'image', 'connected', ?, ?, 42, ?, ?, 800, 600);
            """, [
                .text(id.uuidString),
                .text(String(format: "legacy-%02d.png", index)),
                .text("/tmp/legacy-\(index).png"),
                .text("hash-legacy-\(index)"),
                // Descending import times: the grid order is newest first.
                .real(Double(1_000 - index)),
            ])
            // Item 0 and 1 belong to the first collection, everything lands in Inbox.
            if index < 2 {
                try database.run(
                    "INSERT INTO collection_items (collection_id, item_id, added_at) VALUES (?, ?, 0);",
                    [.text(collectionIDs[0].uuidString), .text(id.uuidString)]
                )
            }
            try database.run(
                "INSERT INTO collection_items (collection_id, item_id, added_at) VALUES (?, ?, 0);",
                [.text(inboxID.uuidString), .text(id.uuidString)]
            )
        }

        database.userVersion = 3
        database.close()
        return (paths, itemIDs, collectionIDs)
    }

    // MARK: - Migration

    @Test("v3 → v4 is additive: every row survives and the board starts empty")
    func v3MigratesToV4() throws {
        let workspace = try TemporaryWorkspace(label: "v3-to-v4")
        let legacy = try makeV3Library(in: workspace)

        let library = try AtlasLibrary(paths: legacy.paths)
        defer { library.close() }

        let database = try SQLiteDatabase(path: library.paths.databaseURL.path)
        defer { database.close() }

        #expect(AtlasSchema.currentVersion == 4)
        #expect(Int(database.userVersion) == 4)
        #expect(try library.info().schemaVersion == 4)
        #expect(try objectNames(database, type: "table").contains("item_positions"))
        #expect(try objectNames(database, type: "index").contains("ix_item_positions_item"))

        // No data loss: every item, collection and link is still there.
        #expect(try library.itemCount() == 5)
        #expect(try library.items().map(\.id).sorted(by: { $0.uuidString < $1.uuidString })
            == legacy.itemIDs.sorted(by: { $0.uuidString < $1.uuidString }))
        #expect(try library.collectionTree().map(\.name) == ["Inbox", "Moodboard", "Type"])

        // And the board is genuinely empty — an auto-packed layout is the app's job, not a
        // migration's, so nothing is invented on disk.
        #expect(try library.canvasPositions(collectionID: nil).isEmpty)
        #expect(try library.canvasPositionCount(collectionID: nil) == 0)
    }

    @Test("reopening a v4 library neither reseeds nor renumbers the board")
    func migrationIsIdempotent() throws {
        let workspace = try TemporaryWorkspace(label: "v4-idempotent")
        let legacy = try makeV3Library(in: workspace)

        let first = try AtlasLibrary(paths: legacy.paths)
        let moved = legacy.itemIDs[0]
        try first.setCanvasPosition(itemID: moved, x: 120, y: -40, z: 3.5, scale: 1.5)
        #expect(try first.canvasPositions(collectionID: nil).count == 1)
        first.close()

        let second = try AtlasLibrary(paths: legacy.paths)
        defer { second.close() }
        let database = try SQLiteDatabase(path: second.paths.databaseURL.path)
        defer { database.close() }

        #expect(Int(database.userVersion) == 4)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM item_positions;") == 1)
        let position = try #require(try second.canvasPositions(collectionID: nil).first)
        #expect(position.itemID == moved)
        #expect(position.x == 120)
        #expect(position.y == -40)
        #expect(position.z == 3.5)
        #expect(position.scale == 1.5)
    }

    // MARK: - Read / write

    @Test("a placement is an upsert, not an append")
    func placementUpserts() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-upsert")
        let legacy = try makeV3Library(in: workspace)
        let library = try AtlasLibrary(paths: legacy.paths)
        defer { library.close() }

        let itemID = legacy.itemIDs[0]
        try library.setCanvasPosition(itemID: itemID, x: 10, y: 20)
        try library.setCanvasPosition(itemID: itemID, x: 300, y: -75)

        let positions = try library.canvasPositions(collectionID: nil)
        #expect(positions.count == 1)
        #expect(positions[0].x == 300)
        #expect(positions[0].y == -75)
    }

    @Test("All and each collection keep separate boards")
    func scopesAreIsolated() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-scopes")
        let legacy = try makeV3Library(in: workspace)
        let library = try AtlasLibrary(paths: legacy.paths)
        defer { library.close() }

        let itemID = legacy.itemIDs[0]
        let collectionID = legacy.collectionIDs[0]

        try library.setCanvasPosition(itemID: itemID, collectionID: nil, x: 1, y: 2)
        try library.setCanvasPosition(itemID: itemID, collectionID: collectionID, x: 900, y: 800)

        #expect(try library.canvasPositions(collectionID: nil).map(\.x) == [1])
        #expect(try library.canvasPositions(collectionID: collectionID).map(\.x) == [900])
        #expect(try library.canvasPositions(collectionID: legacy.collectionIDs[1]).isEmpty)
        // The "All" board is the storage key, not an empty-string or NULL collection id.
        #expect(CanvasScope(collectionID: nil).storageKey == "all")
        #expect(CanvasScope(storageKey: "all") == .all)
        #expect(CanvasScope(storageKey: collectionID.uuidString) == .collection(collectionID))
    }

    @Test("positions survive a close/reopen (the relaunch gate)")
    func positionsSurviveRelaunch() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-relaunch")
        let legacy = try makeV3Library(in: workspace)
        let collectionID = legacy.collectionIDs[0]
        let itemID = legacy.itemIDs[1]

        let first = try AtlasLibrary(paths: legacy.paths)
        try first.setCanvasPosition(itemID: itemID, collectionID: collectionID, x: -512.5, y: 640, z: 7, scale: 2)
        first.close()

        let second = try AtlasLibrary(paths: legacy.paths)
        defer { second.close() }
        let restored = try #require(try second.canvasPositions(collectionID: collectionID).first)
        #expect(restored.itemID == itemID)
        #expect(restored.x == -512.5)
        #expect(restored.y == 640)
        #expect(restored.z == 7)
        #expect(restored.scale == 2)
    }

    @Test("a multi-select drag batch lands as one write and keeps every tile")
    func batchWritePlacesEveryTile() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-batch")
        let legacy = try makeV3Library(in: workspace)
        let library = try AtlasLibrary(paths: legacy.paths)
        defer { library.close() }

        let placements = legacy.itemIDs.enumerated().map { index, id in
            CanvasPlacement(itemID: id, x: Double(index) * 10, y: Double(index) * -10, z: Double(index))
        }
        try library.setCanvasPositions(placements, collectionID: nil)

        let positions = try library.canvasPositions(collectionID: nil)
        #expect(positions.count == legacy.itemIDs.count)
        // Read back in paint order, which is the order the drag wrote.
        #expect(positions.map(\.z) == placements.map(\.z))
    }

    @Test("non-finite coordinates are rejected instead of poisoning the board")
    func nonFiniteCoordinatesAreRejected() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-nan")
        let legacy = try makeV3Library(in: workspace)
        let library = try AtlasLibrary(paths: legacy.paths)
        defer { library.close() }

        #expect(throws: AtlasError.self) {
            try library.setCanvasPosition(itemID: legacy.itemIDs[0], x: .nan, y: 0)
        }
        #expect(throws: AtlasError.self) {
            try library.setCanvasPositions(
                [CanvasPlacement(itemID: legacy.itemIDs[0], x: 0, y: .infinity)],
                collectionID: nil
            )
        }
        #expect(try library.canvasPositions(collectionID: nil).isEmpty)
    }

    @Test("scale is clamped on the way in and on the way out")
    func scaleIsClamped() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-scale")
        let legacy = try makeV3Library(in: workspace)
        let library = try AtlasLibrary(paths: legacy.paths)
        defer { library.close() }

        try library.setCanvasPosition(itemID: legacy.itemIDs[0], x: 0, y: 0, scale: 99)
        let position = try #require(try library.canvasPositions(collectionID: nil).first)
        #expect(position.scale == CanvasLayout.maxScale)
    }

    @Test("removing placements leaves the items themselves alone")
    func removePlacementsOnly() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-remove")
        let legacy = try makeV3Library(in: workspace)
        let library = try AtlasLibrary(paths: legacy.paths)
        defer { library.close() }

        try library.setCanvasPositions(
            CanvasLayout.placements(forItemIDs: legacy.itemIDs),
            collectionID: nil
        )
        let removed = try library.removeCanvasPositions(itemIDs: [legacy.itemIDs[0]], collectionID: nil)
        #expect(removed == 1)
        #expect(try library.canvasPositions(collectionID: nil).count == legacy.itemIDs.count - 1)
        #expect(try library.itemCount() == legacy.itemIDs.count)
    }

    // MARK: - Reset

    @Test("reset packs the board in the grid's own sort order")
    func resetPacksInGridOrder() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-reset")
        let legacy = try makeV3Library(in: workspace)
        let library = try AtlasLibrary(paths: legacy.paths)
        defer { library.close() }

        let gridOrder = try library.items().map(\.id)
        // Scatter first, so the reset has something to undo.
        try library.setCanvasPositions(
            gridOrder.enumerated().map { index, id in
                CanvasPlacement(itemID: id, x: Double(index) * 977, y: Double(index) * -613, z: Double(index))
            },
            collectionID: nil
        )

        let count = try library.resetCanvasLayout(collectionID: nil)
        #expect(count == gridOrder.count)

        let positions = try library.canvasPositions(collectionID: nil)
        #expect(positions.count == gridOrder.count)
        // Same order as the grid, and the same coordinates the pure packer produces.
        #expect(positions.map(\.itemID) == gridOrder)
        let expected = CanvasLayout.placements(forItemIDs: gridOrder)
        #expect(positions.map(\.x) == expected.map(\.x))
        #expect(positions.map(\.y) == expected.map(\.y))
        #expect(positions.map(\.z) == expected.map(\.z))
    }

    @Test("reset on a collection only touches that collection's board")
    func resetIsScoped() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-reset-scope")
        let legacy = try makeV3Library(in: workspace)
        let library = try AtlasLibrary(paths: legacy.paths)
        defer { library.close() }

        try library.setCanvasPosition(itemID: legacy.itemIDs[0], collectionID: nil, x: 55, y: 66)
        let count = try library.resetCanvasLayout(collectionID: legacy.collectionIDs[0])

        #expect(count == 2)
        #expect(try library.canvasPositions(collectionID: legacy.collectionIDs[0]).count == 2)
        // The All board keeps the manual placement.
        #expect(try library.canvasPositions(collectionID: nil).map(\.x) == [55])
    }

    @Test("reset on an empty board writes nothing and does not throw")
    func resetOnEmptyBoard() throws {
        let workspace = try TemporaryWorkspace(label: "canvas-reset-empty")
        let paths = workspace.libraryPaths
        try paths.createDirectories()

        let library = try AtlasLibrary(paths: paths)
        defer { library.close() }

        #expect(try library.resetCanvasLayout(collectionID: nil) == 0)
        #expect(try library.canvasPositions(collectionID: nil).isEmpty)
    }

    // MARK: - Pure layout math

    @Test("packed columns are as square as possible")
    func packedColumns() {
        #expect(CanvasLayout.columns(for: 0) == 1)
        #expect(CanvasLayout.columns(for: 1) == 1)
        #expect(CanvasLayout.columns(for: 2) == 2)
        #expect(CanvasLayout.columns(for: 4) == 2)
        #expect(CanvasLayout.columns(for: 5) == 3)
        #expect(CanvasLayout.columns(for: 9) == 3)
        #expect(CanvasLayout.columns(for: 10) == 4)
        #expect(CanvasLayout.rows(for: 5) == 2)
        #expect(CanvasLayout.rows(for: 9) == 3)
    }

    @Test("a packed block is centred on the origin and never overlaps")
    func packedBlockIsCentredAndDisjoint() {
        for count in [1, 2, 3, 5, 8, 13, 40] {
            let bounds = CanvasLayout.packedBounds(count: count)
            #expect(abs(bounds.midX) < 0.001)
            #expect(abs(bounds.midY) < 0.001)

            let points = (0 ..< count).map { CanvasLayout.packedPosition(index: $0, count: count) }
            // The real footprint — 4:3, not a square. A square here is exactly what made the
            // P2-A board look misaligned: packing reserved 220 pt of height for a 165 pt tile.
            let tiles = points.map { CanvasLayout.tileFrame(x: $0.x, y: $0.y) }
            for (index, tile) in tiles.enumerated() {
                #expect(bounds.contains(tile))
                for other in tiles[(index + 1)...] {
                    #expect(!tile.intersects(other))
                }
            }
        }
    }

    @Test("row pitch is the tile's real height + gutter; column pitch its width + gutter")
    func packedPitchUsesTheTileAspect() {
        #expect(CanvasLayout.tileAspect == 0.75)
        #expect(CanvasLayout.tileWidth == CanvasLayout.tileSize)
        #expect(CanvasLayout.tileHeight == CanvasLayout.tileSize * 0.75)
        #expect(CanvasLayout.pitchX == CanvasLayout.tileWidth + CanvasLayout.gap)
        #expect(CanvasLayout.pitchY == CanvasLayout.tileHeight + CanvasLayout.gap)

        // Measured on a real block rather than on the constants: the gap between rows is the
        // gutter, so two adjacent rows are one tile-height plus one gutter apart.
        let count = 9
        let columns = CanvasLayout.columns(for: count)
        let first = CanvasLayout.packedPosition(index: 0, count: count)
        let nextRow = CanvasLayout.packedPosition(index: columns, count: count)
        #expect(abs((nextRow.y - first.y) - (CanvasLayout.tileHeight + CanvasLayout.gap)) < 0.001)

        let secondColumn = CanvasLayout.packedPosition(index: 1, count: count)
        #expect(abs((secondColumn.x - first.x) - (CanvasLayout.tileWidth + CanvasLayout.gap)) < 0.001)

        // Rows are tighter than columns now (4:3 tiles), and the block height follows suit.
        #expect(CanvasLayout.pitchY < CanvasLayout.pitchX)
        let rows = CanvasLayout.rows(for: count, columns: columns)
        let bounds = CanvasLayout.packedBounds(count: count)
        #expect(abs(bounds.height - (Double(rows) * CanvasLayout.tileHeight + Double(rows - 1) * CanvasLayout.gap)) < 0.001)
    }

    @Test("packed order is left-to-right, then down — same as the grid")
    func packedOrderReadsLikeTheGrid() {
        let count = 5
        let columns = CanvasLayout.columns(for: count)
        let first = CanvasLayout.packedPosition(index: 0, count: count)
        let points = (0 ..< count).map { CanvasLayout.packedPosition(index: $0, count: count) }

        func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) < 0.001 }

        for index in 1 ..< count {
            let previous = points[index - 1]
            let current = points[index]
            if index % columns == 0 {
                // Wrapped onto the next row: back to the first column, one row pitch down.
                #expect(close(current.x, first.x))
                #expect(close(current.y, previous.y + CanvasLayout.pitchY))
            } else {
                #expect(close(current.y, previous.y))
                #expect(close(current.x, previous.x + CanvasLayout.pitchX))
            }
        }
    }

    @Test("appended tiles go on a free row below the board and stay deterministic")
    func appendedPositionsAreStable() {
        let existing = CanvasLayout.placements(forItemIDs: (0 ..< 4).map { _ in UUID() })
            .map { CanvasItemPosition(itemID: $0.itemID, x: $0.x, y: $0.y) }
        let first = CanvasLayout.appendedPositions(existing: existing, count: 3)
        let second = CanvasLayout.appendedPositions(existing: existing, count: 3)

        #expect(first.count == 3)
        #expect(first == second)

        // Below every existing tile (no overlap) and inside the existing column span.
        let maxY = existing.map(\.y).max() ?? 0
        let minX = existing.map(\.x).min() ?? 0
        let maxX = existing.map(\.x).max() ?? 0
        for point in first {
            // A whole tile *and* the gutter below the lowest tile, not just one square pitch.
            #expect(point.y >= maxY + CanvasLayout.pitchY)
            #expect(point.x >= minX)
            #expect(point.x <= maxX)
        }

        // And nothing overlaps an existing tile when both are measured with the real footprint.
        let existingFrames = existing.map { CanvasLayout.tileFrame(x: $0.x, y: $0.y) }
        let newFrames = first.map { CanvasLayout.tileFrame(x: $0.x, y: $0.y) }
        for (index, frame) in newFrames.enumerated() {
            for other in existingFrames {
                #expect(!frame.intersects(other))
            }
            for other in newFrames[(index + 1)...] {
                #expect(!frame.intersects(other))
            }
        }
    }

    @Test("appending to an empty board is the packed block")
    func appendedPositionsOnEmptyBoard() {
        let appended = CanvasLayout.appendedPositions(existing: [], count: 4)
        let packed = (0 ..< 4).map { CanvasLayout.packedPosition(index: $0, count: 4) }
        #expect(appended == packed)
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
