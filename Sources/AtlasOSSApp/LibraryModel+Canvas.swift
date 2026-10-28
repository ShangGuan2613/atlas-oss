import AtlasCore
import CoreGraphics
import Foundation

/// Canvas board bridge between the sidebar selection and `item_positions` (P2-A).
///
/// Three rules hold the whole thing together:
///
/// 1. **The scope follows the sidebar.** A collection is its own board; All Items, Inbox and
///    tags draw the `all` board (tags filter items, they are not a place to file a tile).
/// 2. **Missing rows are healed, not hidden.** A board is seeded with the packed layout the
///    first time it is opened, and items imported since are appended below the existing
///    content and persisted — so a tile never jumps between launches.
/// 3. **Writes are batched.** A multi-select drag is one transaction, not N.
extension LibraryModel {

    /// Board the current sidebar selection points at.
    var resolvedCanvasScope: CanvasScope {
        switch selection {
        case .collection(let id):
            return .collection(id)
        case .inbox:
            return library.flatMap { try? $0.inboxCollection().id }.map { .collection($0) } ?? .all
        case .all, .tag, .none:
            // Tags and All Items share the library-wide board.
            return .all
        }
    }

    /// World rect tiles are clamped to while dragging on the **Canvas** surface. Infinity does
    /// not consult this — it passes `nil` to `CanvasDrag` instead.
    var canvasBoardRect: CGRect { CanvasLayout.boardRect }

    /// Loads the board for the current scope, seeding a layout if the library has none.
    ///
    /// Called when the Canvas appears, when the sidebar selection changes and when items
    /// change — the three moments at which `canvasPositions` could be stale.
    func reloadCanvasPositions() {
        guard let library else { return }
        let scope = resolvedCanvasScope
        canvasScope = scope

        do {
            var positions = try library.canvasPositions(scope: scope)

            if positions.isEmpty, !items.isEmpty {
                // First visit to this board: pack it in the grid's own order and persist, so
                // the layout is stable from the very first drag onwards.
                try library.resetCanvasLayout(collectionID: scope.collectionID)
                positions = try library.canvasPositions(scope: scope)
            } else {
                // New imports (or a re-import) have no row yet: append them below the
                // existing content at the board's pitch, then persist so they stay put.
                let placed = Set(positions.map(\.itemID))
                let missing = items.map(\.id).filter { !placed.contains($0) }
                if !missing.isEmpty {
                    try appendToBoard(missing, existing: positions, scope: scope, library: library)
                    positions = try library.canvasPositions(scope: scope)
                }
            }

            canvasPositions = positions
        } catch {
            canvasPositions = []
            reportLoadError("Could not read the canvas layout: \(error)")
        }
    }

    /// Moves a selection by a drag delta, bringing the moved tiles to the front.
    ///
    /// The delta is in world points, so the same gesture moves the same distance at any zoom.
    /// Nothing is written when the drag ends where it started.
    ///
    /// - Parameter bounded: `true` (Canvas) keeps each tile inside `CanvasLayout.boardRect`;
    ///   `false` (Infinity) writes the coordinate the gesture produced, wherever it landed.
    ///   Both paths write the *same* rows to the *same* table, which is what makes a tile moved
    ///   on one surface visible on the other after a switch.
    func moveCanvasItems(_ ids: Set<UUID>, byWorld delta: CGSize, bounded: Bool = true) {
        guard let library, !ids.isEmpty else { return }
        guard abs(delta.width) > 0.01 || abs(delta.height) > 0.01 else { return }

        let moved = CanvasDrag.positions(
            canvasPositions,
            moving: ids,
            byWorld: delta,
            board: bounded ? CanvasLayout.boardRect : nil
        )
        let restacked = CanvasDrag.restacked(moved, lifting: ids)
        let placements = restacked
            .filter { ids.contains($0.itemID) }
            .map { CanvasPlacement(position: $0) }

        do {
            try library.setCanvasPositions(placements, collectionID: canvasScope.collectionID)
            canvasPositions = try library.canvasPositions(scope: canvasScope)
        } catch {
            reportLoadError("Could not save the canvas position: \(error)")
            // Re-read so the board shows the truth rather than the failed preview.
            canvasPositions = (try? library.canvasPositions(scope: canvasScope)) ?? canvasPositions
        }
    }

    /// **Reset Layout**: repack this board as a grid in the current sort order.
    /// Returns the new content bounds so the caller can refit its camera.
    @discardableResult
    func resetCanvasLayout() -> CGRect {
        guard let library else { return .zero }
        do {
            try library.resetCanvasLayout(collectionID: canvasScope.collectionID)
            canvasPositions = try library.canvasPositions(scope: canvasScope)
        } catch {
            reportLoadError("Could not reset the canvas layout: \(error)")
        }
        return canvasContentBounds
    }

    /// World union of the current tiles — the rect "fit" frames.
    ///
    /// Uses the same footprint as packing and culling (`CanvasLayout.tileFrame`), so Fit framing
    /// the board and the board drawing itself are the same rectangle.
    var canvasContentBounds: CGRect {
        guard !canvasPositions.isEmpty else { return .zero }
        let frames = canvasPositions.map { CanvasLayout.tileFrame(for: $0) }
        return frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    }

    /// Removes rows for items that are no longer on this board (deleted or unfiled).
    /// Kept explicit and cheap: only ids the caller knows about are touched.
    @discardableResult
    func pruneCanvasPositions(keeping ids: Set<UUID>) -> Int {
        guard let library else { return 0 }
        let ghosts = canvasPositions.map(\.itemID).filter { !ids.contains($0) }
        guard !ghosts.isEmpty else { return 0 }
        let removed = (try? library.removeCanvasPositions(itemIDs: ghosts, collectionID: canvasScope.collectionID)) ?? 0
        if removed > 0 {
            canvasPositions = (try? library.canvasPositions(scope: canvasScope)) ?? canvasPositions
        }
        return removed
    }

    // MARK: - Internals

    /// Appends unplaced items below the existing block, continuing its pitch.
    private func appendToBoard(
        _ missing: [UUID],
        existing: [CanvasItemPosition],
        scope: CanvasScope,
        library: AtlasLibrary
    ) throws {
        let points = CanvasLayout.appendedPositions(existing: existing, count: missing.count)
        var z = existing.map(\.z).max() ?? -1
        var placements: [CanvasPlacement] = []
        for (itemID, point) in zip(missing, points) {
            z += 1
            placements.append(CanvasPlacement(itemID: itemID, x: point.x, y: point.y, z: z))
        }
        try library.setCanvasPositions(placements, collectionID: scope.collectionID)
    }
}
