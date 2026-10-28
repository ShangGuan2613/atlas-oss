import CoreGraphics
import Foundation
import ImageIO

// MARK: - Swatch

/// One dominant colour of an image.
///
/// `hex` is always canonical: uppercase `#RRGGBB` in sRGB. `weight` is the share of the
/// sampled pixels that fell into this colour cluster (`0...1`), so a palette of five
/// swatches usually sums to slightly less than 1 — the leftover is the pixels that
/// merged into a neighbouring cluster.
public struct Swatch: Sendable, Hashable, Codable {
    /// Canonical `#RRGGBB` (uppercase, sRGB).
    public let hex: String
    /// Share of sampled pixels in this cluster, `0...1`.
    public let weight: Double

    public init(hex: String, weight: Double) {
        self.hex = ColorProbe.normalizedHex(hex) ?? "#000000"
        self.weight = max(0, weight)
    }

    /// sRGB components in `0...255`.
    public var rgb: (red: Int, green: Int, blue: Int)? {
        ColorProbe.rgbComponents(fromHex: hex)
    }
}

// MARK: - Probe

/// Dominant-colour extraction for a single image file.
///
/// Design notes:
/// * Sampling never full-decodes the original — `CGImageSourceCreateThumbnailAtIndex`
///   downsamples to a ≤64 px edge first, so a 50 MP HEIC costs about as much as a 64 px
///   PNG. That is the rule from AGENTS.md ("decode outside the render path").
/// * Pixels are quantised into 5-bit-per-channel buckets (32³ bins), then buckets are
///   greedily merged back together: a candidate is kept only when it is at least
///   `mergeDistance` away from every swatch already picked. 5 bits keeps two *visibly*
///   different colours out of the same bin while staying stable against noise.
/// * When merging would leave fewer than `minimumDistinctSwatches` results, a second pass
///   relaxes the distance so a nearly flat image still reports its shade plus its
///   neighbours rather than a single lonely swatch.
/// * Fully transparent pixels (alpha < 32) are skipped; premultiplied partially
///   transparent pixels are kept as-is (a negligible darkening for a palette).
public enum ColorProbe {
    /// How many swatches a palette reports by default.
    public static let defaultMaxColors = 5
    /// Palettes try to report at least this many shades, even for low-variance images.
    public static let minimumDistinctSwatches = 3
    /// Default matching distance for "find items with this colour" (see `distance`).
    public static let defaultTolerance = 40

    /// Long edge of the downsample used for sampling.
    static let sampleEdge = 64
    /// RGB L2 distance below which two clusters are considered the same colour.
    static let mergeDistance: Double = 32
    /// Relaxed distance used by the second pass for low-variance images.
    static let relaxedMergeDistance: Double = 8
    /// Bits kept per channel when bucketing (`32` levels per channel).
    static let bucketBits = 5
    /// Pixels at or below this alpha are ignored as noise / empty canvas.
    static let minimumAlpha: UInt8 = 32

    // MARK: - Extraction

    /// Dominant colours of an image file, ordered by prominence.
    ///
    /// Returns `[]` for videos, unreadable files, missing files and fully transparent
    /// images — callers treat "no palette" the same way everywhere.
    public static func swatches(for url: URL, maxColors: Int = defaultMaxColors) -> [Swatch] {
        guard maxColors > 0, let pixels = sampledPixels(of: url) else { return [] }
        return swatches(fromSRGBAPixels: pixels, maxColors: maxColors)
    }

    /// Histogram + merge pass. Split out from disk access so it is unit-testable with
    /// hand-built pixel buffers.
    static func swatches(fromSRGBAPixels bytes: [UInt8], maxColors: Int) -> [Swatch] {
        guard maxColors > 0, bytes.count >= 4 else { return [] }

        let bucketCount = 1 << (bucketBits * 3)
        var counts = [Int](repeating: 0, count: bucketCount)
        var sumsRed = [Int](repeating: 0, count: bucketCount)
        var sumsGreen = [Int](repeating: 0, count: bucketCount)
        var sumsBlue = [Int](repeating: 0, count: bucketCount)
        let shift = 8 - bucketBits
        var total = 0

        var index = 0
        while index + 3 < bytes.count {
            let red = Int(bytes[index])
            let green = Int(bytes[index + 1])
            let blue = Int(bytes[index + 2])
            let alpha = bytes[index + 3]
            index += 4
            guard alpha >= minimumAlpha else { continue }

            let bucket = ((red >> shift) << (bucketBits * 2))
                | ((green >> shift) << bucketBits)
                | (blue >> shift)
            counts[bucket] += 1
            sumsRed[bucket] += red
            sumsGreen[bucket] += green
            sumsBlue[bucket] += blue
            total += 1
        }
        guard total > 0 else { return [] }

        var candidates: [Cluster] = []
        candidates.reserveCapacity(min(bucketCount, 512))
        for bucket in 0 ..< bucketCount where counts[bucket] > 0 {
            let count = counts[bucket]
            let red = Int((Double(sumsRed[bucket]) / Double(count)).rounded())
            let green = Int((Double(sumsGreen[bucket]) / Double(count)).rounded())
            let blue = Int((Double(sumsBlue[bucket]) / Double(count)).rounded())
            candidates.append(
                Cluster(hex: hex(red: red, green: green, blue: blue), rgb: (red, green, blue), count: count)
            )
        }
        // Deterministic: prominence first, then hex so equal-weight buckets never flip.
        candidates.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.hex < rhs.hex : lhs.count > rhs.count
        }

