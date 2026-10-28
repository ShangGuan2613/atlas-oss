import AppKit
import AtlasCore
import CoreGraphics
import XCTest
@testable import AtlasOSSApp

/// P2-A app-layer coverage. Two halves, both without a window:
///
/// 1. **Pure board maths** — camera anchoring, culling, LOD, drag/restack. This is the part
///    that decides whether pan/zoom feels right, so it is asserted rather than eyeballed.
/// 2. **Board ↔ library integration** — seeding, appending, moving, resetting and surviving a
///    relaunch, driven through `LibraryModel` against a throwaway `.atlaslibrary`.
final class CanvasTests: XCTestCase {

    // MARK: - Camera

    private let camera = CanvasCamera(origin: CGPoint(x: -500, y: -400), zoom: 2)

    func testViewAndWorldRoundTrip() {
        let world = CGPoint(x: 120, y: -60)
        let view = camera.viewPoint(forWorld: world)
        XCTAssertEqual(view.x, (120 + 500) * 2, accuracy: 0.0001)
        XCTAssertEqual(view.y, (-60 + 400) * 2, accuracy: 0.0001)

        let back = camera.worldPoint(forView: view)
        XCTAssertEqual(back.x, world.x, accuracy: 0.0001)
        XCTAssertEqual(back.y, world.y, accuracy: 0.0001)
    }

    func testZoomKeepsTheWorldPointUnderThePointer() {
        let anchor = CGPoint(x: 300, y: 220)
        let before = camera.worldPoint(forView: anchor)

        let zoomedIn = camera.zoomed(by: 1.5, anchoredAt: anchor)
        let after = zoomedIn.worldPoint(forView: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)

        // And out again, back through the original zoom.
        let zoomedOut = zoomedIn.zoomed(by: 1 / 1.5, anchoredAt: anchor)
        XCTAssertEqual(zoomedOut.zoom, camera.zoom, accuracy: 0.0001)
        let restored = zoomedOut.worldPoint(forView: anchor)
        XCTAssertEqual(restored.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(restored.y, before.y, accuracy: 0.0001)
    }

    func testZoomIsClampedAndIgnoresJunkFactors() {
        XCTAssertEqual(camera.zoomed(by: 100, anchoredAt: .zero).zoom, CanvasCamera.maxZoom)
        XCTAssertEqual(camera.zoomed(by: 0.0001, anchoredAt: .zero).zoom, CanvasCamera.minZoom)
        XCTAssertEqual(camera.zoomed(by: 0, anchoredAt: .zero), camera)
        XCTAssertEqual(camera.zoomed(by: -2, anchoredAt: .zero), camera)
        XCTAssertEqual(camera.zoomed(by: .nan, anchoredAt: .zero), camera)
        XCTAssertEqual(CanvasCamera.clampZoom(.infinity), CanvasCamera.defaultZoom)
    }

    func testPanningMovesTheContentWithThePointer() {
        let panned = camera.panned(byViewDelta: CGSize(width: 40, height: -20))
        // Content follows the drag, so the camera origin moves the opposite way, in world units.
        XCTAssertEqual(panned.origin.x, camera.origin.x - 20, accuracy: 0.0001)
        XCTAssertEqual(panned.origin.y, camera.origin.y + 10, accuracy: 0.0001)
        XCTAssertEqual(panned.zoom, camera.zoom)
    }

    func testVisibleWorldRectCoversTheViewportPlusMargin() {
        let rect = camera.visibleWorldRect(viewport: CGSize(width: 1000, height: 600), margin: 100)
        // 1000/2 = 500 world points wide, plus 100 on each side.
        XCTAssertEqual(rect.width, 700, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 500, accuracy: 0.0001)
        XCTAssertEqual(rect.minX, camera.origin.x - 100, accuracy: 0.0001)
    }

    func testCameraCannotLoseTheBoard() {
        // P2-B: the grab-clamp is gone. A camera far past the board edge stays exactly where the
        // gesture put it…
        let viewport = CGSize(width: 900, height: 700)
        let board = CanvasLayout.boardRect
        let far = CanvasCamera(origin: CGPoint(x: 1_000_000, y: -1_000_000), zoom: 1).sanitized()
        XCTAssertEqual(far.origin.x, 1_000_000, accuracy: 0.0001)
        XCTAssertEqual(far.origin.y, -1_000_000, accuracy: 0.0001)
        XCTAssertFalse(
            far.shows(board, viewport: viewport),
            "unbounded pan is allowed to leave the board behind — that is the Infinity feature"
        )

        // …and Fit is the soft way back (no clamp involved).
        let fitted = CanvasCamera.fitting(content: board, viewport: viewport).sanitized()
        XCTAssertTrue(fitted.shows(board, viewport: viewport))
    }

    func testSanitisingBoundsJunkWithoutContainingTheCamera() {
        let junk = CanvasCamera(origin: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)).sanitized()
        XCTAssertEqual(junk.origin.x, 0)
        XCTAssertEqual(junk.origin.y, 0)
        XCTAssertEqual(junk.zoom, CanvasCamera.defaultZoom)

        // Absurd but finite: snapped to the practical extent, not to the board.
        let absurd = CanvasCamera(origin: CGPoint(x: 1e12, y: -1e12)).sanitized()
        XCTAssertEqual(absurd.origin.x, CanvasCamera.practicalExtent, accuracy: 0.0001)
        XCTAssertEqual(absurd.origin.y, -CanvasCamera.practicalExtent, accuracy: 0.0001)
        XCTAssertGreaterThan(CanvasCamera.practicalExtent, CanvasLayout.boardExtent)

        // Zoom still lives on the ladder.
        XCTAssertEqual(CanvasCamera(zoom: 1e-9).sanitized().zoom, CanvasCamera.minZoom)
    }

