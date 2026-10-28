import AtlasCore
import CoreGraphics
import Foundation

// MARK: - Camera

/// The Canvas camera: a pure value type, so pan/zoom/culling can be tested without a window.
///
/// Exemplar (PureRef / tldraw): the board does **not** scroll — the camera moves. `origin` is
/// the world point sitting under the viewport's top-left corner, `zoom` multiplies world
/// points into view points. Three consequences that the rest of this file depends on:
///
/// - Zoom is **anchored on a pointer**: `zoomed(by:anchoredAt:)` keeps the world point under
///   that view point exactly where it was, which is the whole feel of the gesture.
/// - **Panning is unbounded** (P2-B). P2-A clamped the origin so the ±8 000 pt board could
///   never be lost; that clamp is gone, because Infinity is an edgeless camera over the same
///   spatial rows (Are.na browse, PureRef pan). What replaces it is a *soft* recovery: the
///   board's HUD notices when the content is off-screen and offers **Fit** (`fitting(...)`).
/// - The camera is therefore only *sanitised*, never *contained*: zoom stays on the ladder and
///   the origin stays finite and inside `practicalExtent`, so junk input cannot wedge it.
struct CanvasCamera: Equatable {
    /// The overview floor. At 0.01 a 220 pt tile is 2.2 pt — a dot, which is what an edgeless
    /// board should show when Fit has to frame a widely scattered collection. P2-A floored at
    /// 0.1 because its board was finite and small; Infinity can be 500 items spread over tens of
    /// thousands of points, and a floor that refuses to frame them is a bug, not a taste.
    ///
    /// Documented ceiling: a 1 400 × 900 window at 0.01 shows ≈ 140 000 × 90 000 world points,
    /// so Fit frames any collection inside that box. Larger boards still *centre* on their middle
    /// (no clamp, no clip) and are reachable by panning.
    static let minZoom: Double = 0.01
    /// Above 4× tiles are blurry: the decode ladder tops out at 540 px.
    static let maxZoom: Double = 4
    static let defaultZoom: Double = 1

    /// World point under the viewport's top-left corner.
    var origin: CGPoint
    /// World points → view points.
    var zoom: Double

    init(origin: CGPoint = .zero, zoom: Double = CanvasCamera.defaultZoom) {
        self.origin = origin
        self.zoom = CanvasCamera.clampZoom(zoom)
    }

    static func clampZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite, zoom > 0 else { return defaultZoom }
        return min(maxZoom, max(minZoom, zoom))
    }

    /// ±1 000 000 world points — about 4 000 packed tiles each way, and far past anything a
    /// drag can express. The bound is not a clip rect: it exists so one `NaN` or one absurd
    /// pan cannot leave the camera somewhere no gesture can return from.
    static let practicalExtent: Double = 1_000_000

    // MARK: Conversions

    func viewPoint(forWorld point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) * zoom, y: (point.y - origin.y) * zoom)
    }

    func worldPoint(forView point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x / zoom, y: origin.y + point.y / zoom)
    }

    /// World-space size of one view point, i.e. a drag's translation in world units.
    var worldPerViewPoint: Double { 1 / zoom }

    /// The world rect the viewport currently shows, grown by `margin` on every side so
    /// culling can realise a band around the edge instead of popping tiles at the boundary.
    func visibleWorldRect(viewport: CGSize, margin: Double = 0) -> CGRect {
        let size = CGSize(width: viewport.width / zoom, height: viewport.height / zoom)
        return CGRect(origin: origin, size: size).insetBy(dx: -margin, dy: -margin)
    }

    // MARK: Moves

    /// Zoom by `factor`, keeping the world point under `anchor` (a view point) fixed.
    func zoomed(by factor: Double, anchoredAt anchor: CGPoint) -> CanvasCamera {
        guard factor.isFinite, factor > 0 else { return self }
        let nextZoom = CanvasCamera.clampZoom(zoom * factor)
        guard nextZoom != zoom else { return self }
        let anchorInWorld = worldPoint(forView: anchor)
        var next = self
        next.zoom = nextZoom
        next.origin = CGPoint(
            x: anchorInWorld.x - anchor.x / nextZoom,
            y: anchorInWorld.y - anchor.y / nextZoom
        )
        return next
    }

    /// Move the camera as if its content were dragged by `delta` view points.
    func panned(byViewDelta delta: CGSize) -> CanvasCamera {
        var next = self
        next.origin = CGPoint(
            x: origin.x - delta.width / zoom,
            y: origin.y - delta.height / zoom
        )
        return next
    }

    /// Makes the camera **usable**, not contained.
    ///
    /// This is what replaced P2-A's `clamped(to:viewport:)`. That function kept `minVisible`
    /// world points of the board on screen so a fast pan could never lose it — and in doing so
    /// it was a hard clip: you could not place a tile past the board edge, and the camera would
    /// refuse to follow one there. Infinity deletes that rule. Panning is free; zoom stays on
    /// the ladder; a non-finite or absurd origin snaps to the practical edge. Recovery is a
    /// *button* (`fit`), not a constraint.
    func sanitized() -> CanvasCamera {
        var next = self
        next.zoom = CanvasCamera.clampZoom(zoom)
        next.origin = CGPoint(
            x: CanvasCamera.clampPractical(origin.x),
            y: CanvasCamera.clampPractical(origin.y)
        )
        return next
    }

    private static func clampPractical(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(practicalExtent, max(-practicalExtent, value))
    }

    /// Whether any part of `rect` (world) is on screen right now.
    ///
    /// Drives the soft "find content" affordance: with unbounded panning, content *can* be
    /// lost, so the board says so and offers Fit rather than clamping the camera to prevent it.
    func shows(_ rect: CGRect, viewport: CGSize) -> Bool {
        guard !rect.isNull, !rect.isEmpty, viewport.width > 0, viewport.height > 0 else { return true }
        return visibleWorldRect(viewport: viewport).intersects(rect)
    }

    /// Frame `content` (world rect) inside the viewport, leaving `padding` view points of air.
    static func fitting(content: CGRect, viewport: CGSize, padding: Double = 48) -> CanvasCamera {
        guard viewport.width > 1, viewport.height > 1 else { return CanvasCamera() }
        let usableWidth = max(1, viewport.width - padding * 2)
        let usableHeight = max(1, viewport.height - padding * 2)

        guard content.width > 0, content.height > 0 else { return CanvasCamera() }
        let scale = clampZoom(min(usableWidth / content.width, usableHeight / content.height))
        var camera = CanvasCamera(origin: .zero, zoom: scale)
        camera.origin = CGPoint(
            x: content.midX - viewport.width / (2 * scale),
            y: content.midY - viewport.height / (2 * scale)
        )
        return camera
    }
}

