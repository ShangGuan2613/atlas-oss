import AppKit
import AtlasCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtlasOSSApp

/// P1-F dimension F, layers 2–3: the in-app loader and its memory tier.
///
/// These are the guarantees the grid now leans on:
/// * a tile is served from a **disk** thumbnail, and the loader reports that tier;
/// * asking again is a memory hit (no second decode, no second encode);
/// * N cells asking for the same item at once produce **one** generation;
/// * the original is only decoded when there is no disk tier at all.
@MainActor
final class ThumbnailLoaderTests: XCTestCase {

    // MARK: - Sandbox

    private var workspace: URL!
    private var library: AtlasLibrary!
    private var libraryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-thumbloader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        libraryURL = workspace.appendingPathComponent("main.atlaslibrary", isDirectory: true)
        library = try AtlasLibrary(url: libraryURL)
    }

    override func tearDownWithError() throws {
        library?.close()
        if let workspace, workspace.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: workspace)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Writes a solid-colour PNG of the given pixel size (no image assets in the repo).
    @discardableResult
    private func writePNG(named name: String, width: Int, height: Int, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("could not create a bitmap context")
            throw AtlasError.io("no context")
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else {
            XCTFail("could not build fixture image")
            throw AtlasError.io("no image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AtlasError.io("cannot finalize \(url.path)")
        }
        return url
    }

    /// Imports one connected 2048×1536 PNG and returns the item + its cell request.
    private func seedItem() throws -> (item: AtlasCore.LibraryItem, request: ThumbnailRequest) {
        let folder = workspace.appendingPathComponent("source", isDirectory: true)
        try writePNG(named: "big.png", width: 2048, height: 1536, into: folder)
        _ = try library.importFolder(folder, mode: .connected)
        let item = try XCTUnwrap(try library.items().first)
        let request = ThumbnailRequest(
            item: item,
            sourceURL: library.sourceURL(for: item),
            thumbnailsRoot: library.paths.thumbnailsURL
        )
        return (item, request)
    }

    private func thumbnailFiles() -> Int {
        library.thumbnails.fileCount()
    }

    // MARK: - Disk tier

    func testFirstRequestGeneratesAThumbnailOnDisk() async throws {
        let loader = ThumbnailLoader()
        let (item, request) = try seedItem()
        let bucket = GridDensity.thumbnailPixelSize(cellWidth: GridDensity.defaultCellWidth)
        XCTAssertEqual(thumbnailFiles(), 0)

        let image = await loader.image(for: request, maxPixel: bucket)

        XCTAssertNotNil(image)
        XCTAssertEqual(thumbnailFiles(), 1)
        XCTAssertEqual(loader.statistics().diskMisses, 1)
        XCTAssertEqual(loader.statistics().originalFallbacks, 0)

        let url = try XCTUnwrap(library.thumbnailURLIfExists(for: item, maxPixel: bucket))
        let size = try XCTUnwrap(library.thumbnails.pixelSize(of: url))
        XCTAssertEqual(size.width, bucket)
        XCTAssertLessThan(size.width, 2048, "a cell must not get the original's pixels")
    }

    func testSecondRequestIsAMemoryHit() async throws {
        let loader = ThumbnailLoader()
        let (item, request) = try seedItem()
        let bucket = 360

        _ = await loader.image(for: request, maxPixel: bucket)
        let url = try XCTUnwrap(library.thumbnailURLIfExists(for: item, maxPixel: bucket))
        let writtenAt = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        for _ in 0..<5 {
            let repeated = await loader.image(for: request, maxPixel: bucket)
            XCTAssertNotNil(repeated)
        }

        let stats = loader.statistics()
        XCTAssertEqual(stats.memoryHits, 5)
        XCTAssertEqual(stats.diskMisses, 1)
        XCTAssertEqual(thumbnailFiles(), 1)
        XCTAssertEqual(
            try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            writtenAt
        )
    }

    func testAFreshLoaderServesFromDiskWithoutTouchingTheOriginal() async throws {
        let warmer = ThumbnailLoader()
        let (item, request) = try seedItem()
        _ = await warmer.image(for: request, maxPixel: 360)

        // Simulate a relaunch: brand-new loader, empty memory cache. The disk thumb is the
        // only thing standing between this cell and a 2048×1536 decode.
        let cold = ThumbnailLoader()
        let image = await cold.image(for: request, maxPixel: 360)

        XCTAssertNotNil(image)
        let stats = cold.statistics()
        XCTAssertEqual(stats.diskHits, 1)
        XCTAssertEqual(stats.originalFallbacks, 0)
        XCTAssertEqual(thumbnailFiles(), 1, "a warm cache must not re-encode")
        XCTAssertNotNil(library.thumbnailURLIfExists(for: item, maxPixel: 360))
    }

    func testABrokenSourceStillShowsItsCachedThumbnail() async throws {
        let warmer = ThumbnailLoader()
        let (item, request) = try seedItem()
        _ = await warmer.image(for: request, maxPixel: 360)

        // The user moves or deletes the linked original after browsing once. The tile must
        // keep working off the cache rather than going blank.
        let source = try XCTUnwrap(library.sourceURL(for: item))
        try FileManager.default.removeItem(at: source)

        let cold = ThumbnailLoader()
        let image = await cold.image(for: request, maxPixel: 360)

        XCTAssertNotNil(image)
        XCTAssertEqual(cold.statistics().diskHits, 1)
        XCTAssertEqual(cold.statistics().originalFallbacks, 0)
    }

    func testWithoutADiskTierTheOriginalIsTheFallbackAndIsCounted() async throws {
        let (item, request) = try seedItem()
        let loader = ThumbnailLoader()
        let bare = ThumbnailRequest(
            item: item,
            sourceURL: request.sourceURL,
            thumbnailsRoot: nil
        )

        let image = await loader.image(for: bare, maxPixel: 360)

        XCTAssertNotNil(image)
        XCTAssertEqual(loader.statistics().originalFallbacks, 1)
        XCTAssertEqual(thumbnailFiles(), 0)
    }

    func testConcurrentCellsShareOneGeneration() async throws {
        let loader = ThumbnailLoader()
        let (_, request) = try seedItem()

        let images = await withTaskGroup(of: NSImage?.self, returning: [NSImage?].self) { group in
            for _ in 0..<12 {
                group.addTask { await loader.image(for: request, maxPixel: 360) }
            }
            var results: [NSImage?] = []
            for await image in group { results.append(image) }
            return results
        }

        XCTAssertEqual(images.compactMap { $0 }.count, 12)
        XCTAssertEqual(thumbnailFiles(), 1, "twelve cells, one JPEG")
        let stats = loader.statistics()
        XCTAssertEqual(stats.generations, 1, "the in-flight map collapsed the stampede")
        XCTAssertGreaterThan(stats.coalescedRuns, 0, "at least one cell joined an in-flight run")
        // Every cell still got an answer, so "one generation" is coalescing, not failure.
        XCTAssertGreaterThanOrEqual(stats.diskMisses, 1)
    }

    func testVideoLikeSourcesDoNotBreakTheGrid() async throws {
        let folder = workspace.appendingPathComponent("vids", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A .mov that is not a real movie: importable as a video, undecodable as an image.
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: folder.appendingPathComponent("clip.mov"))
        _ = try library.importFolder(folder, mode: .connected)
        let item = try XCTUnwrap(try library.items().first)
        let request = ThumbnailRequest(
            item: item,
            sourceURL: library.sourceURL(for: item),
            thumbnailsRoot: library.paths.thumbnailsURL
        )

        let loader = ThumbnailLoader()
        let image = await loader.image(for: request, maxPixel: 360)

        XCTAssertNil(image, "no poster frame yet — the cell draws its SF Symbol placeholder")
        XCTAssertEqual(thumbnailFiles(), 0)
    }

    func testStatisticsResetAndPurge() async throws {
        let loader = ThumbnailLoader()
        let (_, request) = try seedItem()
        _ = await loader.image(for: request, maxPixel: 360)

        XCTAssertEqual(loader.statistics().cachedImages, 1)
        loader.resetStatistics()
        XCTAssertEqual(loader.statistics().diskMisses, 0)
        XCTAssertEqual(loader.statistics().cachedImages, 1, "reset only clears counters")

        loader.purgeMemoryCache()
        XCTAssertEqual(loader.statistics().cachedImages, 0)
    }

    // MARK: - Fresh library root, two items

    func testTwoItemsGetTwoThumbnailsAndShareTheBucket() async throws {
        let folder = workspace.appendingPathComponent("pair", isDirectory: true)
        try writePNG(named: "a.png", width: 900, height: 600, into: folder)
        try writePNG(named: "b.png", width: 1200, height: 800, into: folder)
        _ = try library.importFolder(folder, mode: .connected)

        let loader = ThumbnailLoader()
        for item in try library.items() {
            let request = ThumbnailRequest(
                item: item,
                sourceURL: library.sourceURL(for: item),
                thumbnailsRoot: library.paths.thumbnailsURL
            )
            let small = await loader.image(for: request, maxPixel: 180)
            let large = await loader.image(for: request, maxPixel: 540)
            XCTAssertNotNil(small)
            XCTAssertNotNil(large)
        }

        XCTAssertEqual(thumbnailFiles(), 4, "two items × two buckets")
        XCTAssertEqual(loader.statistics().diskMisses, 4)
    }
}