    func testZoomOutFloorFramesAWidelyScatteredBoard() {
        // 500 tiles scattered over 90 000 × 50 000 pt: Fit must frame them, so the overview
        // floor sits below the old 0.1 caption threshold.
        let scattered = CGRect(x: -45_000, y: -25_000, width: 90_000, height: 50_000)
        let viewport = CGSize(width: 1_400, height: 900)
        let fitted = CanvasCamera.fitting(content: scattered, viewport: viewport)
        XCTAssertLessThan(fitted.zoom, 0.1)
        XCTAssertGreaterThanOrEqual(fitted.zoom, CanvasCamera.minZoom)
        let rect = fitted.visibleWorldRect(viewport: viewport)
        XCTAssertTrue(rect.contains(CGPoint(x: scattered.minX, y: scattered.minY)))
        XCTAssertTrue(rect.contains(CGPoint(x: scattered.maxX, y: scattered.maxY)))

        // Past the documented ceiling Fit still *centres* rather than clipping: the middle of
        // a 1 000 000 pt board is on screen at the floor, and panning covers the rest.
        let huge = CGRect(x: -500_000, y: -500_000, width: 1_000_000, height: 1_000_000)
        let centred = CanvasCamera.fitting(content: huge, viewport: viewport)
        XCTAssertEqual(centred.zoom, CanvasCamera.minZoom, accuracy: 0.0001)
        XCTAssertTrue(centred.visibleWorldRect(viewport: viewport).contains(CGPoint.zero))
    }

