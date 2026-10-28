import Foundation

// MARK: - Scope

/// Which board a placement belongs to.
///
/// A Canvas board is either the whole library (`all`) or one collection. Tags are *not* a
/// board: a tag view filters items but draws the `all` board, so dropping a tile while a tag
/// is selected cannot invent a third layout the sidebar has no column for.
///
/// `storageKey` is what lands in `item_positions.scope`. It is deliberately **not** nullable —
/// SQLite treats NULLs in a PRIMARY KEY as distinct, so a `NULL` for "All" would allow
/// duplicate rows per item. `'all'` is the null-free encoding of "no collection".
public enum CanvasScope: Hashable, Sendable, Codable {
    /// The whole library — `collection_id IS NULL` in the API's terms.
    case all
    case collection(UUID)

    public init(collectionID: UUID?) {
        self = collectionID.map { .collection($0) } ?? .all
    }

    /// Value stored in `item_positions.scope`.
    public var storageKey: String {
        switch self {
        case .all: return "all"
        case .collection(let id): return id.uuidString
        }
    }

    /// Parses a stored scope key. Anything unrecognised is treated as `all` so a corrupt or
    /// future key can only ever widen a board, never hide its tiles.
    public init(storageKey: String) {
        self = UUID(uuidString: storageKey).map { .collection($0) } ?? .all
    }

    /// The collection this board belongs to, or `nil` for the whole library.
    public var collectionID: UUID? {
        switch self {
        case .all: return nil
        case .collection(let id): return id
        }
    }
}

// MARK: - Placement

/// Where one item sits on a board.
///
/// `x`/`y` are world points of the tile's **top-left corner** in the board's own coordinate
/// space; `z` is the paint order (higher paints later, i.e. on top); `scale` multiplies the
/// tile's base size. Pure value types, so the whole board is testable without SwiftUI.
public struct CanvasItemPosition: Sendable, Hashable, Codable, Identifiable {
    public let itemID: UUID
    public let x: Double
    public let y: Double
    public let z: Double
    public let scale: Double

    public var id: UUID { itemID }

    public init(itemID: UUID, x: Double, y: Double, z: Double = 0, scale: Double = 1) {
        self.itemID = itemID
        self.x = x
        self.y = y
        self.z = z
        self.scale = CanvasLayout.clampScale(scale)
    }

    /// Moves the tile, keeping its depth. Used by drag and by the multi-drag maths.
    public func moved(toX newX: Double, y newY: Double) -> CanvasItemPosition {
        CanvasItemPosition(itemID: itemID, x: newX, y: newY, z: z, scale: scale)
    }

    public func offset(byX dx: Double, y dy: Double) -> CanvasItemPosition {
        moved(toX: x + dx, y: y + dy)
    }
}

/// The write side: a position that is about to be persisted. Separated from
/// `CanvasItemPosition` only so call sites read as "this is a change", not "this is state".
public struct CanvasPlacement: Sendable, Hashable {
    public let itemID: UUID
    public let x: Double
    public let y: Double
    public let z: Double
    public let scale: Double

    public init(itemID: UUID, x: Double, y: Double, z: Double = 0, scale: Double = 1) {
        self.itemID = itemID
        self.x = x
        self.y = y
        self.z = z
        self.scale = CanvasLayout.clampScale(scale)
    }

    public init(position: CanvasItemPosition) {
        self.init(
            itemID: position.itemID,
            x: position.x,
            y: position.y,
            z: position.z,
            scale: position.scale
        )
    }
}

// MARK: - Layout math

/// The board's geometry vocabulary: tile size, gutter, and the **packed grid** that
/// `resetCanvasLayout` lays items out in.
///
/// Exemplar note (PureRef / tldraw): the packed grid is the "Reset layout" answer — a
/// deterministic, non-overlapping, visually even arrangement of the *current sort*, so a
/// board can always be recovered from a mess without a physics solver or a second table.
public enum CanvasLayout {
    /// Base tile **width** in world points at `scale == 1`.
    public static let tileSize: Double = 220

    /// Tile aspect — **height ÷ width**, i.e. 4:3 — matching `GridDensity.thumbnailAspect` so a
    /// board tile has exactly the shape of a grid cell's image box.
    ///
    /// The constant lives in Core because `CanvasLayout` may not import the app target, so the
    /// app-side test `CanvasTests.testBoardTileFootprintIsTheDrawnTile` pins it to
    /// `GridDensity.thumbnailAspect` and to `GridDensity.thumbnailHeight(cellWidth:)` — the two
    /// cannot drift apart again. (They did: P2-A packed with a square 220 × 220 footprint while
    /// the tile drew 220 × 165, which is the misalignment P2-A-FEEL is about.)
    public static let tileAspect: Double = 0.75

    /// Gutter between packed tiles, on both axes.
    public static let gap: Double = 24

    /// Height of one caption block (file name + dimensions) **if** captions are ever turned
    /// back on for the board. Canvas draws no captions — see `CanvasView` — so this budget is
    /// deliberately *not* part of the default footprint: a caption must never move a grid line.
    public static let captionHeight: Double = 34

    public static var tileWidth: Double { tileSize }
    public static var tileHeight: Double { tileSize * tileAspect }

    /// Column pitch and row pitch. They are **not** equal: a 4:3 tile packs into a 4:3-wide
    /// cell, so a packed block has `pitchY < pitchX`. Using one number for both (P2-A) is what
    /// made a reset board drift out of alignment as the rows filled up.
    public static var pitchX: Double { tileWidth + gap }
    public static var pitchY: Double { tileHeight + gap }

