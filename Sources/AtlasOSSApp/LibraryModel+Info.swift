import AtlasCore
import Foundation

/// Info-panel and colour-filter state for `LibraryModel`.
///
/// One value type so the whole panel travels through a single `@Published` write, and the
/// bridge (selection mirror → palettes → filter) lives here instead of bloating
/// `LibraryModel` itself.
struct InfoState {
    /// Grid selection mirrored from `ContentView`, in grid order.
    var selectedIDs: [UUID] = []
    /// Palettes we have probed so far, keyed by item id.
    var swatches: [UUID: [Swatch]] = [:]
    /// Active colour filter, or `nil` when the grid shows the plain sidebar query.
    var colorFilter: ColorFilter?
    /// Tag chips for the current selection (shared tags first).
    var tagBadges: [TagBadge] = []
    /// Collection chips for the current selection.
    var collectionChips: [CollectionChip] = []
    /// True while palettes are being extracted in the background.
    var isLoadingSwatches = false
}

/// A `#RRGGBB` filter layered on top of whatever the sidebar shows.
///
/// Clicking a swatch sets one of these; clearing it restores the sidebar query. The filter
/// never mutates the sidebar selection, so "✕" is always a no-surprises undo.
struct ColorFilter: Identifiable, Equatable {
    let hex: String
    var tolerance: Int = ColorProbe.defaultTolerance

    var id: String { "\(hex)@\(tolerance)" }
    var title: String { hex }
}

// MARK: - Selection bridge

extension LibraryModel {

    /// Items the Info panel describes: the grid selection, in grid order.
    ///
    /// Read through `items` rather than the raw selection, so an item that the current
    /// query (collection switch, colour filter) pruned can never leak into the panel.
    var infoTargetItems: [LibraryItem] {
        items.filter { info.selectedIDs.contains($0.id) }
    }

    /// Everything the panel renders for the current selection.
    var infoSummary: InfoSummary {
        let targets = infoTargetItems
        let location = targets.count == 1 ? fileURL(for: targets[0])?.path : nil
        return InfoSummary(items: targets, location: location)
    }

    /// Mirrors `ContentView`'s selection into the model and starts the palette work.
    func setSelection(_ ids: [UUID]) {
        let live = Set(items.map(\.id))
        let pruned = ids.filter { live.contains($0) }
        guard pruned != info.selectedIDs else { return }
        info.selectedIDs = pruned
        refreshInfoMetadata()
        scheduleSwatchLoad(for: pruned)
    }

    /// Tags + collection memberships for the selection (one batched query each).
    func refreshInfoMetadata() {
        guard let library, !info.selectedIDs.isEmpty else {
            info.tagBadges = []
            info.collectionChips = []
            return
        }
        do {
            let tagMap = try library.tags(forItemIDs: info.selectedIDs)
            let collectionMap = try library.collections(forItemIDs: info.selectedIDs)
            info.tagBadges = InfoComposition.tagBadges(
                selection: info.selectedIDs,
                tagsByItem: tagMap
            )
            info.collectionChips = InfoComposition.collectionChips(
                selection: info.selectedIDs,
                collectionsByItem: collectionMap
            )
        } catch {
            info.tagBadges = []
            info.collectionChips = []
            reportLoadError("Could not read item details: \(error)")
        }
    }

    /// Tags the selection does not fully share — the contents of the "add tag" menu.
    var addableTags: [LibraryTag] {
        let shared = Set(info.tagBadges.filter(\.isShared).map(\.id))
        return tags.filter { !shared.contains($0.id) }
    }

    // MARK: - Palettes

    /// Palette that best represents the selection.
    ///
    /// One item: its own palette. Several: top colours across the selection (see
    /// `InfoComposition.swatches` for why that beats a strict intersection).
    var infoSwatches: [Swatch] {
        let targets = infoTargetItems
        if targets.count == 1 { return info.swatches[targets[0].id] ?? [] }
        return InfoComposition.swatches(for: targets.map { info.swatches[$0.id] ?? [] })
    }

    func swatches(for itemID: UUID) -> [Swatch] {
        info.swatches[itemID] ?? []
    }