/// The memory tier on its own — eviction order is a behavioural contract (scroll back must
/// hit, scroll far must not grow without bound), so it is pinned down separately.
final class ThumbnailMemoryCacheTests: XCTestCase {

    func testEvictsLeastRecentlyUsedWhenOverCountLimit() {
        let cache = LRUCache<String, Int>(countLimit: 3)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        cache.insert(3, forKey: "c")

        // Touch "a" so "b" becomes the oldest.
        XCTAssertEqual(cache.value(forKey: "a"), 1)

        cache.insert(4, forKey: "d")

        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.value(forKey: "a"), 1)
        XCTAssertEqual(cache.value(forKey: "c"), 3)
        XCTAssertEqual(cache.value(forKey: "d"), 4)
    }

    func testContainsDoesNotPromote() {
        let cache = LRUCache<String, Int>(countLimit: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")

        XCTAssertTrue(cache.contains("a"))
        cache.insert(3, forKey: "c")

        XCTAssertNil(cache.value(forKey: "a"), "probing must not count as a use")
        XCTAssertEqual(cache.value(forKey: "b"), 2)
    }

    func testByteBudgetEvictsButKeepsTheNewestEntry() {
        let cache = LRUCache<String, Int>(countLimit: 100, costLimit: 100)
        cache.insert(1, forKey: "a", cost: 60)
        cache.insert(2, forKey: "b", cost: 60)

        XCTAssertEqual(cache.count, 1, "60 + 60 > 100, so the oldest goes")
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertEqual(cache.value(forKey: "b"), 2)
        XCTAssertEqual(cache.currentCost, 60)
    }

    func testOversizedEntryIsStillAdmitted() {
        let cache = LRUCache<String, Int>(countLimit: 10, costLimit: 10)
        cache.insert(1, forKey: "huge", cost: 999)

        // Refusing to cache would mean re-decoding forever; one entry is the right floor.
        XCTAssertEqual(cache.value(forKey: "huge"), 1)
    }

    func testCountLimitWinsOverCost() {
        let cache = LRUCache<String, Int>(countLimit: 2, costLimit: .max)
        for (index, key) in ["a", "b", "c", "d"].enumerated() {
            cache.insert(index, forKey: key)
        }
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.orderedKeys, ["c", "d"])
    }

    func testRemoveAndRemoveAll() {
        let cache = LRUCache<String, Int>(countLimit: 4)
        cache.insert(1, forKey: "a", cost: 10)
        cache.insert(2, forKey: "b", cost: 10)
        cache.remove("a")
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertEqual(cache.currentCost, 10)

        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.currentCost, 0)
        XCTAssertTrue(cache.orderedKeys.isEmpty)
    }
}

