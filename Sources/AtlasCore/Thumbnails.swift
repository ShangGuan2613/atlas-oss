import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// On-disk thumbnail cache under `<library>/thumbnails/`.
///
/// P1f: the grid must never decode an original on the hot path. A thumbnail is generated
/// **once** per (content, size bucket), written as JPEG next to the library, and reused by
/// every cell that shows the item afterwards — including after a relaunch, which is the
/// part an in-memory cache alone cannot give you.
///
/// Layout (content-hash sharded so one directory never holds 10k files):
///
/// ```
/// thumbnails/
/// └── ab/
///     └── abcdef…<sha256>_360.jpg
/// ```
///
/// Everything here is *derived* data. Deleting `thumbnails/` is always safe; the ladder
/// rebuilds on demand. Nothing in the library database points at these files, so the
/// cache can never desync the catalogue.
public struct ThumbnailStore: Sendable {

    // MARK: - Size ladder

    /// The size ladder. One file per bucket, generated only when a view asks for it, so a
    /// library browsed at one density holds one thumbnail per item.
    ///
    /// Gaps are deliberate: `PhotoPrism`-style ladders trade a few redundant pixels for far
    /// fewer files. 180 ≈ minimum cell width, 360 ≈ default cell width at 1.8×, 540 ≈ the
    /// densest grid (360 pt cell at 1.5× scale) with headroom for Retina.
    public static let bucketSizes: [Int] = [180, 270, 360, 450, 540]

    public static let defaultMaxPixel = 360

    /// Smallest bucket that covers `maxPixel`; never upscales past the ladder's top.
    public static func bucket(forMaxPixel maxPixel: Int) -> Int {
        let target = max(1, maxPixel)
        return bucketSizes.first { $0 >= target } ?? bucketSizes[bucketSizes.count - 1]
    }

    /// True when `maxPixel` is served by the ladder (i.e. worth a disk file). Larger
    /// requests — the lightbox and the Info preview — deliberately bypass the store and
    /// downsample the original instead: they are one-at-a-time, not a hot path, and a
    /// 1000px bucket would multiply the cache size for no browsing benefit.
    public static func isDiskBacked(maxPixel: Int) -> Bool {
        maxPixel <= (bucketSizes.last ?? defaultMaxPixel)
    }

    /// JPEG quality. 0.82 is visually lossless at these sizes and roughly half the bytes of
    /// 1.0 — the ladder is a cache, not an edit.
    public static let jpegQuality: Double = 0.82

    // MARK: - Location

