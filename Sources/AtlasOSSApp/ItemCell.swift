import AtlasCore
import SwiftUI

/// Reports every realized cell's frame in the grid's viewport coordinate space.
///
/// Both the pointer-anchored zoom and arrow-key reveal need real frames: cell height
/// depends on font metrics and caption lines, so predicting it would drift.
struct GridFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// One grid tile: thumbnail box, file name, dimensions.
struct ItemCell: View {
    // Qualified: SwiftUI's DeveloperToolsSupport also exports a `LibraryItem`.
    let item: AtlasCore.LibraryItem
    /// Where the pixels come from. `nil` renders the placeholder (no backing file).
    let request: ThumbnailRequest?
    let cellWidth: Double
    let isSelected: Bool
    /// LOD: the Grid always shows its caption; the Canvas never does (a moodboard is pictures,
    /// and a caption block would make the drawn cell taller than the footprint the board packs,
    /// culls and clamps to — the P2-A misalignment).
    let showsCaption: Bool
    /// Overrides the thumbnail rung. The Canvas is drawn at a fixed *world* size and scaled by
    /// one transform, so its `cellWidth` no longer tracks the zoom — it has to ask for the rung
    /// explicitly. `nil` keeps the grid behaviour (rung derived from `cellWidth`).
    let decodePixelWidth: Int?

    /// P1-D: tile radius, inner padding and selection wash come from the design tokens
    /// instead of literals. The dictionary default keeps offscreen renders and previews
    /// working with the shipping look.
    @Environment(\.appearance) private var tokens

    @State private var image: NSImage?

    private var decodeSize: Int {
        decodePixelWidth ?? GridDensity.thumbnailPixelSize(cellWidth: cellWidth)
    }

    private var radius: Double { tokens.cornerRadius }

    init(
        item: AtlasCore.LibraryItem,
        request: ThumbnailRequest?,
        cellWidth: Double,
        isSelected: Bool,
        showsCaption: Bool = true,
        decodePixelWidth: Int? = nil
    ) {
        self.item = item
        self.request = request
        self.cellWidth = cellWidth
        self.isSelected = isSelected
        self.showsCaption = showsCaption
        self.decodePixelWidth = decodePixelWidth
    }

    /// Convenience for previews, offscreen renders and tests: one URL, no disk tier.
    init(
        item: AtlasCore.LibraryItem,
        url: URL?,
        cellWidth: Double,
        isSelected: Bool,
        showsCaption: Bool = true,
        decodePixelWidth: Int? = nil
    ) {
        self.init(
            item: item,
            request: url.map {
                ThumbnailRequest(contentHash: $0.path, sourceURL: $0, thumbnailsRoot: nil)
            },
            cellWidth: cellWidth,
            isSelected: isSelected,
            showsCaption: showsCaption,
            decodePixelWidth: decodePixelWidth
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.cellPadding) {
            ZStack {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(tokens.thumbnailInset)
                } else {
                    Image(systemName: item.kind == .image ? "photo" : "doc")
                        .font(.system(size: max(12, cellWidth * 0.14)))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: cellWidth, height: GridDensity.thumbnailHeight(cellWidth: cellWidth))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.quaternary, lineWidth: 1))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
            }
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.accentColor.opacity(isSelected ? tokens.selectionOpacity : 0))
            }

            if showsCaption {
                Text(item.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.dimensionsDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: cellWidth, alignment: .leading)
        .help(item.location)
        .task(id: "\(item.id)#\(decodeSize)") {
            guard let request else {
                image = nil
                return
            }
            // `.task(id:)` is cancelled when the cell is recycled onto another item or the
            // density changes, so a late decode cannot paint the wrong tile.
            image = await ThumbnailLoader.shared.image(for: request, maxPixel: decodeSize)
        }
    }
}