    func testFittingCentresTheContent() {
        let content = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let fitted = CanvasCamera.fitting(content: content, viewport: CGSize(width: 1000, height: 600), padding: 0)
        let centre = fitted.worldPoint(forView: CGPoint(x: 500, y: 300))
        XCTAssertEqual(centre.x, content.midX, accuracy: 1)
        XCTAssertEqual(centre.y, content.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(fitted.zoom, CanvasCamera.maxZoom)
        XCTAssertGreaterThanOrEqual(fitted.zoom, CanvasCamera.minZoom)
    }

    func testFittingAnEmptyViewportIsANoop() {
        XCTAssertEqual(CanvasCamera.fitting(content: .zero, viewport: .zero), CanvasCamera())
    }

    // MARK: - LOD (P2-A Feel: decode rungs, not captions)

    func testLODDecodesAtTheRungTheTileNeeds() {
        // A 220 pt tile at 1× asks for 220 × 1.5 = 330 px → the 360 rung, same as the grid.
        XCTAssertEqual(CanvasLOD.decodePixelWidth(zoom: 1), ThumbnailStore.bucket(forMaxPixel: 330))
        XCTAssertEqual(CanvasLOD.decodePixelWidth(zoom: 1), 360)

        // The ladder has five rungs, so a full zoom sweep re-decodes at most five times per
        // tile — that is what keeps the (now cheap) camera move from becoming decode-bound.
        let rungs = Set(
            stride(from: CanvasCamera.minZoom, through: CanvasCamera.maxZoom, by: 0.01)
                .map { CanvasLOD.decodePixelWidth(zoom: $0) }
        )
        XCTAssertTrue(rungs.isSubset(of: Set(ThumbnailStore.bucketSizes)))
        XCTAssertLessThanOrEqual(rungs.count, ThumbnailStore.bucketSizes.count)

        // Monotone with zoom; junk zooms answer a sane rung instead of trapping.
        let ladder = [0.05, 0.25, 0.5, 1, 2, 4].map { CanvasLOD.decodePixelWidth(zoom: $0) }
        XCTAssertEqual(ladder, ladder.sorted())
        XCTAssertEqual(CanvasLOD.decodePixelWidth(zoom: .nan), ThumbnailStore.defaultMaxPixel)
        XCTAssertEqual(CanvasLOD.decodePixelWidth(zoom: 0), ThumbnailStore.defaultMaxPixel)

        // A tile scaled up *on the board* decodes bigger, exactly like zooming into it.
        XCTAssertGreaterThan(
            CanvasLOD.decodePixelWidth(scale: 2, zoom: 1),
            CanvasLOD.decodePixelWidth(scale: 1, zoom: 1)
        )
    }

    // MARK: - Single layer transform (P2-A Feel)

    /// The invariant the whole render rewrite rests on: one container transform has to agree
    /// with the per-point camera maths the culling, the zoom anchor and the drag all use.
    func testLayerTransformIsTheCameraHoistedOutOfTheLoop() {
        let cameras = [
            CanvasCamera(origin: .zero, zoom: 1),
            CanvasCamera(origin: CGPoint(x: -500, y: -400), zoom: 2),
            CanvasCamera(origin: CGPoint(x: 39_000, y: -12_345.5), zoom: 0.37),
            CanvasCamera(origin: CGPoint(x: 950_000, y: -950_000), zoom: 0.05),
        ]
        let worlds = [
            CGPoint.zero,
            CGPoint(x: 220, y: 165),
            CGPoint(x: -40_000, y: 12_000),
            CGPoint(x: 950_040, y: -949_960),
        ]

        for camera in cameras {
            let layer = camera.layerTransform
            XCTAssertEqual(layer.scale, camera.zoom)
            for world in worlds {
                let hoisted = layer.viewPoint(forWorld: world)
                let direct = camera.viewPoint(forWorld: world)
                XCTAssertEqual(hoisted.x, direct.x, accuracy: 0.0001, "camera \(camera) world \(world)")
                XCTAssertEqual(hoisted.y, direct.y, accuracy: 0.0001, "camera \(camera) world \(world)")
            }
        }
    }

    /// The AppKit board and the pointer share one matrix: world → view, then the inverse back.
    /// A round-trip that drifts is the cursor-misalignment bug with a different host.
    func testCameraMatrixRoundTripsWorldAndView() {
        let cameras = [
            CanvasCamera(origin: .zero, zoom: 1),
            CanvasCamera(origin: CGPoint(x: -500, y: -400), zoom: 2),
            CanvasCamera(origin: CGPoint(x: 120, y: -80), zoom: 0.5),
            CanvasCamera(origin: CGPoint(x: 39_000, y: -12_345.5), zoom: 0.37),
        ]
        let worlds = [
            CGPoint.zero,
            CGPoint(x: 220, y: 165),
            CGPoint(x: -4_000, y: 1_200),
            CGPoint(x: 40_220, y: -12_180),
        ]
        for camera in cameras {
            let matrix = camera.viewTransform
            let inverse = matrix.inverted()
            XCTAssertFalse(inverse.isIdentity && camera.zoom != 1, "zoom \(camera.zoom) must invert")
            for world in worlds {
                let view = world.applying(matrix)
                let direct = camera.viewPoint(forWorld: world)
                XCTAssertEqual(view.x, direct.x, accuracy: 0.001)
                XCTAssertEqual(view.y, direct.y, accuracy: 0.001)
                let back = view.applying(inverse)
                XCTAssertEqual(back.x, world.x, accuracy: 0.001)
                XCTAssertEqual(back.y, world.y, accuracy: 0.001)
                let viaCamera = camera.worldPoint(forView: view)
                XCTAssertEqual(viaCamera.x, world.x, accuracy: 0.001)
                XCTAssertEqual(viaCamera.y, world.y, accuracy: 0.001)
            }
        }
    }

    /// The visible world rect must land exactly on the viewport after the single transform —
    /// otherwise "pointer-anchored zoom" would anchor to a point the user is not looking at.
    func testLayerTransformMapsTheVisibleRectOntoTheViewport() {
        let camera = CanvasCamera(origin: CGPoint(x: -320, y: 96), zoom: 1.75)
        let viewport = CGSize(width: 1_000, height: 700)
        let layer = camera.layerTransform
        let rect = camera.visibleWorldRect(viewport: viewport)

        let topLeft = layer.viewPoint(forWorld: CGPoint(x: rect.minX, y: rect.minY))
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.0001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.0001)
        let bottomRight = layer.viewPoint(forWorld: CGPoint(x: rect.maxX, y: rect.maxY))
        XCTAssertEqual(bottomRight.x, viewport.width, accuracy: 0.0001)
        XCTAssertEqual(bottomRight.y, viewport.height, accuracy: 0.0001)
    }

    /// The geometry fix, pinned to the thing the eye compares it against: the grid.
    func testBoardTileFootprintIsTheDrawnTile() {
        XCTAssertEqual(CanvasLayout.tileAspect, GridDensity.thumbnailAspect)
        XCTAssertEqual(CanvasLayout.tileWidth, CanvasLayout.tileSize, accuracy: 0.0001)
        XCTAssertEqual(
            CanvasLayout.tileHeight,
            CanvasLayout.tileSize * GridDensity.thumbnailAspect,
            accuracy: 0.0001
        )

        // A tile drawn by `ItemCell` at its world width is exactly the footprint the board
        // packs, culls and clamps to — no 55 pt of empty square, no caption overhang.
        let frame = CanvasLayout.tileFrame(x: 40, y: -10)
        let drawnHeight = GridDensity.thumbnailHeight(cellWidth: CanvasLayout.tileWidth)
        XCTAssertEqual(frame.height, drawnHeight, accuracy: 0.0001)
        XCTAssertEqual(frame.width, CanvasLayout.tileWidth, accuracy: 0.0001)
    }

    func testCaptionBudgetIsOptIn() {
        let bare = CanvasLayout.tileFrame(x: 0, y: 0)
        let labelled = CanvasLayout.tileFrame(x: 0, y: 0, captions: true)
        XCTAssertEqual(bare.height, CanvasLayout.tileHeight, accuracy: 0.0001)
        XCTAssertEqual(labelled.height - bare.height, CanvasLayout.captionHeight, accuracy: 0.0001)
    }