// MARK: - Layer transform

/// The **one** transform the whole board is drawn with.
///
/// The tile layer is laid out in *world* points and the camera is expressed here as a single
/// affine pair: multiply by `scale`, then shift by `offset`. That is exactly
/// `CanvasCamera.viewPoint(forWorld:)`,
///
///     view = world * zoom + (-origin * zoom)
///
/// hoisted out of the per-tile loop. P2-A used to call `viewPoint(forWorld:)` once per tile,
/// per frame and then give each tile its own `.offset` and its own zoom-scaled width — so a
/// camera move re-laid-out every visible SwiftUI view. Now it is one `scaleEffect` + one
/// `offset` on a container, i.e. one Core Animation transform. `CanvasTests` asserts the two
/// forms agree to the last representable point, so the single transform cannot silently drift
/// from the camera the culling and the pointer-anchored zoom are computed with.
struct CanvasLayerTransform: Equatable {
    /// World points → view points.
    let scale: Double
    /// View-point shift applied *after* scaling.
    let offset: CGSize

    func viewPoint(forWorld point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }
}

extension CanvasCamera {
    var layerTransform: CanvasLayerTransform {
        CanvasLayerTransform(
            scale: zoom,
            offset: CGSize(width: -origin.x * zoom, height: -origin.y * zoom)
        )
    }

    /// World → view matrix: `(world - origin) * zoom`, the same mapping as
    /// `viewPoint(forWorld:)`.
    ///
    /// `translatedBy` runs on the input of the receiver, so `-origin` is applied first
    /// and the scale carries that translation (`tx = -origin * zoom`). The other
    /// concatenation order scales the point and then adds an unscaled origin, which
    /// misses by `(zoom - 1) * origin`. `CanvasBoardNSView` installs this as the one
    /// `sublayerTransform`. Hit-testing uses `inverted()`.
    var viewTransform: CGAffineTransform {
        CGAffineTransform(scaleX: zoom, y: zoom)
            .translatedBy(x: -origin.x, y: -origin.y)
    }
}

// MARK: - LOD

/// Stepped level of detail, after tldraw.
///
/// The board is a moodboard: it draws **no captions** (PureRef/Atlas behaviour), so LOD is no
/// longer about dropping text — it is about *decode* cost. A tile asks the thumbnail store for
/// the rung its on-screen width needs, and the ladder has five rungs (`ThumbnailStore
/// .bucketSizes`), so a full zoom sweep re-decodes at most five times per tile instead of once
/// per pixel of zoom. Decoding during a gesture is the other half of "卡顿": the camera move is
/// now cheap, and this keeps the image work from becoming the new bottleneck.
enum CanvasLOD {
    /// Ask for ~1.5× the on-screen width, like the grid does, so a Retina tile stays sharp.
    static let decodeOverdraw: Double = 1.5

