import AppKit
import AtlasCore
import SwiftUI
import XCTest
@testable import AtlasOSSApp

/// Offscreen render smoke tests for the grid tile and the lightbox.
///
/// These catch the failure mode that unit tests cannot: a SwiftUI body that traps or
/// silently produces nothing at a given density. Set `ATLAS_RENDER_OUT` to a directory
/// to also keep the PNGs for eyeballing.
@MainActor
final class RenderSmokeTests: XCTestCase {

    private static let item = AtlasCore.LibraryItem(
        id: UUID(),
        kind: .image,
        mode: .connected,
        fileName: "IMG_0042.heic",
        sourcePath: "/tmp/IMG_0042.heic",
        storedName: nil,
        width: 3024,
        height: 4032,
        byteSize: 2_411_522,
        contentHash: "deadbeef",
        importedAt: Date(timeIntervalSince1970: 0),
        fileCreatedAt: nil,
        fileModifiedAt: nil
    )

    func testItemCellRendersAtEveryDensityExtreme() throws {
        for width in [GridDensity.minCellWidth, GridDensity.defaultCellWidth, GridDensity.maxCellWidth] {
            let size = NSSize(width: width, height: width + 60)
            let image = try render(
                ItemCell(item: Self.item, url: nil, cellWidth: width, isSelected: true),
                size: size,
                name: "cell-\(Int(width))"
            )
            XCTAssertEqual(image.size.width, size.width, accuracy: 0.5)
            XCTAssertGreaterThan(image.size.height, 0)
        }
    }

    func testItemCellRendersUnselected() throws {
        _ = try render(
            ItemCell(item: Self.item, url: nil, cellWidth: GridDensity.defaultCellWidth, isSelected: false),
            size: NSSize(width: 200, height: 260),
            name: "cell-unselected"
        )
    }

    func testLightboxRendersWithoutASourceFile() throws {
        let view = LightboxView(
            item: Self.item,
            url: nil,
            index: 0,
            total: 11,
            onClose: {},
            onStep: { _ in }
        )
        _ = try render(view, size: NSSize(width: 900, height: 640), name: "lightbox")
    }

    func testSidebarRowLabelRendersInEveryState() throws {
        let states: [(String, String, Int, Bool, Bool, Color?, SidebarDropZone?)] = [
            ("plain", "folder", 0, false, false, nil, nil),
            ("selected", "folder", 12, true, false, nil, nil),
            ("hovered", "tray", 3, false, true, nil, nil),
            ("drop-onto", "folder", 7, false, false, nil, .onto),
            ("drop-before", "folder", 7, false, false, nil, .before),
            ("drop-after", "folder", 7, false, false, nil, .after),
            ("tag", "number", 99, true, false, Color.orange, nil),
        ]
        for state in states {
            let view = SidebarRowLabel(
                title: state.1 == "folder" ? "A very long collection name that truncates" : "Inbox",
                systemImage: state.1,
                count: state.2,
                isSelected: state.3,
                isHovered: state.4,
                tagColor: state.5,
                zone: state.6
            )
            _ = try render(view, size: NSSize(width: 220, height: 26), name: "sidebar-row-\(state.0)")
        }
    }

    func testNameEntrySheetRenders() throws {
        let request = NamingRequest(kind: .newCollection(parentID: UUID()), initial: "")
        let view = NameEntrySheet(request: request, onSubmit: { _ in }, onCancel: {})
        _ = try render(view, size: NSSize(width: 320, height: 150), name: "sidebar-name-sheet")
    }

    // MARK: - Info panel (P1-C)

    func testInfoPanelRendersEmptySingleAndMulti() throws {
        let empty = InfoPanelView(
            summary: InfoSummary(items: []),
            swatches: [],
            tagBadges: [],
            collectionChips: [],
            previewURL: nil,
            addableTags: [],
            isLoadingSwatches: false
        )
        _ = try render(empty, size: NSSize(width: 300, height: 420), name: "info-empty")

        let single = InfoPanelView(
            summary: InfoSummary(items: [Self.item], location: "/tmp/IMG_0042.heic"),
            swatches: Self.palette,
            tagBadges: [
                TagBadge(tag: Self.tag("hero"), itemCount: 1, total: 1),
                TagBadge(tag: Self.tag("dark"), itemCount: 1, total: 1),
            ],
            collectionChips: [
                CollectionChip(collection: Self.collection("Inbox", isInbox: true), itemCount: 1, total: 1),
                CollectionChip(collection: Self.collection("References"), itemCount: 1, total: 1),
            ],
            previewURL: nil,
            addableTags: [Self.tag("unused")],
            isLoadingSwatches: false
        )
        _ = try render(single, size: NSSize(width: 300, height: 640), name: "info-single")

        let multi = InfoPanelView(
            summary: InfoSummary(items: [Self.item, Self.secondItem]),
            swatches: Self.palette,
            tagBadges: [TagBadge(tag: Self.tag("hero"), itemCount: 2, total: 2)],
            collectionChips: [
                CollectionChip(collection: Self.collection("Inbox", isInbox: true), itemCount: 1, total: 2),
            ],
            previewURL: nil,
            addableTags: [Self.tag("dark")],
            isLoadingSwatches: true
        )
        _ = try render(multi, size: NSSize(width: 300, height: 640), name: "info-multi")
    }

