import CoreGraphics
import XCTest
@testable import AtlasOSSApp

/// Pure-logic coverage for the P1-A grid feel: density clamping, column math, decode
/// steps, pointer anchoring and selection/keyboard semantics.
final class GridFeelTests: XCTestCase {

    // MARK: - Density

    func testClampBoundsAndNonFiniteInput() {
        XCTAssertEqual(GridDensity.clamp(10), GridDensity.minCellWidth)
        XCTAssertEqual(GridDensity.clamp(10_000), GridDensity.maxCellWidth)
        XCTAssertEqual(GridDensity.clamp(180), 180)
        XCTAssertEqual(GridDensity.clamp(.nan), GridDensity.defaultCellWidth)
        XCTAssertTrue((GridDensity.minCellWidth ... GridDensity.maxCellWidth).contains(GridDensity.defaultCellWidth))
    }

    func testColumnsNeverDropsBelowOne() {
        XCTAssertEqual(GridDensity.columns(availableWidth: 0, cellWidth: 200), 1)
        XCTAssertEqual(GridDensity.columns(availableWidth: 40, cellWidth: 200), 1)
    }

    func testColumnsShrinkAsCellsGrow() {
        let wide = GridDensity.columns(availableWidth: 1000, cellWidth: 80)
        let narrow = GridDensity.columns(availableWidth: 1000, cellWidth: 360)
        XCTAssertGreaterThan(wide, narrow)
        XCTAssertEqual(GridDensity.columns(availableWidth: 1000, cellWidth: 200), 4)
    }

    func testGridWidthMatchesColumnCountExactly() {
        // Content width must be exact, otherwise LazyVGrid redistributes slack between
        // columns and the pointer anchor drifts.
        let width = GridDensity.gridWidth(columns: 3, cellWidth: 200)
        XCTAssertEqual(width, 200 * 3 + GridDensity.itemSpacing * 2)
        XCTAssertEqual(GridDensity.gridWidth(columns: 0, cellWidth: 200), 200)
    }

    func testThumbnailPixelSizeIsQuantisedAndMonotonic() {
        XCTAssertEqual(GridDensity.thumbnailPixelSize(cellWidth: GridDensity.minCellWidth), 180)
        XCTAssertEqual(GridDensity.thumbnailPixelSize(cellWidth: 200), 360)
        XCTAssertEqual(GridDensity.thumbnailPixelSize(cellWidth: GridDensity.maxCellWidth), GridDensity.decodeSteps.last)

        var previous = 0
        for width in stride(from: GridDensity.minCellWidth, through: GridDensity.maxCellWidth, by: 5) {
            let size = GridDensity.thumbnailPixelSize(cellWidth: width)
            XCTAssertGreaterThanOrEqual(size, previous)
            XCTAssertTrue(GridDensity.decodeSteps.contains(size))
            previous = size
        }
    }

    func testSteppedZoomIsClampedAndDirectional() {
        XCTAssertGreaterThan(GridDensity.stepped(200, delta: 10, precise: true), 200)
        XCTAssertLessThan(GridDensity.stepped(200, delta: -10, precise: true), 200)
        XCTAssertEqual(GridDensity.stepped(350, delta: 100, precise: true), GridDensity.maxCellWidth)
        XCTAssertEqual(GridDensity.stepped(90, delta: -100, precise: false), GridDensity.minCellWidth)
    }

    // MARK: - Pointer anchoring

