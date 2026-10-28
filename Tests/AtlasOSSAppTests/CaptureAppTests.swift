import AppKit
import AtlasCore
import XCTest
@testable import AtlasOSSApp

/// P1-E app layer: pasteboard parsing, the drop-destination rule, and `CaptureCenter` wiring
/// a drop all the way to a reloaded model + a banner.
///
/// The menu-bar item is never installed here (`installMenuBar: false`): these tests run in a
/// plain test process without a status bar, and the pin is verified manually per STATUS.md.
@MainActor
final class CaptureAppTests: XCTestCase {

    private var workspace: URL!
    private var libraryRoot: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-capture-\(UUID().uuidString)", isDirectory: true)
        libraryRoot = workspace.appendingPathComponent("main.atlaslibrary", isDirectory: true)
        scratch = workspace.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace,
           workspace.path.hasPrefix(FileManager.default.temporaryDirectory.path),
           workspace.lastPathComponent.hasPrefix("atlasoss-capture-") {
            try? FileManager.default.removeItem(at: workspace)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func pngData(width: Int = 4, height: Int = 4, seed: CGFloat = 0) throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: 0.1 + seed * 0.2, green: 0.4, blue: 0.7, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    @discardableResult
    private func makeFixtureFolder(count: Int, name: String = "shots") throws -> URL {
        let folder = workspace.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..< count {
            try pngData(seed: CGFloat(index)).write(to: folder.appendingPathComponent("shot-\(index).png"))
        }
        return folder
    }

    private func makeModel() throws -> LibraryModel {
        let model = LibraryModel()
        model.open(at: libraryRoot)
        XCTAssertTrue(model.isLoaded, model.loadError ?? "")
        return model
    }

    private func makeCollection(named name: String) -> LibraryCollection {
        LibraryCollection(
            id: UUID(),
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            itemCount: 0
        )
    }

    // MARK: - Pasteboard parsing

    func testPasteboardPrefersFileURLsOverBitmapPreview() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let folder = try makeFixtureFolder(count: 2)
        let urls = [folder.appendingPathComponent("shot-0.png"), folder.appendingPathComponent("shot-1.png")]

        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        // A real Finder copy carries a bitmap preview as well; the URLs must win, otherwise
        // a five-file copy would import as one flattened image.
        pasteboard.setData(try pngData(), forType: .png)

        XCTAssertEqual(CapturePasteboard.read(from: pasteboard), .files(urls))
    }