    func testSwatchStripAndColorFilterChipRender() throws {
        _ = try render(
            SwatchStrip(swatches: Self.palette, onSelect: { _ in }),
            size: NSSize(width: 280, height: 60),
            name: "swatch-strip"
        )
        _ = try render(
            ColorFilterChip(hex: "#C81E1E", count: 4, onClear: {}),
            size: NSSize(width: 200, height: 34),
            name: "color-filter-chip"
        )
    }

    // MARK: - Info fixtures

    private static let secondItem = AtlasCore.LibraryItem(
        id: UUID(),
        kind: .video,
        mode: .copy,
        fileName: "clip.mp4",
        sourcePath: nil,
        storedName: "deadbeef.mp4",
        width: 1920,
        height: 1080,
        byteSize: 1_048_576,
        contentHash: "cafebabe",
        importedAt: Date(timeIntervalSince1970: 0),
        fileCreatedAt: nil,
        fileModifiedAt: nil
    )

    private static let palette = [
        Swatch(hex: "#C81E1E", weight: 0.52),
        Swatch(hex: "#8A1010", weight: 0.27),
        Swatch(hex: "#1E3CC8", weight: 0.12),
        Swatch(hex: "#F0D0D0", weight: 0.09),
    ]

    private static func tag(_ name: String) -> LibraryTag {
        LibraryTag(id: UUID(), name: name, createdAt: Date(timeIntervalSince1970: 0), color: nil)
    }

    private static func collection(_ name: String, isInbox: Bool = false) -> LibraryCollection {
        LibraryCollection(
            id: UUID(),
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            itemCount: 1,
            isInbox: isInbox
        )
    }

    // MARK: - Appearance settings (P1-D)

    func testAppearanceSettingsViewRendersWithDefaultsAndExtremes() throws {
        let store = AppearanceStore.ephemeral(suiteName: "atlas.appearance.render.settings")
        _ = try render(
            AppearanceSettingsView().environmentObject(store),
            size: NSSize(width: 520, height: 640),
            name: "appearance-settings-default"
        )

        store.tokens = AppearanceTokens(
            spacing: 4,
            cornerRadius: 20,
            backgroundStyle: .solid,
            colorScheme: .dark,
            selectionOpacity: 0.6
        )
        _ = try render(
            AppearanceSettingsView().environmentObject(store),
            size: NSSize(width: 520, height: 640),
            name: "appearance-settings-extreme"
        )
    }

    func testAppearancePreviewStripRendersAtTokenExtremes() throws {
        let states: [(String, AppearanceTokens)] = [
            ("default", .default),
            ("dense", AppearanceTokens(spacing: 4, cornerRadius: 0, selectionOpacity: 0.4)),
            ("roomy", AppearanceTokens(spacing: 24, cornerRadius: 20, backgroundStyle: .solid)),
        ]
        for (name, tokens) in states {
            _ = try render(
                AppearancePreviewStrip(tokens: tokens),
                size: NSSize(width: 340, height: 150),
                name: "appearance-preview-\(name)"
            )
        }
    }

    func testItemCellRendersWithInjectedTokens() throws {
        // A zero-radius, tight-gutter tile must still lay out (the P1-A bounds test only
        // covers the default tokens).
        for tokens in [AppearanceTokens(spacing: 4, cornerRadius: 0), AppearanceTokens(spacing: 24, cornerRadius: 20)] {
            _ = try render(
                ItemCell(item: Self.item, url: nil, cellWidth: 200, isSelected: true)
                    .environment(\.appearance, tokens),
                size: NSSize(width: 200, height: 260),
                name: "cell-tokens-\(Int(tokens.spacing))"
            )
        }
    }

    func testTokenChangeChangesRenderedPixels() throws {
        // Proof that tokens actually reach pixels: the same view at two extremes must not
        // rasterise identically (this is the offscreen stand-in for "change spacing and the
        // grid updates").
        let size = NSSize(width: 340, height: 150)
        let defaults = try render(
            AppearancePreviewStrip(tokens: .default),
            size: size,
            name: "appearance-preview-pixels-default"
        )
        let extreme = try render(
            AppearancePreviewStrip(
                tokens: AppearanceTokens(
                    spacing: 24,
                    cornerRadius: 20,
                    backgroundStyle: .solid,
                    selectionOpacity: 0.6
                )
            ),
            size: size,
            name: "appearance-preview-pixels-extreme"
        )
        XCTAssertNotEqual(defaults.tiffRepresentation, extreme.tiffRepresentation)
    }