/// P1-F wiring: the density ladder and the model seam.
///
/// The point of these is that nothing in the app can invent its own thumbnail size or its
/// own thumbnail directory — both come from `AtlasCore`, so a bucket the store cannot
/// serve is a compile-time-visible mistake rather than a silent re-encode.
@MainActor
final class ThumbnailWiringTests: XCTestCase {

    func testDensityDecodeSizesAreExactlyTheStoreLadder() {
        XCTAssertEqual(GridDensity.decodeSteps, ThumbnailStore.bucketSizes)
        for width in stride(from: GridDensity.minCellWidth, through: GridDensity.maxCellWidth, by: 7) {
            let size = GridDensity.thumbnailPixelSize(cellWidth: width)
            XCTAssertTrue(
                ThumbnailStore.bucketSizes.contains(size),
                "cell \(width)pt asked for \(size)px, which the disc ladder does not serve"
            )
            XCTAssertTrue(ThumbnailStore.isDiskBacked(maxPixel: size))
        }
    }

    func testDefaultDensityStillAsksForThreeSixty() {
        // Guards the P1-A feel: the shipping density must keep decoding the same size it
        // always did, so the disk tier is an implementation detail, not a visual change.
        XCTAssertEqual(GridDensity.thumbnailPixelSize(cellWidth: GridDensity.defaultCellWidth), 360)
        XCTAssertEqual(GridDensity.thumbnailPixelSize(cellWidth: GridDensity.minCellWidth), 180)
        XCTAssertEqual(GridDensity.thumbnailPixelSize(cellWidth: GridDensity.maxCellWidth), 540)
    }

    func testModelRequestsCarryTheLibraryThumbnailRoot() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-wiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let source = workspace.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        guard let context = CGContext(
            data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = {
            context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            return context.makeImage()
        }() else {
            return XCTFail("could not build the fixture image")
        }
        let pngURL = source.appendingPathComponent("one.png")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let libraryURL = workspace.appendingPathComponent("wiring.atlaslibrary", isDirectory: true)
        let library = try AtlasLibrary(url: libraryURL)
        defer { library.close() }
        _ = try library.importFolder(source, mode: .connected)

        let model = LibraryModel()
        model.open(at: libraryURL)
        defer { model.library?.close() }

        let item = try XCTUnwrap(model.items.first)
        let request = model.thumbnailRequest(for: item)

        XCTAssertEqual(request.contentHash, item.contentHash)
        XCTAssertEqual(request.thumbnailsRoot, model.thumbnailsRoot)
        XCTAssertEqual(request.thumbnailsRoot?.lastPathComponent, "thumbnails")
        XCTAssertEqual(request.sourceURL, model.fileURL(for: item))
        XCTAssertEqual(model.thumbnailFileCount, 0, "an opened library has no thumbs until a cell asks")
    }
}