    func testPasteboardTIFFIsNormalisedToPNG() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        )
        pasteboard.clearContents()
        pasteboard.setData(try XCTUnwrap(rep.tiffRepresentation), forType: .tiff)

        guard case .image(let png) = CapturePasteboard.read(from: pasteboard) else {
            return XCTFail("expected .image, got \(CapturePasteboard.read(from: pasteboard))")
        }
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")
    }

    func testPasteboardTextIsNotCaptured() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("just some text", forType: .string)

        XCTAssertEqual(CapturePasteboard.read(from: pasteboard), .none)
    }

    func testTemporaryPNGIsWrittenWithAnExtension() throws {
        let data = try pngData()
        let url = try CapturePasteboard.writeTemporaryPNG(data, directory: scratch)

        XCTAssertEqual(url.pathExtension, CapturePasteboard.pastedImageExtension)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, scratch.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    // MARK: - Destination rule

    func testSelectedUserCollectionGetsAssigned() {
        let collection = makeCollection(named: "Shots")
        let decision = CaptureRouting.decision(for: .collection(collection.id), tree: [collection])

        XCTAssertEqual(decision.target, .assignedCollection(collection.id))
        XCTAssertEqual(decision.label, "Shots")
    }

    func testInboxAllAndTagsCaptureToInbox() {
        let collection = makeCollection(named: "Shots")
        let tree = [collection]

        for selection: SidebarEntry? in [.inbox, .all, .tag(UUID()), nil] {
            let decision = CaptureRouting.decision(for: selection, tree: tree)
            XCTAssertEqual(decision.target, .inbox, "selection \(String(describing: selection))")
            XCTAssertEqual(decision.label, "Inbox")
        }
    }

    func testDanglingOrInboxCollectionEntryFallsBackToInbox() {
        let inbox = LibraryCollection(
            id: UUID(),
            name: "Inbox",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            itemCount: 0,
            isInbox: true
        )

        XCTAssertEqual(
            CaptureRouting.decision(for: .collection(UUID()), tree: [inbox]).target,
            .inbox,
            "a deleted collection id must not capture into nothing"
        )
        XCTAssertEqual(
            CaptureRouting.decision(for: .collection(inbox.id), tree: [inbox]).target,
            .inbox,
            "the Inbox is not a filing destination"
        )
    }

    // MARK: - CaptureCenter

    func testWindowDropImportsConnectedAndRefreshesTheModel() throws {
        let model = try makeModel()
        let center = CaptureCenter(scratchDirectory: scratch)
        center.attach(model, installMenuBar: false)

        let folder = try makeFixtureFolder(count: 3)
        let urls = [folder.appendingPathComponent("shot-0.png"), folder.appendingPathComponent("shot-1.png")]
        let report = try XCTUnwrap(center.capture(urls: urls, target: .inbox, source: .windowDrop))

        XCTAssertEqual(report.mode, .connected)
        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(report.copiedOriginals, 0)
        XCTAssertEqual(model.items.count, 2, "the grid refreshed from the same capture")
        XCTAssertEqual(model.inboxItemCount, 2)
        XCTAssertEqual(center.lastSource, .windowDrop)
        XCTAssertEqual(center.banner?.style, .success)
        XCTAssertEqual(center.banner?.text, "Inbox: Imported 2 items")
    }

    func testSecondDropReportsDuplicatesInTheBanner() throws {
        let model = try makeModel()
        let center = CaptureCenter(scratchDirectory: scratch)
        center.attach(model, installMenuBar: false)

        let folder = try makeFixtureFolder(count: 2)
        let urls = [folder.appendingPathComponent("shot-0.png")]
        _ = center.capture(urls: urls, target: .inbox, source: .windowDrop)
        let second = try XCTUnwrap(center.capture(urls: urls, target: .inbox, source: .windowDrop))

        XCTAssertTrue(second.hasDuplicates)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(center.banner?.style, .notice)
        XCTAssertEqual(center.banner?.text, "Inbox: 1 already in library")
        XCTAssertEqual(model.items.count, 1, "re-dropping must not duplicate the grid")
    }

    func testDroppingOnACollectionFilesTheItems() throws {
        let model = try makeModel()
        let center = CaptureCenter(scratchDirectory: scratch)
        center.attach(model, installMenuBar: false)

        let collectionID = try XCTUnwrap(model.createCollection(name: "Shots"))
        let folder = try makeFixtureFolder(count: 2)
        let urls = [folder.appendingPathComponent("shot-0.png")]

        let report = try XCTUnwrap(
            center.capture(urls: urls, target: .assignedCollection(collectionID), source: .sidebarDrop)
        )

        XCTAssertEqual(report.destinationLabel, "Shots")
        XCTAssertEqual(model.inboxItemCount, 0, "filed on drop, so it left the Inbox")
        XCTAssertEqual(model.collection(for: collectionID)?.itemCount, 1)
    }

    func testPastedBitmapIsStoredAsACopyAndTheScratchFileIsRemoved() throws {
        let model = try makeModel()
        let center = CaptureCenter(scratchDirectory: scratch)
        center.attach(model, installMenuBar: false)

        let report = try XCTUnwrap(center.captureImageData(try pngData(), target: .inbox))

        XCTAssertEqual(report.mode, .copy, "a pathless bitmap cannot be connected")
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.copiedOriginals, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: scratch.path).count,
            0,
            "the scratch file is deleted once the bytes are owned"
        )
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.mode, .copy)
    }

    func testPasteboardWithOnlyTextIsNotConsumed() throws {
        let model = try makeModel()
        let center = CaptureCenter(scratchDirectory: scratch)
        center.attach(model, installMenuBar: false)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("nothing to import", forType: .string)

        XCTAssertNil(center.capturePasteboard(target: .inbox, pasteboard: pasteboard))
        XCTAssertNil(center.banner)
        XCTAssertEqual(model.items.count, 0)
    }

    func testPasteboardFileURLsImportThroughTheSamePath() throws {
        let model = try makeModel()
        let center = CaptureCenter(scratchDirectory: scratch)
        center.attach(model, installMenuBar: false)

        let folder = try makeFixtureFolder(count: 2)
        let url = folder.appendingPathComponent("shot-1.png")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        let report = try XCTUnwrap(center.capturePasteboard(target: .inbox, pasteboard: pasteboard))

        XCTAssertEqual(report.mode, .connected, "⌘V of a file is connected, like a drop")
        XCTAssertEqual(center.lastSource, .paste)
        XCTAssertEqual(model.items.count, 1)
    }

    func testDismissingTheBannerClearsIt() throws {
        let model = try makeModel()
        let center = CaptureCenter(scratchDirectory: scratch)
        center.attach(model, installMenuBar: false)

        let folder = try makeFixtureFolder(count: 1)
        _ = center.capture(urls: [folder.appendingPathComponent("shot-0.png")], target: .inbox, source: .windowDrop)
        XCTAssertNotNil(center.banner)

        center.dismissBanner()
        XCTAssertNil(center.banner)
    }

    func testEmptyDropIsNotReported() throws {
        let model = try makeModel()
        let center = CaptureCenter(scratchDirectory: scratch)
        center.attach(model, installMenuBar: false)

        let emptyFolder = workspace.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)

        let report = try XCTUnwrap(center.capture(urls: [emptyFolder], target: .inbox, source: .windowDrop))

        XCTAssertTrue(report.isEmpty)
        XCTAssertNil(center.banner, "an empty folder must not flash a pointless banner")
    }

    func testMenuBarDropAlwaysLandsInTheInbox() throws {
        let model = try makeModel()
        let center = CaptureCenter(scratchDirectory: scratch)
        center.attach(model, installMenuBar: false)

        // The window is showing a collection; the pin must still mean Inbox, not "whatever
        // row happens to be selected".
        let collectionID = try XCTUnwrap(model.createCollection(name: "Shots"))
        model.select(.collection(collectionID))
        let folder = try makeFixtureFolder(count: 1)

        let report = try XCTUnwrap(
            center.capture(
                urls: [folder.appendingPathComponent("shot-0.png")],
                target: .inbox,
                source: .menuBarDrop
            )
        )

        XCTAssertEqual(report.destinationLabel, "Inbox")
        XCTAssertEqual(center.lastSource, .menuBarDrop)
        XCTAssertEqual(model.inboxItemCount, 1)
        XCTAssertEqual(model.collection(for: collectionID)?.itemCount, 0)
    }

    // MARK: - Menu-bar status token

    func testFlashTextSummarisesTheBatch() {
        var report = CaptureReport(mode: .connected, destinationLabel: "Inbox")

        report.imported = 3
        XCTAssertEqual(MenuBarCaptureItem.flashText(for: report), "+3")

        report.imported = 0
        report.updated = 2
        XCTAssertEqual(MenuBarCaptureItem.flashText(for: report), "2 dup")

        report.updated = 0
        report.skipped = 1
        XCTAssertEqual(MenuBarCaptureItem.flashText(for: report), "!")
    }
}