    // MARK: - Canvas board (P2-A)

    /// Builds a throwaway library with `count` imported images and a model pointed at it.
    private func makeCanvasModel(itemCount: Int) throws -> (LibraryModel, URL) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-canvas-render-\(UUID().uuidString)", isDirectory: true)
        let folder = workspace.appendingPathComponent("shots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..< itemCount {
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            for x in 0 ..< 4 {
                for y in 0 ..< 4 {
                    bitmap.setColor(
                        NSColor(red: CGFloat(x) / 4, green: CGFloat(index) / CGFloat(max(1, itemCount)), blue: CGFloat(y) / 4, alpha: 1),
                        atX: x, y: y
                    )
                }
            }
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("shot-\(index).png"))
        }

        let root = workspace.appendingPathComponent("main.atlaslibrary", isDirectory: true)
        let seed = try AtlasLibrary(url: root)
        _ = try seed.importFolder(folder, mode: .connected)
        seed.close()

        let model = LibraryModel()
        model.open(at: root)
        model.select(.all)
        model.reloadCanvasPositions()
        return (model, workspace)
    }

    private func renderCanvas(
        _ model: LibraryModel,
        zoom: Double?,
        unbounded: Bool = false,
        name: String
    ) throws -> NSImage {
        let board = CanvasBoardState()
        board.viewport = CGSize(width: 800, height: 600)
        board.fit(content: model.canvasContentBounds)
        if let zoom {
            board.camera = CanvasCamera(origin: board.camera.origin, zoom: zoom)
        }
        let view = CanvasView(
            board: board,
            selection: .constant(ItemSelection()),
            unbounded: unbounded,
            onOpenLightbox: { _ in }
        )
        .environmentObject(model)
        return try render(view, size: NSSize(width: 800, height: 600), name: name)
    }

    func testCanvasBoardRendersAtBothLODSteps() throws {
        let (model, workspace) = try makeCanvasModel(itemCount: 6)
        defer {
            if workspace.lastPathComponent.hasPrefix("atlasoss-canvas-render-") {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        // Fitted: captions on (LOD `.labeled`).
        let fitted = try renderCanvas(model, zoom: nil, name: "canvas-board-fitted")
        // Zoomed out past the caption threshold: LOD `.tiles`, dot grid still legible (pitch
        // 48.8 pt at 0.2×), so this exercises both steps of the ladder.
        let zoomedOut = try renderCanvas(model, zoom: 0.2, name: "canvas-board-zoomed-out")

        XCTAssertGreaterThan(fitted.size.width, 0)
        // Proof the camera reaches pixels: the same board at two zooms cannot rasterise the same.
        XCTAssertNotEqual(fitted.tiffRepresentation, zoomedOut.tiffRepresentation)
    }

    func testInfinityRendersWithoutTheBoardFrame() throws {
        let (model, workspace) = try makeCanvasModel(itemCount: 6)
        defer {
            if workspace.lastPathComponent.hasPrefix("atlasoss-canvas-render-") {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        // Far enough out that Canvas's dashed board frame (16 000 pt × 0.05 = 800 pt) is on
        // screen: Infinity draws no frame, so the two surfaces must not rasterise the same.
        let canvas = try renderCanvas(model, zoom: 0.05, unbounded: false, name: "canvas-board-framed")
        let infinity = try renderCanvas(model, zoom: 0.05, unbounded: true, name: "infinity-board-frameless")
        XCTAssertNotEqual(canvas.tiffRepresentation, infinity.tiffRepresentation)
    }

    func testCanvasBoardRendersEmpty() throws {
        let (model, workspace) = try makeCanvasModel(itemCount: 0)
        defer {
            if workspace.lastPathComponent.hasPrefix("atlasoss-canvas-render-") {
                try? FileManager.default.removeItem(at: workspace)
            }
        }
        _ = try renderCanvas(model, zoom: nil, name: "canvas-board-empty")
    }

    // MARK: - Helpers

    private func render<Content: View>(_ view: Content, size: NSSize, name: String) throws -> NSImage {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw XCTSkip("No bitmap representation available in this environment")
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)

        if let directory = ProcessInfo.processInfo.environment["ATLAS_RENDER_OUT"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            try? png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
        }

        XCTAssertGreaterThan(rep.pixelsWide, 0, "\(name) rendered no pixels")
        return image
    }
}
