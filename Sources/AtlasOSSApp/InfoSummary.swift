import AtlasCore
import Foundation

/// Everything the Info panel renders for the current selection.
///
/// A pure value type — no SwiftUI, no database — so the fiddly multi-select rules
/// (*"Multiple"* dimensions, intersection tags, combined size) stay unit-testable and the
/// view is reduced to formatting.
struct InfoSummary {
    /// Items the panel describes, in grid order.
    let items: [LibraryItem]
    /// Absolute path of the single selected file, when there is exactly one.
    let location: String?

    init(items: [LibraryItem], location: String? = nil) {
        self.items = items
        self.location = location
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var isSingle: Bool { items.count == 1 }

    /// The file name for one item, `"3 items"` for a selection.
    var headline: String {
        guard let first = items.first else { return "Select an item" }
        return isSingle ? first.fileName : "\(items.count) items"
    }

    /// `"3024×4032"` only when every selected item agrees, `"Multiple"` otherwise.
    var dimensions: String {
        guard let first = items.first else { return "—" }
        let label = first.dimensionsDescription
        return items.allSatisfy { $0.dimensionsDescription == label } ? label : "Multiple"
    }

    /// Exact size for one item, combined size for a selection.
    var byteSize: String {
        InfoFormat.bytes(items.reduce(Int64(0)) { $0 + $1.byteSize })
    }

    /// `"HEIC image"`, `"MP4 video"`, `"3 images"`, `"Mixed"`.
    var kindLabel: String {
        guard let first = items.first else { return "—" }
        guard items.count > 1 else { return Self.describe(first) }
        let kinds = Set(items.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else { return "Mixed kinds" }
        return "\(items.count) \(Self.plural(kind))"
    }

    /// How the item entered the library; `nil` for a mixed selection.
    var importModeLabel: String? {
        let modes = Set(items.map(\.mode))
        guard modes.count == 1, let mode = modes.first else { return nil }
        return mode == .copy ? "Copied into library" : "Connected (in place)"
    }

    /// File-level modified date, single selection only.
    var fileModifiedAt: Date? {
        isSingle ? items.first?.fileModifiedAt : nil
    }

    /// Import date, single selection only (a range across a selection says nothing useful).
    var importedAt: Date? {
        isSingle ? items.first?.importedAt : nil
    }

    /// Caption above the swatch strip — the multi-select rule, spelled out in the UI.
    var swatchCaption: String {
        isSingle ? "Dominant colors" : "Top colors across \(items.count) items"
    }

    // MARK: - Labels

    static func describe(_ item: LibraryItem) -> String {
        let ext = (item.fileName as NSString).pathExtension.uppercased()
        switch item.kind {
        case .image: return ext.isEmpty ? "Image" : "\(ext) image"
        case .video: return ext.isEmpty ? "Video" : "\(ext) video"
        case .other: return ext.isEmpty ? "File" : "\(ext) file"
        }
    }

    static func plural(_ kind: MediaKind) -> String {
        switch kind {
        case .image: return "images"
        case .video: return "videos"
        case .other: return "files"
        }
    }
}

// MARK: - Formatting

/// Display formatting for the Info panel. Kept in one place so the panel and its tests
/// agree on the exact strings.
enum InfoFormat {
    /// Human byte size — same units and rounding as the CLI's `formatBytes`.
    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, value))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) B" }
        return String(format: "%.1f %@", value, units[unit])
    }

    /// `"Oct 28, 2026 at 12:45 PM"` — medium date, short time.
    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Composition

/// A tag chip in the Info panel.
struct TagBadge: Identifiable, Equatable {
    let tag: LibraryTag
    /// How many of the target items carry this tag.
    let itemCount: Int
    /// Total number of target items (so the chip can say "2 of 3").
    let total: Int

    var id: UUID { tag.id }
    /// Carried by every selected item — the multi-select "intersection".
    var isShared: Bool { total > 0 && itemCount == total }

    /// `"2/3"` for a partial match, `nil` when the tag is shared by all.
    var detail: String? { isShared ? nil : "\(itemCount)/\(total)" }
}