    /// The `thumbnails/` directory itself.
    public let root: URL
    /// `FileManager.default` is documented as safe to call from any thread; the isolated
    /// flag states that here so `ThumbnailStore` stays `Sendable` for the async path.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
    }

    public init(paths: LibraryPaths, fileManager: FileManager = .default) {
        self.init(root: paths.thumbnailsURL, fileManager: fileManager)
    }

    /// Two-character shard so a 10k-item library spreads across 256 directories instead of
    /// one flat one.
    private func shardDirectory(for contentHash: String) -> URL {
        let prefix = String(contentHash.prefix(2))
        let shard = prefix.count == 2 ? prefix.lowercased() : "00"
        return root.appendingPathComponent(shard, isDirectory: true)
    }

    /// Thumbnail path for a content hash at a bucket. Deterministic — the same item always
    /// maps to the same file, which is what makes "generate once, reuse forever" work and
    /// lets a cell check for a thumb with a `stat` instead of touching the source.
    public func url(forContentHash contentHash: String, maxPixel: Int) -> URL {
        let bucket = Self.bucket(forMaxPixel: maxPixel)
        return shardDirectory(for: contentHash)
            .appendingPathComponent("\(contentHash)_\(bucket).jpg", isDirectory: false)
    }

    /// Existing thumbnail for the bucket, or `nil` when it was never generated.
    public func existingURL(forContentHash contentHash: String, maxPixel: Int) -> URL? {
        let candidate = url(forContentHash: contentHash, maxPixel: maxPixel)
        guard fileManager.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// File count under `thumbnails/`, for `info` and the bench.
    public func fileCount() -> Int {
        DirectoryStats.fileCount(in: root, fileManager: fileManager)
    }

    public func byteSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Fingerprint

    /// Cache fingerprint for one (item, bucket) thumbnail.
    ///
    /// Same shape as `paletteSignature`: identity (content hash) + the *live* source size
    /// and mtime. The live values are what let an in-place edit of a **connected** original
    /// invalidate its thumbnail without re-importing the library.
    public func fingerprint(
        contentHash: String,
        maxPixel: Int,
        sourceURL: URL
    ) -> String {
        let bucket = Self.bucket(forMaxPixel: maxPixel)
        let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = Int64(((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000).rounded())
        return "v1|\(contentHash)|\(bucket)|\(size)|\(modified)"
    }

    /// Fingerprint recorded inside an existing thumbnail, read from the JPEG header only
    /// (no pixel decode).
    ///
    /// Stored in EXIF `UserComment` because that is the one key ImageIO round-trips through
    /// a JPEG unchanged (`kCGImagePropertyTIFFImageDescription` is silently rerouted into
    /// IPTC Caption on JPEG output). TIFF and IPTC are still read as fallbacks so a
    /// thumbnail written by a future non-JPEG encoder is not thrown away.
    public func storedFingerprint(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let comment = exif[kCGImagePropertyExifUserComment] as? String {
            return comment
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let description = tiff[kCGImagePropertyTIFFImageDescription] as? String {
            return description
        }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           let caption = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String {
            return caption
        }
        return nil
    }

    /// True when the file on disk is still the thumbnail of this exact source version.
    ///
    /// The check is a header parse, not a decode, so a warm scroll of 10k cells costs 10k
    /// tiny reads — and, because `ThumbnailLoader` only asks once per item, in practice a
    /// single `stat` per realized cell.
    public func isCurrent(
        _ url: URL,
        contentHash: String,
        maxPixel: Int,
        sourceURL: URL
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let expected = fingerprint(contentHash: contentHash, maxPixel: maxPixel, sourceURL: sourceURL)
        guard storedFingerprint(at: url) == expected else { return false }
        return true
    }

    // MARK: - Generation

    /// Generates the thumbnail if it is missing or stale; returns the file to read.
    ///
    /// Synchronous and safe to call from any thread: generation happens on the calling
    /// thread and the result lands by atomic `rename`, so a concurrent reader either sees
    /// the previous complete file or the new complete one, never a partial write. The app
    /// calls this from a utility-priority `Task`, never from a view render.
    ///
    /// - Throws: `AtlasError.pathNotFound` when the source is gone,
    ///   `AtlasError.unsupported` when the source is not something ImageIO can read
    ///   (videos), `AtlasError.io` when the write fails.
    /// - Returns: the thumbnail URL, already present on disk.
    @discardableResult
    public func ensure(
        contentHash: String,
        maxPixel: Int,
        sourceURL: URL
    ) throws -> URL {
        let bucket = Self.bucket(forMaxPixel: maxPixel)
        let destination = url(forContentHash: contentHash, maxPixel: bucket)

        if isCurrent(destination, contentHash: contentHash, maxPixel: bucket, sourceURL: sourceURL) {
            return destination
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AtlasError.pathNotFound(sourceURL.path)
        }

        let fingerprint = fingerprint(
            contentHash: contentHash,
            maxPixel: bucket,
            sourceURL: sourceURL
        )
        try writeThumbnail(sourceURL: sourceURL, destination: destination, bucket: bucket, fingerprint: fingerprint)
        return destination
    }

    /// `ensure` off the caller's actor. The app uses this so a scroll never blocks on
    /// ImageIO; tests use the synchronous form so they can assert without awaiting.
    public func ensureAsync(
        contentHash: String,
        maxPixel: Int,
        sourceURL: URL
    ) async throws -> URL {
        try await Task.detached(priority: .utility) { [self] in
            try ensure(contentHash: contentHash, maxPixel: maxPixel, sourceURL: sourceURL)
        }.value
    }

    private func writeThumbnail(
        sourceURL: URL,
        destination: URL,
        bucket: Int,
        fingerprint: String
    ) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw AtlasError.unsupported("no ImageIO source for \(sourceURL.path)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AtlasError.unsupported("cannot downsample \(sourceURL.path) to \(bucket)px")
        }

        let directory = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AtlasError.io("cannot create \(directory.path): \(error.localizedDescription)")
        }

        // Unique temp name beside the destination: same filesystem, so the final rename is
        // atomic. A crash mid-write leaves a `.tmp` behind, never a half-written thumb.
        let temp = directory.appendingPathComponent(".tmp-\(UUID().uuidString).jpg")
        defer { try? fileManager.removeItem(at: temp) }

        guard let sipsDestination = CGImageDestinationCreateWithURL(
            temp as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AtlasError.io("cannot open \(temp.path) for writing")
        }

        // The fingerprint rides in EXIF `UserComment`: re-reading it is a header parse, so
        // validation costs the same whether the JPEG is 4 KB or 40 KB.
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Self.jpegQuality,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: fingerprint,
            ],
        ]
        CGImageDestinationAddImage(sipsDestination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(sipsDestination) else {
            throw AtlasError.io("cannot encode thumbnail for \(sourceURL.lastPathComponent)")
        }

        guard rename(temp.path, destination.path) == 0 else {
            throw AtlasError.io("cannot move thumbnail into place at \(destination.path)")
        }
    }

    // MARK: - Read

    /// Decodes a thumbnail file (or any image) at `maxPixel`, honouring EXIF orientation.
    ///
    /// This is the only decode the grid is allowed to do. It never touches the original.
    public static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel size of a thumbnail on disk, for tests and diagnostics. `nil` when unreadable.
    public func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let width, let height else { return nil }
        return (width, height)
    }
}