    func testAnchorKeepsPointerOnSameSpotOfSameCell() {
        let id = UUID()
        let oldFrame = CGRect(x: 0, y: 100, width: 200, height: 200)
        let pointerY: CGFloat = 150          // 25% down the cell
        let anchor = GridAnchor(itemID: id, pointerY: pointerY, frame: oldFrame)

        XCTAssertEqual(anchor?.fraction ?? -1, 0.25, accuracy: 0.0001)

        // Density grew: the cell is now taller and has been pushed down the content.
        let newFrame = CGRect(x: 0, y: 380, width: 300, height: 300)
        let delta = anchor!.scrollDelta(pointerY: pointerY, newFrame: newFrame)
        XCTAssertEqual(delta, 380 - (150 - 0.25 * 300), accuracy: 0.0001)

        // Applying the delta puts the same fraction of the new cell under the pointer.
        let movedFrame = newFrame.offsetBy(dx: 0, dy: -delta)
        XCTAssertEqual(pointerY - movedFrame.minY, 0.25 * newFrame.height, accuracy: 0.0001)
    }

    func testAnchorTargetOffsetAddsToCurrentOffset() {
        let anchor = GridAnchor(itemID: UUID(), fraction: 0.5)
        let target = anchor.targetOffset(
            currentOffset: 120,
            pointerY: 300,
            newFrame: CGRect(x: 0, y: 200, width: 100, height: 100)
        )
        XCTAssertEqual(target, 120 + (200 - (300 - 50)), accuracy: 0.0001)
    }

    func testAnchorFractionClampsAndRejectsZeroHeight() {
        XCTAssertEqual(GridAnchor(itemID: UUID(), fraction: -3).fraction, 0)
        XCTAssertEqual(GridAnchor(itemID: UUID(), fraction: 4).fraction, 1)
        XCTAssertNil(GridAnchor(itemID: UUID(), pointerY: 10, frame: .zero))
    }