    /// Loads — extracting if necessary — the palettes of `ids`.
    func loadSwatches(for ids: [UUID]) async {
        guard let library else { return }
        let missing = ids.filter { info.swatches[$0] == nil }
        guard !missing.isEmpty else { return }
        info.isLoadingSwatches = true
        let extracted = await Self.extractPalettes(library: library, itemIDs: missing)
        info.swatches.merge(extracted) { _, new in new }
        info.isLoadingSwatches = false
    }

    /// Fire-and-forget palette load for the selection, so opening the panel never blocks.
    func scheduleSwatchLoad(for ids: [UUID]) {
        let missing = ids.filter { info.swatches[$0] == nil }
        guard !missing.isEmpty else { return }
        Task { await loadSwatches(for: missing) }
    }

    /// Probes the palettes of the visible items so the colour filter has data to search.
    ///
    /// Bounded to the first `limit` items of the current view: a 10k library should not be
    /// decoded on a background thread just because the panel opened.
    func prefetchPalettes(limit: Int = 120) async {
        guard let library else { return }
        let targets = items
            .prefix(limit)
            .filter { $0.kind == .image && info.swatches[$0.id] == nil }
            .map(\.id)
        guard !targets.isEmpty else { return }
        info.isLoadingSwatches = true
        let extracted = await Self.extractPalettes(library: library, itemIDs: targets)
        info.swatches.merge(extracted) { _, new in new }
        info.isLoadingSwatches = false
    }

    /// Off-main extraction.
    ///
    /// `AtlasLibrary` is a synchronous facade over a WAL SQLite connection opened with
    /// `FULLMUTEX`, so a background probe can write its cache row next to main-thread reads.
    nonisolated static func extractPalettes(
        library: AtlasLibrary,
        itemIDs: [UUID]
    ) async -> [UUID: [Swatch]] {
        await Task.detached(priority: .utility) {
            var result: [UUID: [Swatch]] = [:]
            for itemID in itemIDs {
                if Task.isCancelled { break }
                if let palette = try? library.dominantColors(for: itemID) {
                    result[itemID] = palette
                }
            }
            return result
        }.value
    }

    // MARK: - Colour filter

    /// Filters the grid to items whose palette is within `tolerance` of `hex`.
    ///
    /// Palettes for the visible items are warmed first, otherwise the filter would
    /// silently miss everything that had never been probed.
    func applyColorFilter(hex: String, tolerance: Int = ColorProbe.defaultTolerance) async {
        await prefetchPalettes()
        info.colorFilter = ColorFilter(
            hex: ColorProbe.normalizedHex(hex) ?? hex,
            tolerance: tolerance
        )
        reloadItems()
    }

    /// Drops the colour filter and restores the sidebar query.
    func clearColorFilter() {
        guard info.colorFilter != nil else { return }
        info.colorFilter = nil
        reloadItems()
    }

    /// Applies the active colour filter to a query result (used by `reloadItems()`).
    func filteredByColor(_ base: [LibraryItem], library: AtlasLibrary) -> [LibraryItem] {
        guard let filter = info.colorFilter else { return base }
        guard let ids = try? library.itemIDs(
            matchingColor: filter.hex,
            tolerance: filter.tolerance
        ) else {
            return []
        }
        let matching = Set(ids)
        return base.filter { matching.contains($0.id) }
    }

    // MARK: - Tag editing

    /// Adds a tag to every selected item.
    func addTag(_ tagID: UUID, toSelection ids: [UUID]? = nil) {
        applyTag(tagID, mode: .add, toSelection: ids)
    }

    /// Removes a tag from every selected item.
    func removeTag(_ tagID: UUID, fromSelection ids: [UUID]? = nil) {
        applyTag(tagID, mode: .remove, toSelection: ids)
    }

    private func applyTag(_ tagID: UUID, mode: TagAssignmentMode, toSelection ids: [UUID]?) {
        guard let library else { return }
        let targets = ids ?? info.selectedIDs
        guard !targets.isEmpty else { return }
        do {
            try library.setTags(itemIDs: targets, tagIDs: [tagID], mode: mode)
            refreshInfoMetadata()
            // The sidebar badge and a tag-filtered grid both move with membership.
            if case .tag(let selected) = selection, selected == tagID {
                reloadItems()
            } else {
                reloadSidebar()
            }
        } catch {
            reportLoadError("Could not update tags: \(error)")
        }
    }
}