    func testDragClampUsesTheRealFootprint() {
        let board = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let tile = CanvasItemPosition(itemID: UUID(), x: 0, y: 0)
        let pushed = CanvasDrag.positions(
            [tile],
            moving: [tile.itemID],
            byWorld: CGSize(width: 5_000, height: 5_000),
            board: board
        )
        // Flush means the *image* touches the edge…
        let frame = CanvasLayout.tileFrame(for: pushed[0])
        XCTAssertEqual(frame.maxX, board.maxX, accuracy: 0.0001)
        XCTAssertEqual(frame.maxY, board.maxY, accuracy: 0.0001)
        // …not the invisible square P2-A clamped to: the tile now sits 55 pt *lower*, with its
        // image flush to the board edge instead of leaving a phantom band below it.
        XCTAssertGreaterThan(pushed[0].y, board.maxY - CanvasLayout.tileSize)
    }

    func testIndexBucketsTheAspectFootprint() {
        let tile = CanvasItemPosition(itemID: UUID(), x: 0, y: 0)
        let index = CanvasSpatialIndex(positions: [tile])

        XCTAssertEqual(index.contentBounds.width, CanvasLayout.tileWidth, accuracy: 0.0001)
        XCTAssertEqual(index.contentBounds.height, CanvasLayout.tileHeight, accuracy: 0.0001)

        // The band a square footprint used to claim (below the image) is empty now, so a query
        // there does not realise a tile nothing is drawn in.
        XCTAssertTrue(index.itemIDs(in: CGRect(x: 0, y: 166, width: 100, height: 40)).isEmpty)
        XCTAssertFalse(index.itemIDs(in: CGRect(x: 0, y: 160, width: 100, height: 40)).isEmpty)
    }

    // MARK: - Culling

    private func makePositions(count: Int) -> [CanvasItemPosition] {
        (0 ..< count).map { index in
            CanvasItemPosition(
                itemID: UUID(),
                x: Double(index % 10) * CanvasLayout.pitchX,
                y: Double(index / 10) * CanvasLayout.pitchY,
                z: Double(index)
            )
        }
    }

    func testIndexMatchesBruteForce() {
        let positions = makePositions(count: 120)
        let index = CanvasSpatialIndex(positions: positions)

        let probes = [
            CGRect(x: -10, y: -10, width: 300, height: 300),
            CGRect(x: 0, y: 0, width: 5000, height: 5000),
            CGRect(x: 900, y: 240, width: 600, height: 250),
            CGRect(x: 20_000, y: 20_000, width: 100, height: 100),
        ]

        for probe in probes {
            let expected = positions
                .filter { position in
                    CanvasLayout.tileFrame(for: position).intersects(probe)
                }
                .sorted { $0.z < $1.z }
                .map(\.itemID)

            XCTAssertEqual(index.itemIDs(in: probe), expected, "probe \(probe)")
        }
    }