    func testAnchorHitTestPrefersContainingCell() {
        let a = UUID()
        let b = UUID()
        let frames: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 114, y: 0, width: 100, height: 100),
        ]
        let hit = GridAnchor.anchor(at: CGPoint(x: 160, y: 40), frames: frames)
        XCTAssertEqual(hit?.itemID, b)
        XCTAssertEqual(hit?.fraction ?? -1, 0.4, accuracy: 0.0001)

        // Inside the gutter: nearest cell wins, no crash on empty space.
        let gutter = GridAnchor.anchor(at: CGPoint(x: 107, y: 40), frames: frames)
        XCTAssertNotNil(gutter)
        XCTAssertNil(GridAnchor.anchor(at: .zero, frames: [:]))
    }

    // MARK: - Selection

    private let ids = (0 ..< 10).map { _ in UUID() }

    func testPlainClickReplacesSelection() {
        var selection = ItemSelection()
        selection.select(ids[3])
        XCTAssertEqual(selection.ids, [ids[3]])
        selection.select(ids[5])
        XCTAssertEqual(selection.ids, [ids[5]])
        XCTAssertEqual(selection.focusedID, ids[5])
        XCTAssertEqual(selection.anchorID, ids[5])
    }

    func testCommandClickToggles() {
        var selection = ItemSelection()
        selection.select(ids[1])
        selection.toggle(ids[4])
        XCTAssertEqual(selection.ids, [ids[1], ids[4]])
        selection.toggle(ids[1])
        XCTAssertEqual(selection.ids, [ids[4]])
        selection.toggle(ids[1])
        XCTAssertEqual(selection.ids, [ids[1], ids[4]])
    }

    func testShiftClickSelectsInclusiveRangeFromAnchor() {
        var selection = ItemSelection()
        selection.select(ids[2])
        selection.extend(to: ids[6], in: ids)
        XCTAssertEqual(selection.ids, Set(ids[2 ... 6]))
        XCTAssertEqual(selection.anchorID, ids[2])

        // Backwards range, still anchored at the original click.
        selection.extend(to: ids[0], in: ids)
        XCTAssertEqual(selection.ids, Set(ids[0 ... 2]))

        // Repeated ⇧-clicks re-derive from the same anchor.
        selection.extend(to: ids[4], in: ids)
        XCTAssertEqual(selection.ids, Set(ids[2 ... 4]))
    }

    func testShiftClickKeepsExtendingFromTheOriginClick() {
        var selection = ItemSelection()
        selection.select(ids[1])
        selection.extend(to: ids[3], in: ids)
        // The anchor is the original click, so a second ⇧-click grows the range.
        selection.extend(to: ids[7], in: ids)
        XCTAssertEqual(selection.ids, Set(ids[1 ... 7]))
        XCTAssertEqual(selection.anchorID, ids[1])
    }

    func testAdditiveShiftClickUnionsWithCommandPickedItems() {
        var selection = ItemSelection()
        selection.select(ids[1])
        selection.toggle(ids[8])
        XCTAssertEqual(selection.ids, [ids[1], ids[8]])

        // ⌘⇧-click adds the range without dropping the ⌘-picked far item.
        selection.extend(to: ids[9], in: ids, additive: true)
        XCTAssertEqual(selection.ids, [ids[1], ids[8], ids[9]])

        // Plain ⇧-click replaces with the range instead.
        selection.extend(to: ids[2], in: ids)
        XCTAssertEqual(selection.ids, Set(ids[2 ... 8]))
    }

    func testArrowKeysMoveByColumns() {
        var selection = ItemSelection()
        let columns = 4
        selection.select(ids[0])

        selection.move(.right, in: ids, columns: columns)
        XCTAssertEqual(selection.focusedID, ids[1])
        selection.move(.down, in: ids, columns: columns)
        XCTAssertEqual(selection.focusedID, ids[5])
        selection.move(.up, in: ids, columns: columns)
        XCTAssertEqual(selection.focusedID, ids[1])
        selection.move(.left, in: ids, columns: columns)
        XCTAssertEqual(selection.focusedID, ids[0])
    }

    func testArrowKeysClampInsteadOfWrapping() {
        var selection = ItemSelection()
        selection.select(ids[0])
        selection.move(.left, in: ids, columns: 4)
        XCTAssertEqual(selection.focusedID, ids[0])
        selection.move(.up, in: ids, columns: 4)
        XCTAssertEqual(selection.focusedID, ids[0])

        selection.select(ids[9])
        selection.move(.right, in: ids, columns: 4)
        XCTAssertEqual(selection.focusedID, ids[9])
        selection.move(.down, in: ids, columns: 4)
        XCTAssertEqual(selection.focusedID, ids[9])
    }

    func testShiftArrowExtendsSelectionFromTheLastPlainMove() {
        var selection = ItemSelection()
        selection.select(ids[0])
        selection.move(.right, in: ids, columns: 4)
        XCTAssertEqual(selection.focusedID, ids[1])

        selection.move(.right, in: ids, columns: 4, extending: true)
        XCTAssertEqual(selection.ids, Set(ids[1 ... 2]))

        // Repeated ⇧-arrows keep growing from the same anchor.
        selection.move(.right, in: ids, columns: 4, extending: true)
        XCTAssertEqual(selection.ids, Set(ids[1 ... 3]))
        XCTAssertEqual(selection.anchorID, ids[1])
    }

    func testSelectAllAndClear() {
        var selection = ItemSelection()
        selection.selectAll(ids)
        XCTAssertEqual(selection.count, ids.count)
        XCTAssertEqual(selection.focusedID, ids.first)
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.focusedID)
        XCTAssertNil(selection.anchorID)
    }

    func testPruneDropsVanishedItems() {
        var selection = ItemSelection()
        selection.selectAll(ids)
        selection.prune(to: Array(ids.prefix(3)))
        XCTAssertEqual(selection.ids, Set(ids[0 ... 2]))
        XCTAssertEqual(selection.focusedID, ids[0])

        selection.prune(to: [ids[9]])
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.focusedID)
        XCTAssertNil(selection.anchorID)
    }

    func testMoveOnEmptyListIsANoop() {
        var selection = ItemSelection()
        selection.move(.down, in: [], columns: 4)
        XCTAssertTrue(selection.isEmpty)
    }
}