    /// The footprint one tile occupies on the board.
    ///
    /// Packing, the spatial index, `contentBounds` and the drag clamp all go through this, so
    /// "what the index culls" and "what the user sees" cannot disagree — the single source of
    /// the P2-A misalignment was those four call sites each doing their own square maths.
    public static func tileFrame(
        x: Double,
        y: Double,
        scale: Double = 1,
        captions: Bool = false
    ) -> CGRect {
        let size = clampScale(scale)
        return CGRect(
            x: x,
            y: y,
            width: tileWidth * size,
            height: tileHeight * size + (captions ? captionHeight * size : 0)
        )
    }

    public static func tileFrame(
        for position: CanvasItemPosition,
        captions: Bool = false
    ) -> CGRect {
        tileFrame(x: position.x, y: position.y, scale: position.scale, captions: captions)
    }

    /// Board extent. P2-B **removed the camera clamp** that used to make this a hard clip, so
    /// this value now means exactly two things: the area **Reset Layout** packs into (so a
    /// reset always lands somewhere predictable), and the dashed frame Canvas draws to say
    /// "this is the board". Infinity draws no frame and does not clamp a drag at all — the same
    /// `item_positions` rows, read by an edgeless camera.
    public static let boardExtent: Double = 8000

    /// The Canvas board itself: a square centred on the origin, ≈65 columns × 84 rows of packed
    /// 4:3 tiles.
    ///
    /// Not a camera clip any more (see `boardExtent`) — a containment rect for tile drags on
    /// the Canvas surface, and the outline Canvas paints. Infinity passes `nil` instead.
    public static var boardRect: CGRect {
        CGRect(
            x: -boardExtent,
            y: -boardExtent,
            width: boardExtent * 2,
            height: boardExtent * 2
        )
    }

    public static let minScale: Double = 0.25
    public static let maxScale: Double = 4

    public static func clampScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return min(maxScale, max(minScale, scale))
    }

    /// Columns in a packed block: as square as possible (`ceil(sqrt(n))`).
    ///
    /// A near-square *count* keeps pan/zoom distances roughly equal in both axes, which is what
    /// makes "Reset layout" feel centred rather than like a long ribbon. Note that with 4:3
    /// tiles the block itself is a little wider than tall (`pitchX > pitchY`); that is the
    /// tiles' shape, not a second layout rule, and `packedBounds` measures it exactly.
    public static func columns(for count: Int) -> Int {
        guard count > 1 else { return 1 }
        return Int(Double(count).squareRoot().rounded(.up))
    }

    public static func rows(for count: Int, columns: Int? = nil) -> Int {
        guard count > 0 else { return 0 }
        let cols = max(1, columns ?? Self.columns(for: count))
        return (count + cols - 1) / cols
    }

    /// World rect a packed block of `count` tiles occupies, centred on the origin.
    public static func packedBounds(count: Int) -> CGRect {
        guard count > 0 else { return .zero }
        let cols = columns(for: count)
        let rows = rows(for: count, columns: cols)
        let width = Double(cols) * tileWidth + Double(cols - 1) * gap
        let height = Double(rows) * tileHeight + Double(rows - 1) * gap
        return CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    }

    /// Top-left corner of tile `index` in a packed block of `count`, centred on the origin.
    ///
    /// Fills left-to-right, top-to-bottom — the same order the Grid renders, so a reset
    /// board reads like the grid the user just came from.
    public static func packedPosition(index: Int, count: Int) -> CGPoint {
        guard count > 0 else { return .zero }
        let safeIndex = min(max(0, index), count - 1)
        let cols = columns(for: count)
        let bounds = packedBounds(count: count)
        let column = safeIndex % cols
        let row = safeIndex / cols
        return CGPoint(
            x: bounds.minX + Double(column) * pitchX,
            y: bounds.minY + Double(row) * pitchY
        )
    }

    /// Placements for a whole block, in the given order (which is the caller's sort order).
    /// `z` follows the index so the paint order matches the grid order.
    public static func placements(forItemIDs itemIDs: [UUID]) -> [CanvasPlacement] {
        let count = itemIDs.count
        return itemIDs.enumerated().map { index, itemID in
            let point = packedPosition(index: index, count: count)
            return CanvasPlacement(itemID: itemID, x: point.x, y: point.y, z: Double(index))
        }
    }

    /// Positions for **appending** new items to an existing board.
    ///
    /// New imports must not land on top of an existing tile and must not move one either,
    /// so appended tiles start on the first free row *below* the current content and fill
    /// left-to-right at the same pitch, wrapping at the existing block's column count.
    /// Deterministic for a given board, so a relaunch re-derives the same coordinates; the
    /// app persists them on first sight, after which they are simply rows in the table.
    public static func appendedPositions(
        existing: [CanvasItemPosition],
        count: Int
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        guard let minX = existing.map(\.x).min(),
              let maxX = existing.map(\.x).max(),
              let maxY = existing.map(\.y).max() else {
            // Empty board: the packed block, centred on the origin.
            return (0 ..< count).map { packedPosition(index: $0, count: count) }
        }
        let columns = max(1, Int(((maxX - minX) / pitchX).rounded()) + 1)
        // One full row below the lowest tile: its height, then the gutter.
        let startY = maxY + pitchY
        return (0 ..< count).map { index in
            CGPoint(
                x: minX + Double(index % columns) * pitchX,
                y: startY + Double(index / columns) * pitchY
            )
        }
    }
}
