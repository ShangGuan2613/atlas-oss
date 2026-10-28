import Foundation
import Testing
@testable import AtlasCore

/// P1-C dimension E, layer 2: the cached palette and the colour filter.
@Suite("P1-C · palette cache & colour filter")
struct ColorCacheTests {

    /// A library with one red and one blue image, imported as connected items.
    private func seed(_ workspace: TemporaryWorkspace) throws -> (library: AtlasLibrary, red: UUID, blue: UUID) {
        let folder = workspace.url.appendingPathComponent("colors", isDirectory: true)
        try ColorFixtures.write(
            [.init("#C81E1E", 0.6), .init("#8A1010", 0.25), .init("#F0D0D0", 0.15)],
            to: folder.appendingPathComponent("red.png")
        )
        try ColorFixtures.write(
            [.init("#1E3CC8", 0.6), .init("#10208A", 0.25), .init("#D0D0F0", 0.15)],
            to: folder.appendingPathComponent("blue.png")
        )

        let library = try workspace.makeLibrary()
        _ = try library.importFolder(folder, mode: .connected)

        let items = try library.items()
        let red = try #require(items.first { $0.fileName == "red.png" }).id
        let blue = try #require(items.first { $0.fileName == "blue.png" }).id
        return (library, red, blue)
    }

    // MARK: - Extraction + cache

    @Test("a palette is extracted lazily, then served from the cache")
    func extractsThenCaches() throws {
        let workspace = try TemporaryWorkspace(label: "palette-cache")
        let seeded = try seed(workspace)
        defer { seeded.library.close() }

        #expect(try seeded.library.cachedColors(forItemID: seeded.red).isEmpty)
        #expect(try seeded.library.hasCurrentPalette(for: seeded.red) == false)

        let palette = try seeded.library.dominantColors(for: seeded.red)

        #expect(palette.count >= ColorProbe.minimumDistinctSwatches)
        #expect(try seeded.library.hasCurrentPalette(for: seeded.red))
        #expect(try seeded.library.cachedColors(forItemID: seeded.red).map(\.hex) == palette.map(\.hex))
        // The other item is untouched by a single-item probe.
        #expect(try seeded.library.cachedColors(forItemID: seeded.blue).isEmpty)
    }

    @Test("the palette survives a reopen")
    func paletteSurvivesReopen() throws {
        let workspace = try TemporaryWorkspace(label: "palette-reopen")
        let seeded = try seed(workspace)
        let palette = try seeded.library.dominantColors(for: seeded.red)
        seeded.library.close()

        let reopened = try workspace.makeLibrary()
        defer { reopened.close() }
        #expect(try reopened.cachedColors(forItemID: seeded.red).map(\.hex) == palette.map(\.hex))
        #expect(try reopened.hasCurrentPalette(for: seeded.red))
        // …and `refresh: true` still re-probes without breaking anything.
        #expect(try reopened.dominantColors(for: seeded.red, refresh: true).count == palette.count)
    }