    /// Thumbnail rung (pixels) for a tile drawn at `tileWorldWidth * scale` at `zoom`.
    static func decodePixelWidth(
        tileWorldWidth: Double = CanvasLayout.tileWidth,
        scale: Double = 1,
        zoom: Double
    ) -> Int {
        let viewWidth = tileWorldWidth * scale * zoom
        guard viewWidth.isFinite, viewWidth > 0 else { return ThumbnailStore.defaultMaxPixel }
        return ThumbnailStore.bucket(forMaxPixel: Int((viewWidth * decodeOverdraw).rounded()))
    }
}

// MARK: - Spatial index

/// Uniform-grid spatial index over board tiles.
///
/// Exemplar: tldraw's culling. The Excalidraw trap is re-walking every shape each frame; here
/// the board is bucketed once per layout change (`cellSize` ≈ one tile pitch), so a camera move
/// costs O(tiles in view) instead of O(board). Brute-force rect tests would still be fine at
/// 200 items — this is what keeps the same code honest at 5 000.
///
/// P2-B note: Infinity's camera is unbounded, so a query rect can sit at offsets P2-A never
/// produced (a tile dragged to x = 40 000, a pan to ±1 000 000). `Int(Double)` **traps** on a
/// value Swift cannot represent, so every coordinate goes through `cellIndex(_:)`, which
/// returns `nil` instead of crashing and sends the query down the scan path.
struct CanvasSpatialIndex {
    private struct Cell: Hashable {
        let column: Int
        let row: Int
    }

    private struct Entry {
        let frame: CGRect
        let z: Double
    }

    private let cellSize: Double
    private var cells: [Cell: [UUID]] = [:]
    private var entries: [UUID: Entry] = [:]

    init(cellSize: Double = CanvasLayout.pitchX) {
        self.cellSize = max(1, cellSize)
    }

    /// Rebuilds from the current board. One pass, no allocation in the query path.
    init(positions: [CanvasItemPosition], cellSize: Double = CanvasLayout.pitchX) {
        self.init(cellSize: cellSize)
        update(positions: positions)
    }

    /// Buckets every tile using its **real footprint** (`CanvasLayout.tileFrame`), never a
    /// square stand-in: a 4:3 tile that is 220 wide and 165 tall must not claim 55 points of
    /// empty air below it, or the culled set and the drawn set disagree at the band edges.
    mutating func update(positions: [CanvasItemPosition]) {
        cells.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)

        for position in positions {
            let frame = CanvasLayout.tileFrame(for: position)
            entries[position.itemID] = Entry(frame: frame, z: position.z)
            forEachCell(in: frame) { cell in
                cells[cell, default: []].append(position.itemID)
            }
        }
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func frame(for itemID: UUID) -> CGRect? {
        entries[itemID]?.frame
    }

    /// Every tile frame that intersects `rect`, back-to-front.
    func itemIDs(in rect: CGRect) -> [UUID] {
        // A non-finite query rect is rejected outright. `CGRect.intersects` returns **true** for
        // a NaN rect (measured on this SDK), so letting one through would realise the entire
        // board — the accidental full-scene walk this index exists to avoid.
        guard !entries.isEmpty,
              rect.width > 0, rect.height > 0,
              rect.minX.isFinite, rect.maxX.isFinite,
              rect.minY.isFinite, rect.maxY.isFinite else { return [] }
        guard let minColumn = cellIndex(rect.minX),
              let maxColumn = cellIndex(rect.maxX),
              let minRow = cellIndex(rect.minY),
              let maxRow = cellIndex(rect.maxY) else {
            // Non-finite or beyond the cell-index range: answer exactly, just slower.
            return scanned(rect)
        }

        // Adaptive, and measured: when the query rect covers more cells than there are tiles
        // (zoomed out far enough that the whole board is on screen), probing empty buckets
        // costs more than testing every tile. At 250 items a whole-board query went from
        // 165 µs to ~10 µs with this switch; at high zoom the bucket path wins and is used.
        // The span itself is overflow-safe: both indices are inside ±`cellIndexLimit`, so the
        // product of their extents stays under ~1.1e15 — well inside `Int`.
        let span = (maxColumn - minColumn + 1) * (maxRow - minRow + 1)
        guard span <= entries.count * 2 else { return scanned(rect) }

        var seen = Set<UUID>(minimumCapacity: entries.count / 4)
        var matches: [(id: UUID, z: Double)] = []
        matches.reserveCapacity(entries.count / 4)
        for column in minColumn ... maxColumn {
            for row in minRow ... maxRow {
                guard let bucket = cells[Cell(column: column, row: row)] else { continue }
                for itemID in bucket where !seen.contains(itemID) {
                    guard let entry = entries[itemID], entry.frame.intersects(rect) else { continue }
                    seen.insert(itemID)
                    matches.append((itemID, entry.z))
                }
            }
        }
        return matches.sorted { $0.z < $1.z }.map(\.id)
    }

