import AppKit
import AtlasCore
import XCTest
@testable import AtlasOSSApp

/// P2-A measurement harness — **not** part of the normal suite.
///
/// `swift test` skips it unless `ATLAS_BENCH=1`, because it seeds a real library and then
/// times the four costs the Canvas pillar is judged on:
///
/// | Pass | What it measures |
/// |---|---|
/// | `reset` | `resetCanvasLayout` — one transaction writing N rows (the Reset Layout button) |
/// | `read` | `canvasPositions` for the whole board at open |
/// | `index` | rebuilding the uniform-grid spatial index after a layout change |
/// | `cull` | one viewport query per camera move, plus how many tiles that realises |
/// | `zoom` | one pointer-anchored zoom step (pure camera maths) |
///
/// P2-B adds `testBenchInfinityBoard` (`P2B-BENCH`): the same cull/zoom/commit costs over a
/// 500-item board with a satellite cluster a million points out, which is the geometry the
/// unbounded camera makes possible.
///
/// Run it with `scripts/bench-canvas.sh`. The numbers it prints are the ones quoted in
/// `STATUS.md`; re-run rather than trust them.
@MainActor
final class CanvasBench: XCTestCase {

    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1_000_000 }

    private func line(_ label: String, _ text: String) {
        print("P2A-BENCH  \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(text)")
    }

    private func infinityLine(_ label: String, _ text: String) {
        print("P2B-BENCH  \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(text)")
    }

    /// Cheap synthetic JPEGs: the Canvas bench never decodes pixels, it only needs rows.
    private func seedImages(count: Int, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0 ..< count {
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 12,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            for x in 0 ..< 16 {
                for y in 0 ..< 12 {
                    bitmap.setColor(
                        NSColor(
                            red: CGFloat(x) / 16,
                            green: CGFloat(index % 32) / 32,
                            blue: CGFloat(y) / 12,
                            alpha: 1
                        ),
                        atX: x, y: y
                    )
                }
            }
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: directory.appendingPathComponent(String(format: "shot-%04d.png", index)))
        }
    }

    func testBenchCanvasBoard() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_BENCH"] == "1" else {
            throw XCTSkip("P2-A bench: set ATLAS_BENCH=1 (or run scripts/bench-canvas.sh)")
        }
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["ATLAS_BENCH_COUNT"] ?? "") ?? 250
        let keep = environment["ATLAS_BENCH_KEEP"] == "1"

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-canvas-bench-\(UUID().uuidString)", isDirectory: true)
        defer {
            if !keep, workspace.lastPathComponent.hasPrefix("atlasoss-canvas-bench-") {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        let folder = workspace.appendingPathComponent("shots", isDirectory: true)
        try seedImages(count: count, into: folder)

        let root = workspace.appendingPathComponent("main.atlaslibrary", isDirectory: true)
        let library = try AtlasLibrary(url: root)
        let importStart = now()
        _ = try library.importFolder(folder, mode: .connected)
        let importMs = ms(importStart, now())
        line("import", String(format: "n=%d  total=%8.1fms", count, importMs))

        // reset — one transaction for the whole board.
        let resetStart = now()
        let placed = try library.resetCanvasLayout(collectionID: nil)
        let resetMs = ms(resetStart, now())
        line("reset", String(format: "n=%4d  total=%8.1fms  per-row=%6.3fms", placed, resetMs, resetMs / Double(max(1, placed))))

        // read — what opening the board costs.
        let readStart = now()
        let positions = try library.canvasPositions(collectionID: nil)
        let readMs = ms(readStart, now())
        line("read", String(format: "n=%4d  total=%8.1fms", positions.count, readMs))

        // index — rebuilt once per layout change, never per frame.
        let indexStart = now()
        var index = CanvasSpatialIndex(positions: positions)
        let indexMs = ms(indexStart, now())
        line("index", String(format: "n=%4d  total=%8.1fms", positions.count, indexMs))

        // cull — one query per camera move, measured twice: the whole board on screen (fit)
        // and a normal viewport at 1:1, which is what a pan actually asks for.
        let viewport = CGSize(width: 1_440, height: 900)
        func sweep(_ label: String, camera start: CanvasCamera) {
            var camera = start
            var samples: [Double] = []
            var realized: [Int] = []
            var offset = 0.0
            var direction = 1.0
            for step in 0 ..< 1_000 {
                let begin = now()
                let rect = camera.visibleWorldRect(viewport: viewport, margin: 600)
                let visible = index.itemIDs(in: rect)
                samples.append(ms(begin, now()) * 1_000)  // µs
                if step % 10 == 0 { realized.append(visible.count) }
                if offset >= 40 { direction = -1 }
                if offset <= -40 { direction = 1 }
                offset += direction
                camera = camera.panned(byViewDelta: CGSize(width: direction, height: direction * 0.3))
            }
            let sorted = samples.sorted()
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            line(
                label,
                String(
                    format: "queries=%d  mean=%6.2fµs  p95=%6.2fµs  realized(mean)=%5.1f of %d",
                    sorted.count, mean, p95,
                    Double(realized.reduce(0, +)) / Double(max(1, realized.count)), positions.count
                )
            )
        }

        let fitted = CanvasCamera.fitting(content: index.contentBounds, viewport: viewport)
        sweep("cull (fit)", camera: fitted)
        var oneToOne = CanvasCamera(zoom: 1)
        oneToOne.origin = CGPoint(x: index.contentBounds.midX - viewport.width / 2,
                                  y: index.contentBounds.midY - viewport.height / 2)
        sweep("cull (1:1)", camera: oneToOne)
        let camera = oneToOne

        // zoom — pure maths, no layout.
        let zoomStart = now()
        var zoomCamera = camera
        for _ in 0 ..< 10_000 {
            zoomCamera = zoomCamera.zoomed(by: 1.01, anchoredAt: CGPoint(x: 720, y: 450))
            zoomCamera = zoomCamera.zoomed(by: 1 / 1.01, anchoredAt: CGPoint(x: 720, y: 450))
        }
        let zoomUs = ms(zoomStart, now()) * 1_000 / 20_000
        line("zoom step", String(format: "mean=%6.3fµs per anchored zoom", zoomUs))

        // drag commit — one persisted move (the write a drag release performs).
        let target = positions[0]
        let commitStart = now()
        try library.setCanvasPosition(itemID: target.itemID, x: target.x + 25, y: target.y + 25, z: target.z)
        let commitMs = ms(commitStart, now())
        line("drag commit", String(format: "total=%8.3fms (1 row, 1 tx)", commitMs))

        // A 40-tile multi-drag: the batch path.
        let batch = Array(positions.prefix(40)).map {
            CanvasPlacement(itemID: $0.itemID, x: $0.x + 40, y: $0.y + 40, z: $0.z)
        }
        let batchStart = now()
        try library.setCanvasPositions(batch, collectionID: nil)
        let batchMs = ms(batchStart, now())
        line("multi-drag", String(format: "n=%4d  total=%8.3fms", batch.count, batchMs))

        library.close()
        if keep { print("P2A-BENCH  library kept at \(root.path)") }
    }

    // MARK: - P2-B (Infinity)

    /// The Infinity pass: 500 items, with a satellite cluster placed **a million points out** —
    /// coordinates the P2-A camera clamp made impossible and P2-B's culling has to survive.
    ///
    /// What it answers, in order: does one index query per camera move stay inside a frame
    /// budget at Infinity offsets; how many tiles does a viewport realise when the board spans
    /// 1 000 000 pt; and what does the 0.01 overview floor cost when Fit has to frame it all.
    func testBenchInfinityBoard() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_BENCH"] == "1" else {
            throw XCTSkip("P2-B bench: set ATLAS_BENCH=1 (or run scripts/bench-canvas.sh)")
        }
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["ATLAS_BENCH_INFINITY_COUNT"] ?? "") ?? 500
        let keep = environment["ATLAS_BENCH_KEEP"] == "1"

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-infinity-bench-\(UUID().uuidString)", isDirectory: true)
        defer {
            if !keep, workspace.lastPathComponent.hasPrefix("atlasoss-infinity-bench-") {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        let folder = workspace.appendingPathComponent("shots", isDirectory: true)
        try seedImages(count: count, into: folder)

        let root = workspace.appendingPathComponent("main.atlaslibrary", isDirectory: true)
        let library = try AtlasLibrary(url: root)
        _ = try library.importFolder(folder, mode: .connected)
        _ = try library.resetCanvasLayout(collectionID: nil)

        // Scatter: a third of the board pushed out to ±950 000 pt, the way an Infinity user
        // spreads a moodboard past any conceivable board edge.
        var positions = try library.canvasPositions(collectionID: nil)
        let satellite = Array(positions.prefix(count / 3))
        let satellites = satellite.enumerated().map { index, position in
            CanvasPlacement(
                itemID: position.itemID,
                x: 950_000 + Double(index % 20) * CanvasLayout.pitchX,
                y: -950_000 + Double(index / 20) * CanvasLayout.pitchY,
                z: position.z
            )
        }
        let scatterStart = now()
        try library.setCanvasPositions(satellites, collectionID: nil)
        let scatterMs = ms(scatterStart, now())
        infinityLine("scatter", String(format: "n=%4d  total=%8.3fms (satellite cluster at ±950 000 pt)", satellites.count, scatterMs))

        positions = try library.canvasPositions(collectionID: nil)

        let indexStart = now()
        let index = CanvasSpatialIndex(positions: positions)
        let indexMs = ms(indexStart, now())
        let bounds = index.contentBounds
        infinityLine("index", String(format: "n=%4d  total=%8.1fms  span=%9.0f × %9.0f pt", positions.count, indexMs, bounds.width, bounds.height))

        let viewport = CGSize(width: 1_440, height: 900)
        func sweep(_ label: String, camera start: CanvasCamera) {
            var camera = start
            var samples: [Double] = []
            var realized: [Int] = []
            var direction = 1.0
            var offset = 0.0
            for step in 0 ..< 1_000 {
                let begin = now()
                let visible = index.itemIDs(in: camera.visibleWorldRect(viewport: viewport, margin: 600))
                samples.append(ms(begin, now()) * 1_000)
                if step % 10 == 0 { realized.append(visible.count) }
                if offset >= 40 { direction = -1 }
                if offset <= -40 { direction = 1 }
                offset += direction
                camera = camera.panned(byViewDelta: CGSize(width: direction, height: direction * 0.3))
            }
            let sorted = samples.sorted()
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            infinityLine(
                label,
                String(
                    format: "queries=%d  mean=%6.2fµs  p95=%6.2fµs  realized(mean)=%5.1f of %d",
                    sorted.count, mean, p95,
                    Double(realized.reduce(0, +)) / Double(max(1, realized.count)), positions.count
                )
            )
        }

        // A normal viewport over the packed block, and one over the satellite cluster a million
        // points away — the case P2-A could not reach.
        var nearOrigin = CanvasCamera(zoom: 1)
        nearOrigin.origin = CGPoint(x: -720, y: -450)
        sweep("cull origin", camera: nearOrigin)

        var satelliteCamera = CanvasCamera(zoom: 1)
        satelliteCamera.origin = CGPoint(x: 949_000, y: -951_000)
        sweep("cull 950k", camera: satelliteCamera)

        // Fit at the overview floor: the whole thing on screen, which is the worst case.
        let fitted = CanvasCamera.fitting(content: bounds, viewport: viewport)
        infinityLine("fit zoom", String(format: "%.4f  (overview floor %.2f)", fitted.zoom, CanvasCamera.minZoom))
        let fitBegin = now()
        let fitVisible = index.itemIDs(in: fitted.visibleWorldRect(viewport: viewport, margin: 600))
        let fitUs = ms(fitBegin, now()) * 1_000
        infinityLine("cull (fit)", String(format: "n=%4d  one query=%7.2fµs  realized=%d", positions.count, fitUs, fitVisible.count))

        // Panning at the far edge of the practical extent: the cell-index range guard is what
        // keeps this a query rather than a crash.
        var extreme = CanvasCamera(origin: CGPoint(x: 990_000, y: 990_000), zoom: 1)
        let extremeBegin = now()
        let extremeVisible = index.itemIDs(in: extreme.visibleWorldRect(viewport: viewport, margin: 600))
        let extremeUs = ms(extremeBegin, now()) * 1_000
        infinityLine("cull 990k", String(format: "queries=1  %7.2fµs  realized=%d (empty board corner)", extremeUs, extremeVisible.count))
        extreme = extreme.panned(byViewDelta: CGSize(width: 10, height: 10))
        XCTAssertEqual(extreme.origin.x, 990_000 - 10, accuracy: 0.0001)

        // Drag commit from the satellite cluster: same one-transaction write as the Canvas.
        let target = satellites[0]
        let commitStart = now()
        try library.setCanvasPosition(itemID: target.itemID, x: target.x + 240, y: target.y, z: target.z)
        infinityLine("commit 950k", String(format: "total=%8.3fms (1 row, 1 tx)", ms(commitStart, now())))

        library.close()
        if keep { print("P2B-BENCH  library kept at \(root.path)") }
    }
}
