import AtlasCore
import CoreGraphics
import Foundation

/// Size model for the item grid.
///
/// One scalar — the cell's target width — drives the column count, the tile height
/// and the thumbnail decode size, so zooming stays a single clamped number that can
/// be persisted with `@AppStorage`.
enum GridDensity {
    static let minCellWidth: Double = 80
    static let maxCellWidth: Double = 360
    static let defaultCellWidth: Double = 200

    static let itemSpacing: Double = 14
    static let contentPadding: Double = 16

    /// Tile image-box height as a fraction of the cell width (tiles sit near 4:3).
    static let thumbnailAspect: Double = 0.75

    static func clamp(_ width: Double) -> Double {
        guard width.isFinite else { return defaultCellWidth }
        return min(maxCellWidth, max(minCellWidth, width))
    }

    /// Column count for a viewport width — mirrors the fixed-width `GridItem`s we build,
    /// so keyboard row math and the real layout cannot drift apart.
    static func columns(
        availableWidth: Double,
        cellWidth: Double,
        spacing: Double = itemSpacing,
        padding: Double = contentPadding
    ) -> Int {
        let usable = availableWidth - padding * 2
        guard usable > 0, cellWidth > 0 else { return 1 }
        return max(1, Int((usable + spacing) / (cellWidth + spacing)))
    }

    /// Exact content width for `columns` cells, so the grid never gets extra space
    /// distributed between columns (which would break pointer anchoring).
    static func gridWidth(columns: Int, cellWidth: Double, spacing: Double = itemSpacing) -> Double {
        let n = Double(max(1, columns))
        return n * cellWidth + (n - 1) * spacing
    }

    static func thumbnailHeight(cellWidth: Double) -> Double {
        cellWidth * thumbnailAspect
    }

    /// Decode sizes are quantised so a continuous zoom keeps hitting the loader cache
    /// instead of decoding a new size for every intermediate pixel width.
    ///
    /// P1f: the ladder *is* the on-disk thumbnail ladder (`ThumbnailStore.bucketSizes`).
    /// One list, so the size a cell asks the loader for is always a size the store can
    /// answer with a file instead of a fresh encode.
    static var decodeSteps: [Int] { ThumbnailStore.bucketSizes }

    /// Thumbnail decode size for a cell: ~1.5× the cell width, snapped up to a bucket.
    /// A Retina cell at default density therefore decodes a 360 px thumbnail — one JPEG
    /// shared by all 34 columns, not 34 encodes.
    static func thumbnailPixelSize(cellWidth: Double) -> Int {
        ThumbnailStore.bucket(forMaxPixel: Int((clamp(cellWidth) * 1.5).rounded()))
    }

    /// Density after one scroll-wheel / magnify input unit.
    ///
    /// Trackpads report pixel deltas, mouse wheels report line deltas; the two need
    /// very different multipliers to feel like the same gesture.
    static func stepped(_ width: Double, delta: Double, precise: Bool) -> Double {
        clamp(width + delta * (precise ? 0.5 : 6))
    }
}
