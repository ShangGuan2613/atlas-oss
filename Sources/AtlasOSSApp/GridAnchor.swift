import CoreGraphics
import Foundation

/// Pointer-anchored zoom.
///
/// Before the layout changes we remember which cell is under the cursor and where
/// inside it the cursor sits (0 = top edge, 1 = bottom edge). Once the new layout has
/// been measured we know that cell's fresh frame, so the scroll delta that puts the
/// cursor back on the same spot of the same cell is:
///
///     delta = newFrame.minY - (pointerY - fraction * newFrame.height)
///
/// Frames and the cursor both live in the grid's viewport coordinate space (they move
/// with scrolling), so no content-space bookkeeping is needed.
struct GridAnchor: Equatable {
    let itemID: UUID
    /// Cursor position inside the anchor cell, clamped to 0…1.
    let fraction: CGFloat

    init(itemID: UUID, fraction: CGFloat) {
        self.itemID = itemID
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0.5))
    }

    init?(itemID: UUID, pointerY: CGFloat, frame: CGRect) {
        guard frame.height > 0 else { return nil }
        self.init(itemID: itemID, fraction: (pointerY - frame.minY) / frame.height)
    }

    /// How far the content must move for the anchor point to stay under the cursor.
    func scrollDelta(pointerY: CGFloat, newFrame: CGRect) -> CGFloat {
        newFrame.minY - (pointerY - fraction * newFrame.height)
    }

    func targetOffset(currentOffset: CGFloat, pointerY: CGFloat, newFrame: CGRect) -> CGFloat {
        currentOffset + scrollDelta(pointerY: pointerY, newFrame: newFrame)
    }

    // MARK: - Hit testing

    /// Picks the anchor for a pointer position: the cell containing it, else the
    /// nearest one (gutters, padding, empty space below the last row).
    static func anchor(at point: CGPoint, frames: [UUID: CGRect]) -> GridAnchor? {
        guard !frames.isEmpty else { return nil }

        var best: (id: UUID, frame: CGRect, distance: CGFloat)?
        for (id, frame) in frames {
            if frame.contains(point) {
                return GridAnchor(itemID: id, pointerY: point.y, frame: frame)
            }
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (id, frame, distance)
            }
        }
        guard let best else { return nil }
        return GridAnchor(itemID: best.id, pointerY: point.y, frame: best.frame)
    }
}