    @Test("editing the file invalidates and re-probes the cache")
    func fileEditReprobes() async throws {
        let workspace = try TemporaryWorkspace(label: "palette-edit")
        let seeded = try seed(workspace)
        defer { seeded.library.close() }

        let before = try seeded.library.dominantColors(for: seeded.red)
        let item = try #require(try seeded.library.item(id: seeded.red))
        let url = try #require(seeded.library.fileURL(for: item))

        // Same path, different colours: the mtime (not the import hash) is what moves.
        try await Task.sleep(nanoseconds: 30_000_000)
        try ColorFixtures.write([.init("#1E8C3A", 0.8), .init("#F0F0F0", 0.2)], to: url)

        #expect(try seeded.library.hasCurrentPalette(for: seeded.red) == false)

        let after = try seeded.library.dominantColors(for: seeded.red)
        #expect(after.map(\.hex) != before.map(\.hex))
        let firstAfter = try #require(after.first)
        let distance = try #require(
            ColorProbe.distance(betweenHex: firstAfter.hex, andHex: "#1E8C3A")
        )
        #expect(distance < 40)
        #expect(try seeded.library.hasCurrentPalette(for: seeded.red))
    }

    @Test("videos are palette-less, and that empty result is cached too")
    func videoHasNoPalette() throws {
        let workspace = try TemporaryWorkspace(label: "palette-video")
        let folder = workspace.url.appendingPathComponent("clips", isDirectory: true)
        try Data(repeating: 7, count: 256).write(
            to: folder.appendingPathComponent("clip.mp4").withDirectoryCreated()
        )

        let library = try workspace.makeLibrary()
        defer { library.close() }
        _ = try library.importFolder(folder, mode: .connected)

        let video = try #require(try library.items().first { $0.kind == .video })
        #expect(try library.dominantColors(for: video.id).isEmpty)
        #expect(try library.cachedColors(forItemID: video.id).isEmpty)
        // Cached-as-empty: a second probe does not touch the file again.
        #expect(try library.hasCurrentPalette(for: video.id))
    }

    @Test("probing an unknown item throws")
    func unknownItemThrows() throws {
        let workspace = try TemporaryWorkspace(label: "palette-unknown")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        #expect(throws: AtlasError.self) {
            _ = try library.dominantColors(for: UUID())
        }
        #expect(try library.item(id: UUID()) == nil)
    }

    // MARK: - Colour filter

    @Test("the colour filter matches within tolerance and ignores everything else")
    func colourFilterHonoursTolerance() throws {
        let workspace = try TemporaryWorkspace(label: "colour-filter")
        let seeded = try seed(workspace)
        defer { seeded.library.close() }

        let redHex = try #require(try seeded.library.dominantColors(for: seeded.red).first).hex
        _ = try seeded.library.dominantColors(for: seeded.blue)

        // Default tolerance: only the red item.
        #expect(try seeded.library.items(matchingColor: redHex).map(\.id) == [seeded.red])
        // Exact match (tolerance 0) still finds the item it was read from.
        #expect(try seeded.library.items(matchingColor: redHex, tolerance: 0).map(\.id) == [seeded.red])
        // Wide open: both images share the red neighbourhood.
        #expect(try seeded.library.items(matchingColor: redHex, tolerance: 255).count == 2)
        // Near-miss with a tight tolerance: nothing.
        #expect(try seeded.library.items(matchingColor: redHex, tolerance: 1).isEmpty == false)
        // Malformed / unknown colours are empty, not errors.
        #expect(try seeded.library.items(matchingColor: "not-a-colour").isEmpty)
        #expect(try seeded.library.items(matchingColor: "#000000").isEmpty)
    }

    @Test("an unprobed library has nothing to filter")
    func filterNeedsCachedPalettes() throws {
        let workspace = try TemporaryWorkspace(label: "colour-filter-cold")
        let seeded = try seed(workspace)
        defer { seeded.library.close() }

        #expect(try seeded.library.itemIDs(matchingColor: "#C81E1E").isEmpty)
        #expect(try seeded.library.items(matchingColor: "#C81E1E").isEmpty)
    }

    @Test("item id filtering is exact and composable with the standard query")
    func itemIDFiltering() throws {
        let workspace = try TemporaryWorkspace(label: "item-ids")
        let seeded = try seed(workspace)
        defer { seeded.library.close() }

        #expect(try seeded.library.items(itemIDs: []).isEmpty)
        #expect(try seeded.library.items(itemIDs: [seeded.blue]).map(\.id) == [seeded.blue])
        #expect(try seeded.library.items(itemIDs: [seeded.red, seeded.blue]).count == 2)
        #expect(try seeded.library.items(itemIDs: [UUID()]).isEmpty)
    }
}

/// P1-C dimension E, layer 3: the metadata the Info panel needs.
@Suite("P1-C · info metadata")
struct InfoMetadataTests {

    @Test("collection membership is reported per item in one pass")
    func membershipChips() throws {
        let workspace = try TemporaryWorkspace(label: "info-membership")
        let folder = workspace.url.appendingPathComponent("shots", isDirectory: true)
        try Fixtures.write(prefix: 2, into: folder)

        let library = try workspace.makeLibrary()
        defer { library.close() }
        _ = try library.importFolder(folder, mode: .connected)

        let items = try library.items()
        #expect(items.count == 2)
        let moodboard = try library.createCollection(name: "Moodboard")
        try library.assignItems([items[0].id], toCollection: moodboard)

        let memberships = try library.collections(forItemIDs: items.map(\.id))

        // The filed item: Moodboard plus the import folder — filing cleared the Inbox.
        let filedNames = try #require(memberships[items[0].id]).map(\.name)
        #expect(Set(filedNames) == ["shots", "Moodboard"])
        #expect(!filedNames.contains("Inbox"))

        // The untouched item: Inbox (pinned first) plus the import folder.
        let looseNames = try #require(memberships[items[1].id]).map(\.name)
        #expect(Set(looseNames) == ["Inbox", "shots"])
        #expect(looseNames.first == "Inbox", "Inbox-first ordering")

        let noItems = try library.collections(forItemIDs: [])
        #expect(noItems.isEmpty)
        let unknownID = UUID()
        let unknown = try library.collections(forItemIDs: [unknownID])
        #expect(unknown[unknownID]?.isEmpty == true)
    }

    @Test("tags for many items are returned in bulk")
    func tagLookups() throws {
        let workspace = try TemporaryWorkspace(label: "info-tags")
        let folder = workspace.url.appendingPathComponent("shots", isDirectory: true)
        try Fixtures.write(prefix: 3, into: folder)

        let library = try workspace.makeLibrary()
        defer { library.close() }
        _ = try library.importFolder(folder, mode: .connected)
        let items = try library.items()

        let hero = try library.createTag(name: "hero")
        let dark = try library.createTag(name: "dark")
        try library.setTags(itemIDs: items.prefix(2).map(\.id), tagIDs: [hero], mode: .add)
        try library.setTags(itemIDs: [items[0].id], tagIDs: [dark], mode: .add)

        let byItem = try library.tags(forItemIDs: items.map(\.id))
        #expect(byItem[items[0].id]?.map(\.name) == ["dark", "hero"])
        #expect(byItem[items[1].id]?.map(\.name) == ["hero"])
        #expect(byItem[items[2].id]?.isEmpty == true)
    }
}

// MARK: - Helpers

private extension URL {
    /// Creates the parent directory so tests can write a file with one call.
    func withDirectoryCreated() -> URL {
        try? FileManager.default.createDirectory(
            at: deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return self
    }
}