/// A collection chip in the Info panel.
struct CollectionChip: Identifiable, Equatable {
    let collection: LibraryCollection
    let itemCount: Int
    let total: Int

    var id: UUID { collection.id }
    var isShared: Bool { total > 0 && itemCount == total }
    var detail: String? { isShared ? nil : "\(itemCount)/\(total)" }
}

/// Pure aggregation rules for the panel's chips and swatches.
enum InfoComposition {

    /// Every tag carried by at least one selected item, with how many items carry it.
    /// Shared tags come first (that is the multi-select answer), then alphabetical.
    static func tagBadges(selection: [UUID], tagsByItem: [UUID: [LibraryTag]]) -> [TagBadge] {
        guard !selection.isEmpty else { return [] }
        var counts: [UUID: (tag: LibraryTag, count: Int)] = [:]
        for itemID in selection {
            for tag in tagsByItem[itemID] ?? [] {
                if let existing = counts[tag.id] {
                    counts[tag.id] = (tag, existing.count + 1)
                } else {
                    counts[tag.id] = (tag, 1)
                }
            }
        }
        return counts.values
            .map { TagBadge(tag: $0.tag, itemCount: $0.count, total: selection.count) }
            .sorted { lhs, rhs in
                if lhs.isShared != rhs.isShared { return lhs.isShared }
                return lhs.tag.name.localizedStandardCompare(rhs.tag.name) == .orderedAscending
            }
    }

    /// Every collection the selection is filed into, with per-item counts.
    static func collectionChips(
        selection: [UUID],
        collectionsByItem: [UUID: [LibraryCollection]]
    ) -> [CollectionChip] {
        guard !selection.isEmpty else { return [] }
        var counts: [UUID: (collection: LibraryCollection, count: Int)] = [:]
        for itemID in selection {
            for collection in collectionsByItem[itemID] ?? [] {
                if let existing = counts[collection.id] {
                    counts[collection.id] = (collection, existing.count + 1)
                } else {
                    counts[collection.id] = (collection, 1)
                }
            }
        }
        return counts.values
            .map { CollectionChip(collection: $0.collection, itemCount: $0.count, total: selection.count) }
            .sorted { lhs, rhs in
                if lhs.isShared != rhs.isShared { return lhs.isShared }
                if lhs.collection.isInbox != rhs.collection.isInbox { return lhs.collection.isInbox }
                return lhs.collection.name.localizedStandardCompare(rhs.collection.name) == .orderedAscending
            }
    }

    /// Colours across a selection.
    ///
    /// **Documented choice:** a strict intersection of approximate colours is empty for two
    /// different photos, so the panel shows the *top colours across the selection* instead:
    /// per-item palettes are merged into clusters (anything within `mergeDistance` is the
    /// same shade) and ranked by how many selected items contain that shade first, then by
    /// total pixel weight. That answers "what colour is this group", which is what the
    /// chips are for.
    static func swatches(
        for palettes: [[Swatch]],
        maxColors: Int = ColorProbe.defaultMaxColors,
        mergeDistance: Double = 24
    ) -> [Swatch] {
        struct Cluster {
            var hex: String
            var rgb: (red: Int, green: Int, blue: Int)
            var weight: Double
            var itemCount: Int
        }

        var clusters: [Cluster] = []
        for palette in palettes {
            for swatch in palette {
                guard let rgb = swatch.rgb else { continue }
                if let index = clusters.firstIndex(where: {
                    ColorProbe.distance($0.rgb, rgb) < mergeDistance
                }) {
                    clusters[index].weight += swatch.weight
                    clusters[index].itemCount += 1
                } else {
                    clusters.append(
                        Cluster(hex: swatch.hex, rgb: rgb, weight: swatch.weight, itemCount: 1)
                    )
                }
            }
        }

        let ranked = clusters.sorted { lhs, rhs in
            if lhs.itemCount != rhs.itemCount { return lhs.itemCount > rhs.itemCount }
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.hex < rhs.hex
        }
        return ranked.prefix(max(0, maxColors)).map { Swatch(hex: $0.hex, weight: $0.weight) }
    }
}