// MARK: - Library surface

extension AtlasLibrary {

    /// The disk thumbnail cache for this library.
    public var thumbnails: ThumbnailStore {
        ThumbnailStore(paths: paths, fileManager: fileManager)
    }

    /// The file an item's pixels come from — `originals/<storedName>` for copied items,
    /// the linked path for connected ones. Thin alias of `fileURL(for:)` so the thumbnail
    /// story reads as one vocabulary.
    public func sourceURL(for item: LibraryItem) -> URL? {
        fileURL(for: item)
    }

    /// Where this item's thumbnail *would* live, generated or not.
    public func thumbnailURL(for item: LibraryItem, maxPixel: Int = ThumbnailStore.defaultMaxPixel) -> URL {
        thumbnails.url(forContentHash: item.contentHash, maxPixel: maxPixel)
    }

    /// Existing thumbnail for the bucket, or `nil` when it was never generated.
    public func thumbnailURLIfExists(
        for item: LibraryItem,
        maxPixel: Int = ThumbnailStore.defaultMaxPixel
    ) -> URL? {
        thumbnails.existingURL(forContentHash: item.contentHash, maxPixel: maxPixel)
    }

    /// Generates (once) and returns the thumbnail for an item.
    ///
    /// Works for both import modes: a copied item reads `originals/<storedName>`, a
    /// connected item reads its linked file in place. Neither mode is ever asked to copy
    /// bytes to make a thumbnail.
    @discardableResult
    public func ensureThumbnail(
        for item: LibraryItem,
        maxPixel: Int = ThumbnailStore.defaultMaxPixel
    ) throws -> URL {
        guard let source = sourceURL(for: item) else {
            throw AtlasError.unsupported("item \(item.id.uuidString) has no backing file")
        }
        return try thumbnails.ensure(
            contentHash: item.contentHash,
            maxPixel: maxPixel,
            sourceURL: source
        )
    }

    /// `ensureThumbnail` for callers that must not block their actor (the app's cells).
    @discardableResult
    public func ensureThumbnailAsync(
        for item: LibraryItem,
        maxPixel: Int = ThumbnailStore.defaultMaxPixel
    ) async throws -> URL {
        guard let source = sourceURL(for: item) else {
            throw AtlasError.unsupported("item \(item.id.uuidString) has no backing file")
        }
        return try await thumbnails.ensureAsync(
            contentHash: item.contentHash,
            maxPixel: maxPixel,
            sourceURL: source
        )
    }
}
