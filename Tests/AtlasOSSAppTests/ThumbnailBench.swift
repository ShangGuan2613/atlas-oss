import AppKit
import AtlasCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtlasOSSApp

/// P1-F measurement harness — **not** part of the normal suite.
///
/// `swift test` skips it unless `ATLAS_BENCH=1`, because it seeds a real library (default
/// 1000 synthetic 1600×1200 files) and then times four passes over it:
///
/// | Pass | What it measures |
/// |---|---|
/// | `baseline` | the pre-P1f hot path: ImageIO downsample straight from the original, per cell |
/// | `cold` | P1f, nothing cached: generate + encode + decode one thumbnail per item |
/// | `warm` | P1f after a relaunch: memory cache empty, every thumbnail already on disk |
/// | `memory` | P1f scrolling back over realized tiles: pure LRU hits |
///
/// Run it with `scripts/bench-thumbs.sh`. The numbers it prints are the ones quoted in
/// `STATUS.md`; re-run rather than trust them.
@MainActor
final class ThumbnailBench: XCTestCase {

    // MARK: - Reporting

    struct Summary {
        let count: Int
        let totalMs: Double
        let meanMs: Double
        let p50Ms: Double
        let p95Ms: Double
        let p99Ms: Double

        static func of(_ samples: [Double]) -> Summary {
            guard !samples.isEmpty else {
                return Summary(count: 0, totalMs: 0, meanMs: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0)
            }
            let sorted = samples.sorted()
            func percentile(_ p: Double) -> Double {
                let index = min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1))
                return sorted[index]
            }
            let total = sorted.reduce(0, +)
            return Summary(
                count: sorted.count,
                totalMs: total,
                meanMs: total / Double(sorted.count),
                p50Ms: percentile(50),
                p95Ms: percentile(95),
                p99Ms: percentile(99)
            )
        }

        func line(_ label: String) -> String {
            String(
                format: "P1F-BENCH  %-9@ n=%4d  total=%8.1fms  mean=%6.3fms  p50=%6.3fms  p95=%6.3fms  p99=%6.3fms",
                label as NSString,
                count,
                totalMs,
                meanMs,
                p50Ms,
                p95Ms,
                p99Ms
            )
        }
    }

    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1_000_000 }

    // MARK: - Seeding

    /// Writes `count` deterministic 1600×1200 JPEGs. High-entropy pixels so the files are
    /// photo-sized (~400 KB) instead of compressing to nothing, which keeps the JPEG
    /// entropy-decode cost in the same league as a real capture.
    private func seedImages(count: Int, width: Int, height: Int, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height

        for index in 0..<count {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 4)
            defer { buffer.deallocate() }
            let pixels = buffer.bindMemory(to: UInt8.self, capacity: byteCount)
            var state = UInt32(truncatingIfNeeded: index &* 2_654_435_761 &+ 1)
            for offset in stride(from: 0, to: byteCount, by: 4) {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                let value = UInt8(truncatingIfNeeded: state >> 24)
                pixels[offset] = value
                pixels[offset + 1] = value ^ 0x5A
                pixels[offset + 2] = UInt8(truncatingIfNeeded: (state >> 8) & 0xFF)
                pixels[offset + 3] = 255
            }

            guard let context = CGContext(
                data: buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else {
                throw AtlasError.io("cannot build benchmark image \(index)")
            }

            let url = directory.appendingPathComponent(String(format: "shot-%04d.jpg", index))
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else {
                throw AtlasError.io("cannot write \(url.path)")
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else {
                throw AtlasError.io("cannot finalize \(url.path)")
            }
        }
    }

    // MARK: - Bench

    func testBenchGridThumbnails() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_BENCH"] == "1" else {
            throw XCTSkip("P1f bench: set ATLAS_BENCH=1 (or run scripts/bench-thumbs.sh)")
        }

        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["ATLAS_BENCH_COUNT"] ?? "") ?? 1_000
        let width = Int(environment["ATLAS_BENCH_WIDTH"] ?? "") ?? 1_600
        let height = Int(environment["ATLAS_BENCH_HEIGHT"] ?? "") ?? 1_200
        let denom = Double(count)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-bench-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("originals", isDirectory: true)
        let libraryURL = root.appendingPathComponent("bench.atlaslibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        print("P1F-BENCH  ===== disabled-startup: \(count) synthetic \(width)×\(height) JPEGs =====")
        print("P1F-BENCH  machine: \(machineSummary())")

        var started = now()
        try seedImages(count: count, width: width, height: height, into: sourceDirectory)
        let seedMs = ms(started, now())

        let library = try AtlasLibrary(url: libraryURL)
        started = now()
        let report = try library.importFolder(sourceDirectory, mode: .connected)
        let importMs = ms(started, now())
        let items = try library.items()

        print(String(
            format: "P1F-BENCH  seeded %d files in %.1fms (%.2fms/file), imported %d in %.1fms (%.2fms/file)",
            count, seedMs, seedMs / denom, report.imported, importMs, importMs / denom
        ))
        let sourceBytes = items.reduce(Int64(0)) { $0 + $1.byteSize }
        print(String(
            format: "P1F-BENCH  source volume: %d items, %.1f MB (%.0f KB/file)",
            items.count, Double(sourceBytes) / 1_048_576, Double(sourceBytes) / denom / 1_024
        ))

        // `ATLAS_BENCH_IMPORT_ONLY=1` stops after the import, leaving a library with **no**
        // thumbnails behind. bench-scroll.sh uses it to measure the cold first browse.
        if environment["ATLAS_BENCH_IMPORT_ONLY"] == "1" {
            print("P1F-BENCH  import-only: no thumbnails generated; kept workspace at \(root.path)")
            library.close()
            return
        }

        let bucket = GridDensity.thumbnailPixelSize(cellWidth: GridDensity.defaultCellWidth)
        print("P1F-BENCH  grid density \(Int(GridDensity.defaultCellWidth))pt → thumbnail bucket \(bucket)px")

        // MARK: baseline — decode the original in the cell, P1f's "before"
        var samples: [Double] = []
        var baselineBytes = 0
        samples.reserveCapacity(items.count)
        for item in items {
            guard let source = library.sourceURL(for: item) else { continue }
            let tick = now()
            let image = ThumbnailStore.downsample(url: source, maxPixel: bucket)
            samples.append(ms(tick, now()))
            baselineBytes += image.map { $0.bytesPerRow * $0.height } ?? 0
        }
        let baselineSummary = Summary.of(samples)
        print(baselineSummary.line("baseline"))
        print(String(format: "P1F-BENCH  baseline decoded pixels held: %.1f MB", Double(baselineBytes) / 1_048_576))

        // MARK: cold — nothing on disk, every cell pays generation
        let coldLoader = ThumbnailLoader()
        samples.removeAll(keepingCapacity: true)
        started = now()
        for item in items {
            guard let request = requestFor(item, library: library) else { continue }
            let tick = now()
            let image = await coldLoader.image(for: request, maxPixel: bucket)
            samples.append(ms(tick, now()))
            XCTAssertNotNil(image, "cold pass should produce a thumbnail for \(item.fileName)")
        }
        let coldTotal = ms(started, now())
        let coldSummary = Summary.of(samples)
        print(coldSummary.line("cold"))
        print(String(
            format: "P1F-BENCH  cold wall clock %.1fms (%.2fms/item); statistics %@",
            coldTotal, coldTotal / denom, describe(coldLoader.statistics())
        ))

        let thumbBytes = library.thumbnails.byteSize()
        let thumbFiles = library.thumbnails.fileCount()
        print(String(
            format: "P1F-BENCH  thumbnails/: %d files, %.1f MB (%.0f KB/item) = %.1f%% of source volume",
            thumbFiles, Double(thumbBytes) / 1_048_576, Double(thumbBytes) / denom / 1_024,
            sourceBytes > 0 ? Double(thumbBytes) / Double(sourceBytes) * 100 : 0
        ))

        // MARK: warm — relaunch: memory empty, disk full
        let warmLoader = ThumbnailLoader()
        samples.removeAll(keepingCapacity: true)
        started = now()
        for item in items {
            guard let request = requestFor(item, library: library) else { continue }
            let tick = now()
            let image = await warmLoader.image(for: request, maxPixel: bucket)
            samples.append(ms(tick, now()))
            XCTAssertNotNil(image)
        }
        let warmTotal = ms(started, now())
        let warmSummary = Summary.of(samples)
        print(warmSummary.line("warm"))
        let warmStats = warmLoader.statistics()
        print(String(format: "P1F-BENCH  warm wall clock %.1fms (%.2fms/item); statistics %@", warmTotal, warmTotal / denom, describe(warmStats)))
        XCTAssertEqual(warmStats.diskHits, items.count, "a warm pass must be answered by the disk tier")
        XCTAssertEqual(warmStats.originalFallbacks, 0, "no original should be decoded when a thumb exists")
        XCTAssertEqual(warmStats.generations, 0, "a warm pass must not re-encode anything")
        XCTAssertEqual(thumbFiles, library.thumbnails.fileCount(), "a warm pass must not add files")

        // MARK: memory — scrolling back over tiles that are still resident.
        //
        // A 96 MB budget holds roughly 250 tiles at 360 px, so a full 1000-item re-walk is
        // *meant* to spill to disk. What this pass answers is the realistic question: "I
        // scrolled away and came back one screen ago — is that free?"
        let windowSize = min(items.count, 240)
        let window = Array(items.suffix(windowSize))
        warmLoader.purgeMemoryCache()
        for item in window {
            guard let request = requestFor(item, library: library) else { continue }
            _ = await warmLoader.image(for: request, maxPixel: bucket)
        }
        warmLoader.resetStatistics()
        samples.removeAll(keepingCapacity: true)
        for item in window {
            guard let request = requestFor(item, library: library) else { continue }
            let tick = now()
            _ = await warmLoader.image(for: request, maxPixel: bucket)
            samples.append(ms(tick, now()))
        }
        let memorySummary = Summary.of(samples)
        print(memorySummary.line("memory"))
        let memoryStats = warmLoader.statistics()
        print(String(format: "P1F-BENCH  memory tier (%d-tile window): %@", windowSize, describe(memoryStats)))
        XCTAssertEqual(memoryStats.memoryHits, windowSize, "a resident window must be pure LRU hits")

        // MARK: verdict
        let speedup = baselineSummary.p95Ms / max(warmSummary.p95Ms, 0.000_001)
        print(String(
            format: "P1F-BENCH  RESULT p95 original-decode %.3fms vs thumb-decode %.3fms → %.1f× less work per tile",
            baselineSummary.p95Ms, warmSummary.p95Ms, speedup
        ))
        print(String(
            format: "P1F-BENCH  RESULT 60fps per-tile budget = 16.67ms; warm p95 is %.2f%% of it, baseline p95 is %.2f%%",
            warmSummary.p95Ms / 16.67 * 100, baselineSummary.p95Ms / 16.67 * 100
        ))
        print(String(
            format: "P1F-BENCH  RESULT cold generation %.2fms/item, warm read %.3fms/item, memory hit %.4fms/item",
            coldSummary.meanMs, warmSummary.meanMs, memorySummary.meanMs
        ))

        library.close()
        if environment["ATLAS_BENCH_KEEP"] != "1" {
            try? FileManager.default.removeItem(at: root)
        } else {
            print("P1F-BENCH  kept workspace at \(root.path)")
        }
    }

    private func requestFor(_ item: AtlasCore.LibraryItem, library: AtlasLibrary) -> ThumbnailRequest? {
        guard let source = library.sourceURL(for: item) else { return nil }
        return ThumbnailRequest(
            item: item,
            sourceURL: source,
            thumbnailsRoot: library.paths.thumbnailsURL
        )
    }

    private func describe(_ statistics: ThumbnailLoader.Statistics) -> String {
        "diskHits=\(statistics.diskHits) misses=\(statistics.diskMisses) "
            + "generations=\(statistics.generations) coalesced=\(statistics.coalescedRuns) "
            + "memoryHits=\(statistics.memoryHits) originalFallbacks=\(statistics.originalFallbacks) "
            + "cached=\(statistics.cachedImages) (\(statistics.cachedBytes / 1_048_576) MB)"
    }

    private func machineSummary() -> String {
        var size = 0
        var count: size_t = MemoryLayout<Int>.size
        sysctlbyname("hw.memsize", &size, &count, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(ProcessInfo.processInfo.processorCount) cores, \(size / 1_073_741_824) GB RAM, macOS \(os.majorVersion).\(os.minorVersion)"
    }
}