    func testIndexCullsMostOfALargeBoard() {
        let positions = makePositions(count: 400)
        let index = CanvasSpatialIndex(positions: positions)
        XCTAssertEqual(index.count, 400)

        // One screen at the default zoom: a handful of tiles, not 400.
        let visible = index.itemIDs(in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertFalse(visible.isEmpty)
        XCTAssertLessThan(visible.count, 40, "culling should realise a viewport, not the board")
    }

    func testIndexIsEmptyForAnEmptyBoardOrEmptyRect() {
        let index = CanvasSpatialIndex(positions: [])
        XCTAssertTrue(index.isEmpty)
        XCTAssertTrue(index.itemIDs(in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)

        let populated = CanvasSpatialIndex(positions: makePositions(count: 4))
        XCTAssertTrue(populated.itemIDs(in: .zero).isEmpty)
    }

    // MARK: - Infinity-scale culling (P2-B)

    /// Tiles a long way from the origin, as Infinity allows: same index, same answers.
    private func makeFarPositions(count: Int, originX: Double = 900_000, originY: Double = -900_000) -> [CanvasItemPosition] {
        (0 ..< count).map { index in
            CanvasItemPosition(
                itemID: UUID(),
                x: originX + Double(index % 10) * CanvasLayout.pitchX,
                y: originY + Double(index / 10) * CanvasLayout.pitchY,
                z: Double(index)
            )
        }
    }

    func testIndexCullsCorrectlyAtInfinityOffsets() {
        let positions = makeFarPositions(count: 200)
        let index = CanvasSpatialIndex(positions: positions)
        XCTAssertEqual(index.count, 200)

        for probe in [
            CGRect(x: 899_000, y: -901_000, width: 1_200, height: 800),
            CGRect(x: 901_000, y: -899_000, width: 600, height: 400),
            CGRect(x: 0, y: 0, width: 1_200, height: 800),
        ] {
            let expected = positions
                .filter { position in
                    CanvasLayout.tileFrame(for: position).intersects(probe)
                }
                .sorted { $0.z < $1.z }
                .map(\.itemID)
            XCTAssertEqual(index.itemIDs(in: probe), expected, "probe \(probe)")
        }

        // Content bounds stay exact a million points out, which is what Fit frames.
        let bounds = index.contentBounds
        XCTAssertEqual(bounds.minX, 900_000, accuracy: 0.0001)
        XCTAssertEqual(bounds.minY, -900_000, accuracy: 0.0001)
    }

    func testIndexSurvivesCoordinatesACellIndexCannotHold() {
        let index = CanvasSpatialIndex(positions: makePositions(count: 20))

        // `Int(_: Double)` traps outside `Int`'s range, so these must go down the scan path
        // rather than crashing the render loop.
        XCTAssertTrue(index.itemIDs(in: CGRect(x: 1e15, y: 1e15, width: 100, height: 100)).isEmpty)
        XCTAssertTrue(index.itemIDs(in: CGRect(x: -1e300, y: -1e300, width: 100, height: 100)).isEmpty)
        XCTAssertTrue(index.itemIDs(in: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)).isEmpty)
        XCTAssertTrue(index.itemIDs(in: CGRect(x: 0, y: Double.infinity, width: 100, height: 100)).isEmpty)

        // A rect that does overlap still answers exactly.
        XCTAssertFalse(index.itemIDs(in: CGRect(x: -10, y: -10, width: 260, height: 260)).isEmpty)
    }

    func testContentBoundsUnionsEveryTile() {
        let positions = makePositions(count: 12)
        let bounds = CanvasSpatialIndex(positions: positions).contentBounds
        let expectedMaxX = positions.map(\.x).max()! + CanvasLayout.tileWidth
        XCTAssertEqual(bounds.maxX, expectedMaxX, accuracy: 0.0001)
        XCTAssertEqual(
            bounds.maxY,
            positions.map(\.y).max()! + CanvasLayout.tileHeight,
            accuracy: 0.0001
        )
    }

    // MARK: - Drag

    func testDragMovesOnlyTheSelectedTiles() {
        let positions = makePositions(count: 4)
        let moving: Set<UUID> = [positions[1].itemID, positions[3].itemID]
        let moved = CanvasDrag.positions(positions, moving: moving, byWorld: CGSize(width: 50, height: -30))

        for (index, position) in moved.enumerated() {
            if moving.contains(position.itemID) {
                XCTAssertEqual(position.x, positions[index].x + 50, accuracy: 0.0001)
                XCTAssertEqual(position.y, positions[index].y - 30, accuracy: 0.0001)
            } else {
                XCTAssertEqual(position.x, positions[index].x, accuracy: 0.0001)
                XCTAssertEqual(position.y, positions[index].y, accuracy: 0.0001)
            }
        }
    }

    func testDragKeepsTilesInsideTheBoard() {
        let board = CGRect(x: -100, y: -100, width: 300, height: 300)
        let inside = CanvasItemPosition(itemID: UUID(), x: 0, y: 0)
        let pushed = CanvasDrag.positions(
            [inside],
            moving: [inside.itemID],
            byWorld: CGSize(width: 10_000, height: -10_000),
            board: board
        )
        XCTAssertEqual(pushed[0].x, board.maxX - CanvasLayout.tileSize, accuracy: 0.0001)
        XCTAssertEqual(pushed[0].y, board.minY, accuracy: 0.0001)
    }

    func testInfinityDragHasNoContainment() {
        let tile = CanvasItemPosition(itemID: UUID(), x: 0, y: 0)
        let far = CanvasDrag.positions(
            [tile],
            moving: [tile.itemID],
            byWorld: CGSize(width: 250_000, height: -250_000),
            board: nil
        )
        XCTAssertEqual(far[0].x, 250_000, accuracy: 0.0001)
        XCTAssertEqual(far[0].y, -250_000, accuracy: 0.0001)

        // Still refuses to write a coordinate no render can draw.
        let junk = CanvasDrag.positions(
            [tile],
            moving: [tile.itemID],
            byWorld: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
            board: nil
        )
        XCTAssertEqual(junk[0].x, 0)
        XCTAssertEqual(junk[0].y, 0)
    }

    func testMultiDragRestacksTheMovedTilesInOrder() {
        let positions = makePositions(count: 5)
        let lifted: Set<UUID> = [positions[0].itemID, positions[2].itemID]
        let restacked = CanvasDrag.restacked(positions, lifting: lifted)

        // Untouched tiles keep their order, lifted ones sit on top in their original order.
        XCTAssertEqual(restacked.count, positions.count)
        let untouched: [UUID] = restacked.map(\.itemID).filter { !lifted.contains($0) }
        XCTAssertEqual(untouched, [positions[1].itemID, positions[3].itemID, positions[4].itemID])
        let onTop: [UUID] = Array(restacked.suffix(2)).map(\.itemID)
        XCTAssertEqual(onTop, [positions[0].itemID, positions[2].itemID])
        XCTAssertLessThan(restacked[2].z, restacked[3].z)
        XCTAssertLessThan(restacked[3].z, restacked[4].z)
    }

    func testRestackWithNothingLiftedIsANoop() {
        let positions = makePositions(count: 3)
        XCTAssertEqual(CanvasDrag.restacked(positions, lifting: []), positions)
    }

    func testDragDeltaIsZoomIndependent() {
        let atOne = CanvasCamera(zoom: 1).worldDelta(forViewTranslation: CGSize(width: 100, height: 50))
        let atTwo = CanvasCamera(zoom: 2).worldDelta(forViewTranslation: CGSize(width: 100, height: 50))
        XCTAssertEqual(atOne.width, 100, accuracy: 0.0001)
        XCTAssertEqual(atTwo.width, 50, accuracy: 0.0001)
        XCTAssertEqual(atTwo.height, 25, accuracy: 0.0001)
    }

    // MARK: - View mode

    func testViewModeOffersAllThreePillars() {
        XCTAssertEqual(ViewMode.selectable, [.grid, .canvas, .infinity])
        XCTAssertEqual(ViewMode.infinity.shortcutKey, "3")
        XCTAssertTrue(ViewMode.canvas.usesBoard)
        XCTAssertTrue(ViewMode.infinity.usesBoard)
        XCTAssertFalse(ViewMode.grid.usesBoard)
    }

    func testPersistedModeRoundTripsAndJunkFallsBackToGrid() {
        XCTAssertEqual(ViewMode.resolved("canvas"), .canvas)
        XCTAssertEqual(ViewMode.resolved("grid"), .grid)
        // P2-B: Infinity is a real storable value now.
        XCTAssertEqual(ViewMode.resolved("infinity"), .infinity)
        // A future/unknown value must never leave the pane blank.
        XCTAssertEqual(ViewMode.resolved("nonsense"), .grid)
    }

    // MARK: - Board ↔ library integration

    private var workspace: URL!
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-canvas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        libraryRoot = workspace.appendingPathComponent("main.atlaslibrary", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let workspace,
           workspace.path.hasPrefix(FileManager.default.temporaryDirectory.path),
           workspace.lastPathComponent.hasPrefix("atlasoss-canvas-") {
            try? FileManager.default.removeItem(at: workspace)
        }
        try super.tearDownWithError()
    }

    /// Imports `count` distinct PNGs into a fresh library and opens a model on it.
    @MainActor
    private func makeModel(itemCount: Int) throws -> LibraryModel {
        let folder = workspace.appendingPathComponent("shots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..< itemCount {
            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            for x in 0 ..< 4 {
                for y in 0 ..< 4 {
                    image.setColor(
                        NSColor(red: CGFloat(x) / 4, green: CGFloat(index) / max(1, CGFloat(itemCount)), blue: CGFloat(y) / 4, alpha: 1),
                        atX: x, y: y
                    )
                }
            }
            try image.representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("shot-\(index).png"))
        }

        let seed = try AtlasLibrary(url: libraryRoot)
        _ = try seed.importFolder(folder, mode: .connected)
        seed.close()

        let model = LibraryModel()
        model.open(at: libraryRoot)
        XCTAssertNil(model.loadError, "open failed: \(model.loadError ?? "")")
        return model
    }

