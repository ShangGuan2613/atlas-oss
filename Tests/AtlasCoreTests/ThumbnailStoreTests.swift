import Foundation
import Testing
@testable import AtlasCore

/// P1-F dimension F, layer 1: the disk thumbnail store.
///
/// The contract the grid depends on is narrow and worth pinning down:
/// * a thumbnail lands at a deterministic path derived from **content hash + size bucket**;
/// * asking twice does not rewrite the file (scroll, relaunch, re-select all hit the same JPEG);
/// * both import modes generate from the file they already point at — connected items are
///   never copied into `originals/` just to make a picture;
/// * an in-place edit of a connected original invalidates the cached thumbnail.
@Suite("P1-F · disk thumbnail store")
struct ThumbnailStoreTests {

    // MARK: - Fixtures

    /// One connected library with the four deterministic PNG fixtures.
    private func seededConnected(
        _ workspace: TemporaryWorkspace
    ) throws -> (library: AtlasLibrary, folder: URL, items: [LibraryItem]) {
        // Import canonicalises (`/var/...` → `/private/var/...`), so the expectation side
        // has to canonicalise too or the prefix check is meaningless.
        let folder = PathUtilities.canonicalURL(try workspace.makeFixtures(count: 4))
        let library = try workspace.makeLibrary()
        _ = try library.importFolder(folder, mode: .connected)
        let items = try library.items()
        return (library, folder, items)
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Size ladder

    @Test("the ladder snaps up to the next bucket and never past the top")
    func bucketLadder() {
        #expect(ThumbnailStore.bucketSizes == [180, 270, 360, 450, 540])

        #expect(ThumbnailStore.bucket(forMaxPixel: 1) == 180)
        #expect(ThumbnailStore.bucket(forMaxPixel: 180) == 180)
        #expect(ThumbnailStore.bucket(forMaxPixel: 181) == 270)
        #expect(ThumbnailStore.bucket(forMaxPixel: 360) == 360)
        #expect(ThumbnailStore.bucket(forMaxPixel: 1_000) == 540)
        // Only the ladder is disk-backed; a lightbox-sized request is not.
        #expect(ThumbnailStore.isDiskBacked(maxPixel: 540))
        #expect(ThumbnailStore.isDiskBacked(maxPixel: 640) == false)
    }

    @Test("the thumbnail path is deterministic and sharded by content hash")
    func deterministicPath() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-path")
        let seeded = try seededConnected(workspace)
        defer { seeded.library.close() }

        let item = try #require(seeded.items.first)
        let store = seeded.library.thumbnails

        let a = store.url(forContentHash: item.contentHash, maxPixel: 360)
        let b = store.url(forContentHash: item.contentHash, maxPixel: 300) // same bucket
        let c = store.url(forContentHash: item.contentHash, maxPixel: 540)

        #expect(a == b)
        #expect(a != c)
        #expect(a.lastPathComponent == "\(item.contentHash)_360.jpg")
        // Sharded: thumbnails/<first two hex chars>/<file>
        #expect(a.deletingLastPathComponent().lastPathComponent == String(item.contentHash.prefix(2)))
        #expect(a.deletingLastPathComponent().deletingLastPathComponent() == store.root)
        #expect(c.lastPathComponent.hasSuffix("_540.jpg"))
    }

    // MARK: - Generation

    @Test("ensure writes a JPEG under thumbnails/ and returns it")
    func ensureCreatesFile() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-create")
        let seeded = try seededConnected(workspace)
        defer { seeded.library.close() }

        let item = try #require(seeded.items.first)