        var picked = merge(candidates, minDistance: mergeDistance, limit: maxColors)
        let floor = min(maxColors, minimumDistinctSwatches)
        if picked.count < floor {
            let taken = Set(picked.map(\.hex))
            let rest = candidates.filter { !taken.contains($0.hex) }
            picked += merge(rest, minDistance: relaxedMergeDistance, limit: maxColors - picked.count)
        }

        return picked.map { cluster in
            Swatch(hex: cluster.hex, weight: Double(cluster.count) / Double(total))
        }
    }

    // MARK: - Colour maths

    /// Euclidean distance between two sRGB colours.
    ///
    /// A cheap stand-in for ΔE00: monotonic with perceptual distance, plenty for "find
    /// things that are roughly this colour". A tolerance of 40 is roughly "clearly the
    /// same family, obviously not identical"; 0 means an exact match.
    public static func distance(
        _ lhs: (red: Int, green: Int, blue: Int),
        _ rhs: (red: Int, green: Int, blue: Int)
    ) -> Double {
        let dr = Double(lhs.red - rhs.red)
        let dg = Double(lhs.green - rhs.green)
        let db = Double(lhs.blue - rhs.blue)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Distance between two hex strings, or `nil` when either is malformed.
    public static func distance(betweenHex lhs: String, andHex rhs: String) -> Double? {
        guard let a = rgbComponents(fromHex: lhs), let b = rgbComponents(fromHex: rhs) else { return nil }
        return distance(a, b)
    }

    /// `#RRGGBB` for the given components, clamped into `0...255`.
    public static func hex(red: Int, green: Int, blue: Int) -> String {
        let r = min(255, max(0, red))
        let g = min(255, max(0, green))
        let b = min(255, max(0, blue))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Canonical form of a hex colour: accepts `#RRGGBB`, `RRGGBB`, `#RGB` and `RGB`,
    /// case-insensitively; returns uppercase `#RRGGBB`, or `nil` when unparseable.
    public static func normalizedHex(_ raw: String) -> String? {
        var digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }

        switch digits.count {
        case 6:
            return "#" + digits.uppercased()
        case 3:
            let expanded = digits.map { "\($0)\($0)" }.joined()
            return "#" + expanded.uppercased()
        default:
            return nil
        }
    }

    /// sRGB components of a hex colour, or `nil` when unparseable.
    public static func rgbComponents(fromHex hex: String) -> (red: Int, green: Int, blue: Int)? {
        guard let canonical = normalizedHex(hex) else { return nil }
        let digits = canonical.dropFirst()
        guard let value = Int(digits, radix: 16) else { return nil }
        return (red: (value >> 16) & 0xFF, green: (value >> 8) & 0xFF, blue: value & 0xFF)
    }

    // MARK: - Sampling

    /// Downsampled sRGB(A) pixels for a file, or `nil` when it is not a readable image.
    static func sampledPixels(of url: URL, maxPixelSize: Int = sampleEdge) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return pixels(from: image)
    }

    /// Draws an image into an 8-bit sRGB buffer (`RGBA`, premultiplied) and hands back the
    /// raw bytes, or `nil` when the bitmap context cannot be created.
    static func pixels(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let drew: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? buffer : nil
    }

    // MARK: - Internals

    /// One quantisation bucket, averaged back into a colour.
    struct Cluster: Equatable {
        let hex: String
        let rgb: (red: Int, green: Int, blue: Int)
        let count: Int

        static func == (lhs: Cluster, rhs: Cluster) -> Bool {
            lhs.hex == rhs.hex && lhs.count == rhs.count
        }
    }

    /// Greedy farthest-first pick: keep a candidate only when it is far enough from every
    /// colour already chosen.
    private static func merge(_ candidates: [Cluster], minDistance: Double, limit: Int) -> [Cluster] {
        guard limit > 0 else { return [] }
        var chosen: [Cluster] = []
        var seen = Set<String>()
        for candidate in candidates {
            guard chosen.count < limit else { break }
            guard seen.insert(candidate.hex).inserted else { continue }
            let tooClose = chosen.contains { distance($0.rgb, candidate.rgb) < minDistance }
            if tooClose { continue }
            chosen.append(candidate)
        }
        return chosen
    }
}
