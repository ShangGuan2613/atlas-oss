import AppKit
import AtlasCore
import ImageIO
import XCTest
@testable import AtlasOSSApp

/// P1-C dimension E at the app layer: the pure Info summary rules, the composition
/// (tags / collections / colours across a selection) and the model bridge that feeds the
/// panel and the colour filter.
@MainActor
final class InfoPanelTests: XCTestCase {

    private var workspace: URL!
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-info-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        libraryRoot = workspace.appendingPathComponent("main.atlaslibrary", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let workspace,
           workspace.path.hasPrefix(FileManager.default.temporaryDirectory.path),
           workspace.lastPathComponent.hasPrefix("atlasoss-info-") {
            try? FileManager.default.removeItem(at: workspace)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func item(
        name: String = "IMG_0042.heic",
        kind: MediaKind = .image,
        width: Int? = 3024,
        height: Int? = 4032,
        byteSize: Int64 = 2_411_522,
        mode: ImportMode = .connected
    ) -> AtlasCore.LibraryItem {
        AtlasCore.LibraryItem(
            id: UUID(),
            kind: kind,
            mode: mode,
            fileName: name,
            sourcePath: mode == .connected ? "/tmp/\(name)" : nil,
            storedName: mode == .copy ? name : nil,
            width: width,
            height: height,
            byteSize: byteSize,
            contentHash: "hash-\(name)",
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileCreatedAt: nil,
            fileModifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func tag(_ name: String) -> LibraryTag {
        LibraryTag(id: UUID(), name: name, createdAt: Date(timeIntervalSince1970: 0), color: nil)
    }

    private func collection(
        _ name: String,
        isInbox: Bool = false,
        sortOrder: Double = 0
    ) -> LibraryCollection {
        LibraryCollection(
            id: UUID(),
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            itemCount: 1,
            sortOrder: sortOrder,
            isInbox: isInbox
        )
    }

    /// Writes `count` PNGs with three distinct colour bands each; the first is red-family,
    /// the rest are blue-family so a colour filter can tell them apart.
    ///
    /// Drawn into an sRGB `CGContext` rather than an `NSBitmapImageRep`: the AppKit path
    /// runs values through the display profile and logs "Unrecognized colorspace".
    @discardableResult
    private func makeColorFolder(count: Int = 2, name: String = "colors") throws -> URL {
        let folder = workspace.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let palettes: [[(UInt8, UInt8, UInt8)]] = [
            [(200, 31, 31), (138, 16, 16), (240, 208, 208)],
            [(31, 60, 200), (16, 32, 138), (160, 160, 255)],
        ]

        for index in 0 ..< count {
            try writeBandedPNG(
                to: folder.appendingPathComponent("color-\(index).png"),
                bands: palettes[index % palettes.count]
            )
        }
        return folder
    }

    private func writeBandedPNG(
        to url: URL,
        bands: [(UInt8, UInt8, UInt8)],
        width: Int = 40,
        height: Int = 40
    ) throws {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0 ..< height {
            let band = bands[min(bands.count - 1, y * bands.count / height)]
            for x in 0 ..< width {
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = band.0
                buffer[offset + 1] = band.1
                buffer[offset + 2] = band.2
                buffer[offset + 3] = 255
            }
        }

        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered: CGImage? = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: info
            ) else { return nil }
            return context.makeImage()
        }
        let image = try XCTUnwrap(rendered)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeModel(itemCount: Int = 2) throws -> LibraryModel {
        let seed = try AtlasLibrary(url: libraryRoot)
        let folder = try makeColorFolder(count: itemCount)
        _ = try seed.importFolder(folder, mode: .connected)
        seed.close()

        let model = LibraryModel()
        model.open(at: libraryRoot)
        XCTAssertNil(model.loadError, "open failed: \(model.loadError ?? "")")
        return model
    }

    // MARK: - InfoSummary

    func testSingleSelectionSummary() throws {
        let item = item()
        let summary = InfoSummary(items: [item], location: "/tmp/IMG_0042.heic")

        XCTAssertTrue(summary.isSingle)
        XCTAssertEqual(summary.headline, "IMG_0042.heic")
        XCTAssertEqual(summary.dimensions, "3024×4032")
        XCTAssertEqual(summary.byteSize, "2.3 MB")
        XCTAssertEqual(summary.kindLabel, "HEIC image")
        XCTAssertEqual(summary.importModeLabel, "Connected (in place)")
        XCTAssertEqual(summary.location, "/tmp/IMG_0042.heic")
        XCTAssertNotNil(summary.importedAt)
        XCTAssertNotNil(summary.fileModifiedAt)
        XCTAssertEqual(summary.swatchCaption, "Dominant colors")
    }

    func testMultiSelectionSummaryUsesMultipleForMixedDimensions() throws {
        let a = item(name: "a.png", width: 100, height: 100, byteSize: 1024)
        let b = item(name: "b.png", width: 100, height: 100, byteSize: 1024)
        let same = InfoSummary(items: [a, b])

        XCTAssertFalse(same.isSingle)
        XCTAssertEqual(same.headline, "2 items")
        XCTAssertEqual(same.dimensions, "100×100", "shared dimensions are reported")
        XCTAssertEqual(same.byteSize, "2.0 KB", "sizes add up across the selection")
        XCTAssertEqual(same.kindLabel, "2 images")
        XCTAssertNil(same.importedAt, "date rows are single-selection only")
        XCTAssertNil(same.fileModifiedAt)
        XCTAssertEqual(same.swatchCaption, "Top colors across 2 items")

        let different = InfoSummary(items: [a, item(name: "c.png", width: 640, height: 480)])
        XCTAssertEqual(different.dimensions, "Multiple")

        let mixedKinds = InfoSummary(items: [a, item(name: "movie.mp4", kind: .video, width: 1920, height: 1080)])
        XCTAssertEqual(mixedKinds.kindLabel, "Mixed kinds")

        let mixedModes = InfoSummary(items: [a, item(name: "copy.png", mode: .copy)])
        XCTAssertNil(mixedModes.importModeLabel)
    }

    func testEmptySummaryIsAPlaceholder() throws {
        let summary = InfoSummary(items: [])

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.headline, "Select an item")
        XCTAssertEqual(summary.dimensions, "—")
        XCTAssertEqual(summary.byteSize, "0 B")
        XCTAssertEqual(summary.kindLabel, "—")
        XCTAssertNil(summary.location)
    }

    func testByteFormattingMatchesTheCLI() throws {
        XCTAssertEqual(InfoFormat.bytes(0), "0 B")
        XCTAssertEqual(InfoFormat.bytes(512), "512 B")
        XCTAssertEqual(InfoFormat.bytes(1024), "1.0 KB")
        XCTAssertEqual(InfoFormat.bytes(2_411_522), "2.3 MB")
        XCTAssertEqual(InfoFormat.bytes(-5), "0 B")
    }

    // MARK: - Composition

    func testTagBadgesCountPerItemAndSortSharedFirst() throws {
        let ids = [UUID(), UUID(), UUID()]
        let shared = tag("shared")
        let partial = tag("partial")
        let single = tag("single")

        let badges = InfoComposition.tagBadges(
            selection: ids,
            tagsByItem: [
                ids[0]: [shared, partial, single],
                ids[1]: [shared, partial],
                ids[2]: [shared],
            ]
        )

        XCTAssertEqual(badges.map(\.tag.name), ["shared", "partial", "single"])
        XCTAssertEqual(badges.map(\.itemCount), [3, 2, 1])
        XCTAssertEqual(badges.map(\.isShared), [true, false, false])
        XCTAssertEqual(badges.map(\.detail), [nil, "2/3", "1/3"])
    }

    func testCollectionChipsRankSharedFirstThenInbox() throws {
        let ids = [UUID(), UUID()]
        let inbox = collection("Inbox", isInbox: true, sortOrder: -1000)
        let mood = collection("Moodboard", sortOrder: 1)
        let refs = collection("References", sortOrder: 2)

        let chips = InfoComposition.collectionChips(
            selection: ids,
            collectionsByItem: [
                ids[0]: [inbox, mood],
                ids[1]: [inbox, mood, refs],
            ]
        )

        XCTAssertEqual(chips.map(\.collection.name), ["Inbox", "Moodboard", "References"])
        XCTAssertEqual(chips.map(\.itemCount), [2, 2, 1])
        XCTAssertTrue(chips[0].isShared)
        XCTAssertNil(chips[0].detail)
        XCTAssertEqual(chips[2].detail, "1/2")

        XCTAssertTrue(InfoComposition.tagBadges(selection: [], tagsByItem: [:]).isEmpty)
        XCTAssertTrue(InfoComposition.collectionChips(selection: [], collectionsByItem: [:]).isEmpty)
    }

    func testSelectionColorsRankByItemCountThenWeight() throws {
        // Red appears in both palettes, blue only in the second one.
        let palettes = [
            [Swatch(hex: "#C81E1E", weight: 0.6), Swatch(hex: "#8A1010", weight: 0.4)],
            [Swatch(hex: "#C71F1F", weight: 0.3), Swatch(hex: "#1E3CC8", weight: 0.7)],
        ]

        let merged = InfoComposition.swatches(for: palettes)

        XCTAssertEqual(merged.first?.hex, "#C81E1E", "the shade both items share wins")
        XCTAssertEqual(merged.first?.weight ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertTrue(merged.contains { $0.hex == "#1E3CC8" })
        XCTAssertLessThanOrEqual(merged.count, ColorProbe.defaultMaxColors)
        XCTAssertTrue(InfoComposition.swatches(for: []).isEmpty)
        XCTAssertTrue(InfoComposition.swatches(for: [[], []]).isEmpty)
    }

    // MARK: - Model bridge

    func testSelectionMirrorsIntoInfoTargets() throws {
        let model = try makeModel(itemCount: 3)
        model.select(.all)
        let ids = model.items.map(\.id)

        model.setSelection([ids[0]])
        XCTAssertEqual(model.infoTargetItems.map(\.id), [ids[0]])
        XCTAssertEqual(model.infoSummary.count, 1)

        model.setSelection(ids)
        XCTAssertEqual(model.infoTargetItems.count, 3)
        XCTAssertEqual(model.infoSummary.headline, "3 items")

        // Unknown ids can never appear in the panel.
        model.setSelection([UUID()])
        XCTAssertTrue(model.infoTargetItems.isEmpty)

        model.setSelection([])
        XCTAssertTrue(model.infoSummary.isEmpty)
    }

    func testSwatchesLoadForTheSelection() async throws {
        let model = try makeModel(itemCount: 2)
        model.select(.all)
        let ids = model.items.map(\.id)

        await model.loadSwatches(for: ids)

        let palette = model.swatches(for: ids[0])
        XCTAssertGreaterThanOrEqual(
            palette.count, ColorProbe.minimumDistinctSwatches,
            "an Info panel needs at least three swatches"
        )
        for swatch in palette {
            XCTAssertEqual(swatch.hex.count, 7)
            XCTAssertTrue(swatch.hex.hasPrefix("#"))
        }

        model.setSelection([ids[0]])
        XCTAssertEqual(model.infoSwatches.map(\.hex), palette.map(\.hex))
    }

    func testColorFilterNarrowsTheGridAndClearingRestoresIt() async throws {
        let model = try makeModel(itemCount: 2)
        model.select(.all)
        let items = model.items
        XCTAssertEqual(items.count, 2)

        let red = try XCTUnwrap(items.first { $0.fileName == "color-0.png" })
        await model.loadSwatches(for: [red.id])
        let hex = try XCTUnwrap(model.swatches(for: red.id).first).hex

        await model.applyColorFilter(hex: hex)

        XCTAssertEqual(model.info.colorFilter?.hex, hex)
        XCTAssertEqual(model.items.map(\.id), [red.id], "only the red item matches")

        model.clearColorFilter()

        XCTAssertNil(model.info.colorFilter)
        XCTAssertEqual(model.items.count, 2, "clearing restores the sidebar query")
    }

    func testColorFilterWithAnUnknownColorShowsNothing() async throws {
        let model = try makeModel(itemCount: 2)
        model.select(.all)

        await model.applyColorFilter(hex: "#00FF00")

        XCTAssertTrue(model.items.isEmpty)
        model.clearColorFilter()
        XCTAssertEqual(model.items.count, 2)
    }

    func testTagChipsAreEditableAcrossTheSelection() throws {
        let model = try makeModel(itemCount: 3)
        model.select(.all)
        let ids = model.items.map(\.id)

        model.createTag(name: "hero")
        let hero = try XCTUnwrap(model.tags.first)
        // `createTag` navigates to the tag; come back to the grid.
        model.select(.all)
        model.setSelection(ids)

        // Two of three: a partial match, so the chip reports "2/3".
        model.addTag(hero.id, toSelection: [ids[0], ids[1]])
        model.setSelection(ids)
        XCTAssertEqual(model.info.tagBadges.count, 1)
        XCTAssertEqual(model.info.tagBadges[0].itemCount, 2)
        XCTAssertFalse(model.info.tagBadges[0].isShared)
        XCTAssertEqual(model.info.tagBadges[0].detail, "2/3")
        XCTAssertEqual(model.tag(for: hero.id)?.itemCount, 2)

        // Adding to the whole selection makes it shared.
        model.addTag(hero.id)
        XCTAssertEqual(model.info.tagBadges[0].itemCount, 3)
        XCTAssertTrue(model.info.tagBadges[0].isShared)
        XCTAssertTrue(model.addableTags.isEmpty, "nothing left to add")

        // Removing applies to every selected item.
        model.removeTag(hero.id)
        XCTAssertTrue(model.info.tagBadges.isEmpty)
        XCTAssertEqual(model.tag(for: hero.id)?.itemCount, 0)
    }

    func testCollectionChipsFollowMembership() throws {
        let model = try makeModel(itemCount: 2)
        model.select(.all)
        let ids = model.items.map(\.id)
        let board = try XCTUnwrap(model.createCollection(name: "Board"))

        // Dropping on a collection files the item: Board is added, the Inbox is cleared.
        XCTAssertTrue(model.apply(.addItems(itemIDs: [ids[0]], collectionID: board)))

        model.select(.all)
        model.setSelection([ids[0]])

        XCTAssertEqual(
            model.info.collectionChips.map(\.collection.name).sorted(),
            ["Board", "colors"].sorted()
        )

        let chip = try XCTUnwrap(model.info.collectionChips.first { $0.collection.id == board })
        XCTAssertEqual(chip.itemCount, 1)
        XCTAssertTrue(chip.isShared)
        XCTAssertEqual(model.infoSummary.location, model.fileURL(for: model.infoTargetItems[0])?.path)
    }
}