        #expect(seeded.library.thumbnailURLIfExists(for: item, maxPixel: 360) == nil)
        let url = try seeded.library.ensureThumbnail(for: item, maxPixel: 360)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "jpg")
        #expect(url.path.hasPrefix(seeded.library.paths.thumbnailsURL.path))
        #expect(seeded.library.thumbnailURLIfExists(for: item, maxPixel: 360) == url)
        // Nothing leaked into originals/ for a connected item.
        #expect(DirectoryStats.fileCount(in: seeded.library.paths.originalsURL) == 0)
        // The database's own counter agrees.
        #expect(try seeded.library.info().thumbnailsFileCount >= 1)
    }

    @Test("a second ensure does not rewrite a thumbnail whose fingerprint matches")
    func secondEnsureIsNoOp() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-idempotent")
        let seeded = try seededConnected(workspace)
        defer { seeded.library.close() }

        let item = try #require(seeded.items.first)
        let first = try seeded.library.ensureThumbnail(for: item, maxPixel: 360)
        let bytes = try Data(contentsOf: first)
        let writtenAt = try #require(modificationDate(first))

        // A second call (a scroll, a re-select, a relaunch) must not re-encode.
        let second = try seeded.library.ensureThumbnail(for: item, maxPixel: 360)
        let third = try seeded.library.ensureThumbnail(for: item, maxPixel: 300) // same bucket

        #expect(second == first)
        #expect(third == first)
        #expect(try Data(contentsOf: first) == bytes)
        #expect(modificationDate(first) == writtenAt)
    }

    @Test("each bucket is a separate file, generated only when asked for")
    func bucketsAreSeparateFiles() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-buckets")
        let seeded = try seededConnected(workspace)
        defer { seeded.library.close() }

        let item = try #require(seeded.items.first)
        let small = try seeded.library.ensureThumbnail(for: item, maxPixel: 180)
        #expect(seeded.library.thumbnails.fileCount() == 1)

        let large = try seeded.library.ensureThumbnail(for: item, maxPixel: 540)
        #expect(large != small)
        #expect(seeded.library.thumbnails.fileCount() == 2)
        #expect(FileManager.default.fileExists(atPath: small.path))
    }

    @Test("the JPEG records the fingerprint of the source version")
    func fingerprintIsRecorded() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-fingerprint")
        let seeded = try seededConnected(workspace)
        defer { seeded.library.close() }

        let item = try #require(seeded.items.first)
        let source = try #require(seeded.library.sourceURL(for: item))
        let url = try seeded.library.ensureThumbnail(for: item, maxPixel: 360)

        let expected = seeded.library.thumbnails.fingerprint(
            contentHash: item.contentHash,
            maxPixel: 360,
            sourceURL: source
        )
        #expect(seeded.library.thumbnails.storedFingerprint(at: url) == expected)
        #expect(seeded.library.thumbnails.isCurrent(
            url,
            contentHash: item.contentHash,
            maxPixel: 360,
            sourceURL: source
        ))
    }

    @Test("an in-place edit of a connected original invalidates and regenerates the thumbnail")
    func inPlaceEditRegenerates() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-invalidate")
        let seeded = try seededConnected(workspace)
        defer { seeded.library.close() }

        let item = try #require(seeded.items.first)
        let source = try #require(seeded.library.sourceURL(for: item))
        let url = try seeded.library.ensureThumbnail(for: item, maxPixel: 360)
        let before = try Data(contentsOf: url)

        // Replace the file behind the connected item — same path, different pixels.
        let replacement = try #require(Fixtures.all.first { $0.name != item.fileName })
        try replacement.data.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: source.path
        )

        #expect(seeded.library.thumbnails.isCurrent(
            url,
            contentHash: item.contentHash,
            maxPixel: 360,
            sourceURL: source
        ) == false)

        let regenerated = try seeded.library.ensureThumbnail(for: item, maxPixel: 360)
        #expect(regenerated == url)
        #expect(try Data(contentsOf: url) != before)
    }

    @Test("copied items generate from originals/<storedName>, not from the source path")
    func copiedItemsUseOriginals() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-copy")
        let folder = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }
        _ = try library.importFolder(folder, mode: .copy)

        let item = try #require(try library.items().first)
        #expect(item.mode == .copy)
        let source = try #require(library.sourceURL(for: item))
        #expect(source.path.hasPrefix(library.paths.originalsURL.path))

        let url = try library.ensureThumbnail(for: item, maxPixel: 360)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Deleting the *source* folder does not break the thumbnail: a copied library is
        // self-contained, which is the whole point of `.copy`.
        try FileManager.default.removeItem(at: folder)
        #expect(try library.ensureThumbnail(for: item, maxPixel: 360) == url)
    }

    @Test("connected items generate from the linked file and leave it alone")
    func connectedItemsUseSourcePath() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-connected")
        let seeded = try seededConnected(workspace)
        defer { seeded.library.close() }

        let item = try #require(seeded.items.first)
        #expect(item.mode == .connected)
        let source = try #require(seeded.library.sourceURL(for: item))
        #expect(source.path.hasPrefix(seeded.folder.path))

        let sourceBytes = try Data(contentsOf: source)
        let sourceDate = modificationDate(source)

        _ = try seeded.library.ensureThumbnail(for: item, maxPixel: 180)

        // Generation is read-only with respect to the user's file.
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(modificationDate(source) == sourceDate)
        #expect(DirectoryStats.fileCount(in: seeded.library.paths.originalsURL) == 0)
    }

    @Test("the generated thumbnail is bounded by the bucket and keeps its aspect ratio")
    func thumbnailIsBounded() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-size")
        // 120×90 → aspect 4:3; below every bucket, so ImageIO must not upscale it.
        let folder = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()
        defer { library.close() }
        _ = try library.importFolder(folder, mode: .connected)

        let item = try #require(try library.items().first { $0.fileName == "dusk.png" })
        #expect(item.width == 120)
        #expect(item.height == 90)

        let url = try library.ensureThumbnail(for: item, maxPixel: 180)
        let size = try #require(library.thumbnails.pixelSize(of: url))

        #expect(size.width <= 180 && size.height <= 180)
        // No upscale and no stretch.
        #expect(size.width == 120 && size.height == 90)
        #expect(abs(Double(size.width) / Double(size.height) - 4.0 / 3.0) < 0.05)
    }

    @Test("downsample reads a thumbnail without touching the original")
    func downsampleReadsFile() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-downsample")
        let seeded = try seededConnected(workspace)
        defer { seeded.library.close() }

        let item = try #require(seeded.items.first)
        let url = try seeded.library.ensureThumbnail(for: item, maxPixel: 360)
        let image = try #require(ThumbnailStore.downsample(url: url, maxPixel: 360))
        #expect(image.width <= 360)
        #expect(image.width > 0)
    }

    @Test("a missing source throws instead of writing an empty thumbnail")
    func missingSourceThrows() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-missing")
        let seeded = try seededConnected(workspace)
        defer { seeded.library.close() }

        let item = try #require(seeded.items.first)
        let source = try #require(seeded.library.sourceURL(for: item))
        try FileManager.default.removeItem(at: source)

        #expect(throws: AtlasError.self) {
            _ = try seeded.library.ensureThumbnail(for: item, maxPixel: 360)
        }
        // No zero-byte placeholder, no half-written temp file.
        #expect(seeded.library.thumbnailURLIfExists(for: item, maxPixel: 360) == nil)
        #expect(seeded.library.thumbnails.fileCount() == 0)
    }

    @Test("ensureAsync generates off the caller and agrees with the synchronous path")
    func asyncEnsure() async throws {
        let workspace = try TemporaryWorkspace(label: "thumb-async")
        let folder = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()
        _ = try library.importFolder(folder, mode: .connected)
        defer { library.close() }

        let item = try #require(try library.items().first)
        let expected = library.thumbnailURL(for: item, maxPixel: 360)
        #expect(!FileManager.default.fileExists(atPath: expected.path))

        let url = try await library.ensureThumbnailAsync(for: item, maxPixel: 360)
        #expect(url == expected)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test("thumbnails survive a library reopen")
    func survivesReopen() throws {
        let workspace = try TemporaryWorkspace(label: "thumb-reopen")
        let seeded = try seededConnected(workspace)
        let item = try #require(seeded.items.first)
        let url = try seeded.library.ensureThumbnail(for: item, maxPixel: 360)
        let writtenAt = try #require(modificationDate(url))
        seeded.library.close()

        let reopened = try workspace.makeLibrary()
        defer { reopened.close() }
        let reloaded = try #require(try reopened.item(id: item.id))
        #expect(try reopened.ensureThumbnail(for: reloaded, maxPixel: 360) == url)
        #expect(modificationDate(url) == writtenAt)
    }

    @Test("concurrent generation of the same thumbnail lands one complete file")
    func concurrentEnsure() async throws {
        let workspace = try TemporaryWorkspace(label: "thumb-concurrent")
        let folder = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()
        _ = try library.importFolder(folder, mode: .connected)
        defer { library.close() }

        let item = try #require(try library.items().first)
        let expected = library.thumbnailURL(for: item, maxPixel: 360)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await library.ensureThumbnailAsync(for: item, maxPixel: 360)
                }
            }
        }

        #expect(FileManager.default.fileExists(atPath: expected.path))
        // Atomic rename, so whatever won the race is a readable image, not a partial write.
        let size = try #require(library.thumbnails.pixelSize(of: expected))
        #expect(size.width > 0 && size.height > 0)
        // And it is still the file `ensure` trusts, so no rewrite is pending.
        let source = try #require(library.sourceURL(for: item))
        #expect(library.thumbnails.isCurrent(
            expected,
            contentHash: item.contentHash,
            maxPixel: 360,
            sourceURL: source
        ))
        #expect(library.thumbnails.fileCount() == 1)
    }
}