    @MainActor
    func testFirstCanvasOpenSeedsAPackedLayout() throws {
        let model = try makeModel(itemCount: 6)
        model.select(.all)
        model.reloadCanvasPositions()

        XCTAssertEqual(model.canvasScope, .all)
        XCTAssertEqual(model.canvasPositions.count, 6)

        // Packed, centred, same order as the grid, and no two tiles on top of each other.
        let expected = CanvasLayout.placements(forItemIDs: model.items.map(\.id))
        XCTAssertEqual(model.canvasPositions.map(\.itemID), expected.map(\.itemID))
        let frames = model.canvasPositions.map { CanvasLayout.tileFrame(for: $0) }
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                XCTAssertFalse(frame.intersects(other), "packed tiles must not overlap")
            }
        }
        XCTAssertEqual(model.canvasContentBounds.midX, 0, accuracy: 1)
    }

    @MainActor
    func testSeededLayoutIsStableAcrossLaunches() throws {
        let first = try makeModel(itemCount: 5)
        first.select(.all)
        first.reloadCanvasPositions()
        let original = first.canvasPositions
        XCTAssertEqual(original.count, 5)

        let reopened = LibraryModel()
        reopened.open(at: libraryRoot)
        reopened.select(.all)
        reopened.reloadCanvasPositions()

        XCTAssertEqual(reopened.canvasPositions.map(\.itemID), original.map(\.itemID))
        XCTAssertEqual(reopened.canvasPositions.map(\.x), original.map(\.x))
        XCTAssertEqual(reopened.canvasPositions.map(\.y), original.map(\.y))
    }

    @MainActor
    func testDraggingATilePersistsAndLiftsItToTheFront() throws {
        let model = try makeModel(itemCount: 4)
        model.select(.all)
        model.reloadCanvasPositions()

        let target = model.canvasPositions[0]
        let before = Dictionary(uniqueKeysWithValues: model.canvasPositions.map { ($0.itemID, $0) })

        model.moveCanvasItems([target.itemID], byWorld: CGSize(width: 320, height: -180))

        let after = Dictionary(uniqueKeysWithValues: model.canvasPositions.map { ($0.itemID, $0) })
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after[target.itemID]!.x, before[target.itemID]!.x + 320, accuracy: 0.0001)
        XCTAssertEqual(after[target.itemID]!.y, before[target.itemID]!.y - 180, accuracy: 0.0001)
        // The dragged tile is now painted last.
        XCTAssertEqual(model.canvasPositions.last?.itemID, target.itemID)
        // Everything else stayed put.
        for (id, position) in before where id != target.itemID {
            XCTAssertEqual(after[id]!.x, position.x, accuracy: 0.0001)
            XCTAssertEqual(after[id]!.y, position.y, accuracy: 0.0001)
        }
    }

    @MainActor
    func testMultiSelectionDragMovesEveryTileByTheSameDelta() throws {
        let model = try makeModel(itemCount: 4)
        model.select(.all)
        model.reloadCanvasPositions()

        let ids = Set(model.canvasPositions.prefix(2).map(\.itemID))
        let before = Dictionary(uniqueKeysWithValues: model.canvasPositions.map { ($0.itemID, $0) })
        model.moveCanvasItems(ids, byWorld: CGSize(width: 60, height: 90))
        let after = Dictionary(uniqueKeysWithValues: model.canvasPositions.map { ($0.itemID, $0) })

        for id in ids {
            XCTAssertEqual(after[id]!.x, before[id]!.x + 60, accuracy: 0.0001)
            XCTAssertEqual(after[id]!.y, before[id]!.y + 90, accuracy: 0.0001)
        }
    }

    @MainActor
    func testMoveIsPersistedForTheNextLaunch() throws {
        let model = try makeModel(itemCount: 3)
        model.select(.all)
        model.reloadCanvasPositions()
        let target = model.canvasPositions[1].itemID
        model.moveCanvasItems([target], byWorld: CGSize(width: 500, height: 500))
        let expected = model.canvasPositions.first { $0.itemID == target }!

        let reopened = LibraryModel()
        reopened.open(at: libraryRoot)
        reopened.select(.all)
        reopened.reloadCanvasPositions()
        let restored = reopened.canvasPositions.first { $0.itemID == target }
        XCTAssertEqual(restored?.x ?? .nan, expected.x, accuracy: 0.0001)
        XCTAssertEqual(restored?.y ?? .nan, expected.y, accuracy: 0.0001)
    }

    @MainActor
    func testResetLayoutRepacksAfterAManualScatter() throws {
        let model = try makeModel(itemCount: 5)
        model.select(.all)
        model.reloadCanvasPositions()
        let gridOrder = model.items.map(\.id)

        for (index, id) in gridOrder.enumerated() {
            model.moveCanvasItems([id], byWorld: CGSize(width: Double(index) * 400, height: Double(index) * 250))
        }
        XCTAssertNotEqual(model.canvasPositions.map(\.x), CanvasLayout.placements(forItemIDs: gridOrder).map(\.x))

        let bounds = model.resetCanvasLayout()
        // Back to the packed grid, framed by the returned content bounds.
        XCTAssertEqual(model.canvasPositions.map(\.itemID), gridOrder)
        XCTAssertEqual(model.canvasPositions.map(\.x), CanvasLayout.placements(forItemIDs: gridOrder).map(\.x))
        XCTAssertEqual(bounds.midX, 0, accuracy: 1)
    }

    @MainActor
    func testEachCollectionKeepsItsOwnBoard() throws {
        let model = try makeModel(itemCount: 3)
        model.select(.all)
        model.reloadCanvasPositions()
        let allBoard = model.canvasPositions
        XCTAssertEqual(allBoard.count, 3)

        // The import created a "shots" collection holding the same three items.
        let collectionID = try XCTUnwrap(model.tree.first { $0.name == "shots" }?.id)
        model.select(.collection(collectionID))
        model.reloadCanvasPositions()

        XCTAssertEqual(model.canvasScope, .collection(collectionID))
        XCTAssertEqual(model.canvasPositions.count, 3)
        // Its own packed board, unaffected by the All board's coordinates.
        XCTAssertEqual(model.canvasPositions.map(\.itemID), model.items.map(\.id))

        // A drag on the collection board leaves the All board alone.
        let movedID = model.canvasPositions[0].itemID
        let beforeAll = allBoard.first { $0.itemID == movedID }!
        model.moveCanvasItems([movedID], byWorld: CGSize(width: 700, height: 700))

        model.select(.all)
        model.reloadCanvasPositions()
        let afterAll = model.canvasPositions.first { $0.itemID == movedID }!
        XCTAssertEqual(afterAll.x, beforeAll.x, accuracy: 0.0001)
        XCTAssertEqual(afterAll.y, beforeAll.y, accuracy: 0.0001)
    }

    @MainActor
    func testTagViewDrawsTheAllBoard() throws {
        let model = try makeModel(itemCount: 2)
        model.select(.all)
        model.reloadCanvasPositions()
        let allBoard = model.canvasPositions

        let tagID = try XCTUnwrap(model.library).createTag(name: "red")
        model.select(.tag(tagID))
        model.reloadCanvasPositions()

        XCTAssertEqual(model.canvasScope, .all)
        // The tag filters items; it does not own a third layout.
        XCTAssertEqual(Set(model.canvasPositions.map(\.itemID)).count, allBoard.count)
    }

    @MainActor
    func testNewImportIsAppendedWithoutMovingExistingTiles() throws {
        let model = try makeModel(itemCount: 3)
        model.select(.all)
        model.reloadCanvasPositions()
        let before = Dictionary(uniqueKeysWithValues: model.canvasPositions.map { ($0.itemID, $0) })

        // Import one more file, then reload the way the pane does.
        let extra = workspace.appendingPathComponent("more", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for x in 0 ..< 4 {
            for y in 0 ..< 4 {
                image.setColor(NSColor(red: 0.1, green: CGFloat(x + y) / 8, blue: 0.9, alpha: 1), atX: x, y: y)
            }
        }
        try image.representation(using: .png, properties: [:])!
            .write(to: extra.appendingPathComponent("new.png"))
        _ = try XCTUnwrap(model.library).importFolder(extra, mode: .connected)

        // The capture funnel calls `reloadAll()` after an import; mirror that here.
        model.reloadAll()
        model.reloadCanvasPositions()

        XCTAssertEqual(model.canvasPositions.count, 4)
        for (id, position) in before {
            let now = model.canvasPositions.first { $0.itemID == id }
            XCTAssertEqual(now?.x ?? .nan, position.x, accuracy: 0.0001)
            XCTAssertEqual(now?.y ?? .nan, position.y, accuracy: 0.0001)
        }
        // The new tile landed below the existing block, not on top of it.
        let maxY = before.values.map(\.y).max()!
        let newTile = model.canvasPositions.first { before[$0.itemID] == nil }
        XCTAssertGreaterThan(newTile?.y ?? -.infinity, maxY)
    }

    // MARK: - Infinity shares the Canvas board (P2-B acceptance)

    @MainActor
    func testInfinityDragLeavesTheBoardAndCanvasStillSeesTheTile() throws {
        let model = try makeModel(itemCount: 5)
        model.select(.all)
        model.reloadCanvasPositions()
        let target = model.canvasPositions[0].itemID

        // Canvas first: an absurd drag is contained by the board (P2-A rule, still true).
        model.moveCanvasItems([target], byWorld: CGSize(width: 400_000, height: 400_000), bounded: true)
        let bounded = try XCTUnwrap(model.canvasPositions.first { $0.itemID == target })
        XCTAssertLessThanOrEqual(bounded.x, CanvasLayout.boardExtent)
        XCTAssertLessThanOrEqual(bounded.y, CanvasLayout.boardExtent)

        // Infinity: no containment at all — the tile really is out there.
        model.moveCanvasItems([target], byWorld: CGSize(width: 40_000, height: 40_000), bounded: false)
        let far = try XCTUnwrap(model.canvasPositions.first { $0.itemID == target })
        XCTAssertGreaterThan(far.x, CanvasLayout.boardExtent)
        XCTAssertGreaterThan(far.y, CanvasLayout.boardExtent)

        // …and it is the *same row* the Canvas reads: one board, two cameras.
        XCTAssertEqual(model.canvasScope, .all)
        let bounds = model.canvasContentBounds
        XCTAssertTrue(bounds.contains(CGPoint(x: far.x, y: far.y)))

        let viewport = CGSize(width: 1_200, height: 800)
        let fitted = CanvasCamera.fitting(content: bounds, viewport: viewport)
        XCTAssertTrue(
            fitted.visibleWorldRect(viewport: viewport).contains(CGPoint(x: far.x, y: far.y)),
            "Fit must frame a tile Infinity placed past the old board edge"
        )
        // The unbounded camera can also just pan there.
        let panned = CanvasCamera(origin: CGPoint(x: far.x, y: far.y), zoom: 1).sanitized()
        XCTAssertTrue(panned.shows(CGRect(origin: CGPoint(x: far.x, y: far.y), size: CGSize(width: 220, height: 220)), viewport: viewport))

        // Survives relaunch exactly like a Canvas move: same table, same rows.
        let reopened = LibraryModel()
        reopened.open(at: libraryRoot)
        reopened.select(.all)
        reopened.reloadCanvasPositions()
        let restored = try XCTUnwrap(reopened.canvasPositions.first { $0.itemID == target })
        XCTAssertEqual(restored.x, far.x, accuracy: 0.0001)
        XCTAssertEqual(restored.y, far.y, accuracy: 0.0001)
    }

    @MainActor
    func testInfinityAndCanvasAddressTheSameRowsForACollection() throws {
        let model = try makeModel(itemCount: 3)
        let collectionID = try XCTUnwrap(model.tree.first { $0.name == "shots" }?.id)
        model.select(.collection(collectionID))
        model.reloadCanvasPositions()
        let target = model.canvasPositions[0].itemID

        // Move with Infinity's unclamped maths…
        model.moveCanvasItems([target], byWorld: CGSize(width: -30_000, height: 12_000), bounded: false)
        let infinityPosition = try XCTUnwrap(model.canvasPositions.first { $0.itemID == target })

        // …reload the way a mode switch does, and Canvas reads the same coordinate.
        model.reloadCanvasPositions()
        let afterSwitch = try XCTUnwrap(model.canvasPositions.first { $0.itemID == target })
        XCTAssertEqual(afterSwitch.x, infinityPosition.x, accuracy: 0.0001)
        XCTAssertEqual(afterSwitch.y, infinityPosition.y, accuracy: 0.0001)
        XCTAssertEqual(model.canvasScope, .collection(collectionID))

        // The All board is untouched: Infinity does not invent a third layout.
        model.select(.all)
        model.reloadCanvasPositions()
        let allBoardRow = try XCTUnwrap(model.canvasPositions.first { $0.itemID == target })
        XCTAssertNotEqual(allBoardRow.x, infinityPosition.x)
    }
}