    /// Exact answer by testing every tile. The fallback when the bucket path cannot be used
    /// (huge offsets) *and* the chosen strategy when the query covers more cells than tiles.
    private func scanned(_ rect: CGRect) -> [UUID] {
        entries
            .filter { $0.value.frame.intersects(rect) }
            .sorted { $0.value.z < $1.value.z }
            .map(\.key)
    }

    /// World union of every tile — what "fit" and "reset" frame.
    var contentBounds: CGRect {
        guard let first = entries.values.first?.frame else { return .zero }
        return entries.values.dropFirst().reduce(first) { $0.union($1.frame) }
    }

    /// Buckets one frame. A tile straddling a cell border is registered in every cell it
    /// touches, which is why the query de-duplicates with `seen`.
    private func forEachCell(in frame: CGRect, _ body: (Cell) -> Void) {
        guard let firstColumn = cellIndex(frame.minX),
              let lastColumn = cellIndex(frame.maxX),
              let firstRow = cellIndex(frame.minY),
              let lastRow = cellIndex(frame.maxY) else { return }
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return }
        for column in firstColumn ... lastColumn {
            for row in firstRow ... lastRow {
                body(Cell(column: column, row: row))
            }
        }
    }

    /// Cell index for a world coordinate, or `nil` when it is not safely representable.
    ///
    /// `Int(_: Double)` traps on values outside `Int`'s range and is undefined for `NaN`, so a
    /// camera that wandered to infinity (or a corrupt row) must not reach it raw. The limit is
    /// ±16.7M cells — ±4.1e9 world points at the default pitch, i.e. four thousand times past
    /// `CanvasCamera.practicalExtent` — so a real board never falls back, and a junk one cannot
    /// crash the render loop.
    private func cellIndex(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let scaled = (value / cellSize).rounded(.down)
        guard scaled.magnitude < Double(Self.cellIndexLimit) else { return nil }
        return Int(scaled)
    }

    private static let cellIndexLimit: Double = 16_777_216  // 1 << 24 cells
}

// MARK: - Drag

/// Board-editing maths, kept pure so a drag can be asserted without a pointer.
enum CanvasDrag {
    /// Applies one drag delta to every moving tile.
    ///
    /// The delta is in **world** points (the view translation divided by zoom), so a drag
    /// feels the same at every zoom level and survives a mid-drag zoom precisely.
    ///
    /// - Parameter board: the containment rect, or `nil` for **no containment at all**.
    ///   Canvas keeps its board (±`CanvasLayout.boardExtent`, the area Reset Layout packs
    ///   into) so a tile cannot be dropped off the visible frame; Infinity passes `nil`, which
    ///   is the whole point of an edgeless board — a tile can live at x = 40 000.
    ///
    ///   The clamp uses the tile's real footprint, so "flush with the right edge" means the
    ///   *image* touches the edge, not the invisible square that used to surround it.
    static func positions(
        _ positions: [CanvasItemPosition],
        moving ids: Set<UUID>,
        byWorld delta: CGSize,
        board: CGRect? = CanvasLayout.boardRect
    ) -> [CanvasItemPosition] {
        guard !ids.isEmpty else { return positions }
        return positions.map { position in
            guard ids.contains(position.itemID) else { return position }
            let rawX = position.x + delta.width
            let rawY = position.y + delta.height
            guard let board else {
                // Unbounded: keep the result finite so the render and the row stay meaningful.
                return position.moved(
                    toX: rawX.isFinite ? rawX : position.x,
                    y: rawY.isFinite ? rawY : position.y
                )
            }
            let footprint = CanvasLayout.tileFrame(for: position)
            let nextX = min(board.maxX - footprint.width, max(board.minX, rawX))
            let nextY = min(board.maxY - footprint.height, max(board.minY, rawY))
            return position.moved(toX: nextX, y: nextY)
        }
    }

    /// Paint order for tiles being dragged: they move to the top and keep their relative
    /// order, so a multi-drag does not reshuffle the stack.
    static func restacked(_ positions: [CanvasItemPosition], lifting ids: Set<UUID>) -> [CanvasItemPosition] {
        let front = positions.enumerated()
            .filter { ids.contains($0.element.itemID) }
            .sorted { $0.offset < $1.offset }
            .map(\.element)
        guard !front.isEmpty else { return positions }

        let remaining = positions.filter { !ids.contains($0.itemID) }
        var nextZ = remaining.map(\.z).max() ?? 0
        var lifted: [CanvasItemPosition] = []
        for position in front {
            nextZ += 1
            lifted.append(
                CanvasItemPosition(
                    itemID: position.itemID,
                    x: position.x,
                    y: position.y,
                    z: nextZ,
                    scale: position.scale
                )
            )
        }
        return remaining + lifted
    }
}
