import AppKit
import AtlasCore
import XCTest
@testable import AtlasOSSApp

/// End-to-end coverage of the app layer against a throwaway `.atlaslibrary`: the model
/// opens schema v2, lands on the Inbox, and every sidebar gesture (create / nest /
/// reorder / assign / tag / delete) goes through `AtlasCore` and comes back correctly.
@MainActor
final class LibraryModelTests: XCTestCase {

    private var workspace: URL!
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlasoss-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        libraryRoot = workspace.appendingPathComponent("main.atlaslibrary", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let workspace,
           workspace.path.hasPrefix(FileManager.default.temporaryDirectory.path),
           workspace.lastPathComponent.hasPrefix("atlasoss-app-") {
            try? FileManager.default.removeItem(at: workspace)
        }
        try super.tearDownWithError()
    }

    /// Writes `count` distinct 4×4 PNGs and returns the folder holding them.
    private func makeFixtureFolder(count: Int, name: String = "shots") throws -> URL {
        let folder = workspace.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..< count {
            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            // Distinct pixel data per file so content-hash dedupe does not collapse them.
            for x in 0 ..< 4 {
                for y in 0 ..< 4 {
                    image.setColor(
                        NSColor(red: CGFloat(x) / 4, green: CGFloat(index == 0 ? 0.2 : 0.8), blue: CGFloat(y) / 4, alpha: 1),
                        atX: x, y: y
                    )
                }
            }
            let data = image.representation(using: .png, properties: [:])!
            try data.write(to: folder.appendingPathComponent("shot-\(index).png"))
        }
        return folder
    }

    private func makeModel(itemCount: Int = 2) throws -> LibraryModel {
        let folder = try makeFixtureFolder(count: itemCount)
        // Seed through the core so we exercise the same import path the CLI uses.
        let seed = try AtlasLibrary(url: libraryRoot)
        _ = try seed.importFolder(folder, mode: .connected)
        seed.close()

        let model = LibraryModel()
        model.open(at: libraryRoot)
        XCTAssertNil(model.loadError, "open failed: \(model.loadError ?? "")")
        return model
    }

    // MARK: - Landing

    func testOpensOnInboxWithEverythingUnfiled() throws {
        let model = try makeModel(itemCount: 2)

        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.selection, .inbox, "Inbox is the default landing")
        XCTAssertEqual(model.inboxItemCount, 2)
        XCTAssertEqual(model.totalItemCount, 2)
        XCTAssertEqual(model.items.count, 2)

        // Inbox is pin-listed first, and the import folder shows up as a user collection.
        XCTAssertEqual(model.tree.first?.isInbox, true)
        XCTAssertTrue(model.tree.contains { $0.name == "shots" && !$0.isInbox })
    }

    func testEmptyInboxFallsBackToAllItems() throws {
        let model = try makeModel(itemCount: 2)
        XCTAssertEqual(model.selection, .inbox)

        // Simulate a migrated v1 library: items live in collections but the Inbox was
        // never populated, so landing on it would show an empty grid.
        let seed = try AtlasLibrary(url: libraryRoot)
        let inbox = try seed.inboxCollection()
        try seed.removeItems(try seed.items().map(\.id), fromCollection: inbox.id)
        XCTAssertEqual(try seed.inboxItemCount(), 0)
        seed.close()

        let reopened = LibraryModel()
        reopened.open(at: libraryRoot)
        XCTAssertEqual(reopened.selection, .all)
        XCTAssertEqual(reopened.items.count, 2)
    }

    func testSelectingAllItemsShowsEverything() throws {
        let model = try makeModel(itemCount: 2)
        model.select(.all)
        XCTAssertEqual(model.selection, .all)
        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.selectionTitle, "All Items")
    }

    // MARK: - Collections

    func testCreateFolderSelectsItAndPersists() throws {
        let model = try makeModel()
        let id = try XCTUnwrap(model.createCollection(name: "Moodboard"))

        XCTAssertEqual(model.selection, .collection(id))
        XCTAssertEqual(model.selectionTitle, "Moodboard")
        XCTAssertTrue(model.tree.contains { $0.id == id })
        XCTAssertTrue(model.items.isEmpty, "a fresh folder is empty")

        // A second model over the same file sees it — order and names survive relaunch.
        let reopened = LibraryModel()
        reopened.open(at: libraryRoot)
        XCTAssertTrue(SidebarTree.allNodes(reopened.tree).contains { $0.id == id && $0.name == "Moodboard" })
    }

    func testNestedFolderIsReachableThroughDisclosure() throws {
        let model = try makeModel()
        let parent = try XCTUnwrap(model.createCollection(name: "Projects"))
        let child = try XCTUnwrap(model.createCollection(name: "Rounds", parentID: parent))

        let parentNode = try XCTUnwrap(model.collection(for: parent))
        XCTAssertEqual(parentNode.children.map(\.id), [child])
        XCTAssertTrue(model.expanded.contains(parent), "creating a child expands the parent")

        let rows = SidebarRow.rows(tree: model.tree, tags: model.tags, expanded: model.expanded)
        let childRow = try XCTUnwrap(rows.first { $0.collectionID == child })
        XCTAssertEqual(childRow.depth, 1)
    }

    func testRenameAndDeleteRoundTrip() throws {
        let model = try makeModel()
        let id = try XCTUnwrap(model.createCollection(name: "Draft"))
        model.renameCollection(id, name: "Final")
        XCTAssertEqual(model.collection(for: id)?.name, "Final")

        model.deleteCollection(id)
        XCTAssertNil(model.collection(for: id))
        XCTAssertEqual(model.selection, .inbox, "deleting the selected folder falls back to Inbox")
    }

    func testDeletingAParentPromotesItsChildren() throws {
        let model = try makeModel()
        let parent = try XCTUnwrap(model.createCollection(name: "Parent"))
        let child = try XCTUnwrap(model.createCollection(name: "Child", parentID: parent))

        model.deleteCollection(parent)
        XCTAssertEqual(model.collection(for: child)?.parentID, nil)
        XCTAssertNotNil(model.collection(for: child))
    }

    func testInboxIsNotEditableFromTheModel() throws {
        let model = try makeModel()
        let inbox = try XCTUnwrap(model.tree.first { $0.isInbox })

        model.renameCollection(inbox.id, name: "Sorted")
        XCTAssertEqual(model.collection(for: inbox.id)?.name, "Inbox")
        XCTAssertNotNil(model.loadError, "the refusal is surfaced, not swallowed")

        model.deleteCollection(inbox.id)
        XCTAssertNotNil(model.collection(for: inbox.id))
    }

    // MARK: - Drag and drop

    func testDroppingSelectionOnAFolderFilesItOutOfTheInbox() throws {
        let model = try makeModel(itemCount: 3)
        let target = try XCTUnwrap(model.createCollection(name: "Kept"))

        model.select(.inbox)
        XCTAssertEqual(model.inboxItemCount, 3)
        let ids = model.items.map(\.id)
        XCTAssertEqual(ids.count, 3)

        let action = SidebarTree.resolve(
            payload: .items(ids),
            target: .collection(try XCTUnwrap(model.collection(for: target))),
            zone: .onto,
            tree: model.tree
        )
        XCTAssertTrue(model.apply(action))

        XCTAssertEqual(model.inboxItemCount, 0, "filing clears the Inbox badge")
        XCTAssertEqual(model.collection(for: target)?.itemCount, 3)
        XCTAssertEqual(model.totalItemCount, 3, "the items themselves are untouched")
    }

    func testDropOnTopOrBottomEdgeReordersInstead() throws {
        let model = try makeModel()
        let a = try XCTUnwrap(model.createCollection(name: "A"))
        let b = try XCTUnwrap(model.createCollection(name: "B"))

        let zone = SidebarTree.zone(locationY: 1, rowHeight: 26)
        XCTAssertEqual(zone, .before)

        let action = SidebarTree.resolve(
            payload: .collection(b),
            target: .collection(try XCTUnwrap(model.collection(for: a))),
            zone: zone,
            tree: model.tree
        )
        XCTAssertTrue(model.apply(action))

        // Created order was shots → A → B; dragging B above A yields shots, B, A.
        let roots = model.tree.filter { !$0.isInbox }.map(\.name)
        XCTAssertEqual(roots, ["shots", "B", "A"])

        // The new order is written to the database, not just held in memory.
        let reopened = LibraryModel()
        reopened.open(at: libraryRoot)
        XCTAssertEqual(reopened.tree.filter { !$0.isInbox }.map(\.name), ["shots", "B", "A"])
    }

    func testDropInTheMiddleNests() throws {
        let model = try makeModel()
        let parent = try XCTUnwrap(model.createCollection(name: "Parent"))
        let loose = try XCTUnwrap(model.createCollection(name: "Loose"))

        let action = SidebarTree.resolve(
            payload: .collection(loose),
            target: .collection(try XCTUnwrap(model.collection(for: parent))),
            zone: .onto,
            tree: model.tree
        )
        XCTAssertTrue(model.apply(action))

        XCTAssertEqual(model.collection(for: loose)?.parentID, parent)
        XCTAssertTrue(model.expanded.contains(parent))
    }

    func testDroppingOnItsOwnSubtreeIsRejected() throws {
        let model = try makeModel()
        let parent = try XCTUnwrap(model.createCollection(name: "Parent"))
        let child = try XCTUnwrap(model.createCollection(name: "Child", parentID: parent))

        let action = SidebarTree.resolve(
            payload: .collection(parent),
            target: .collection(try XCTUnwrap(model.collection(for: child))),
            zone: .onto,
            tree: model.tree
        )
        XCTAssertEqual(action, .none)
        XCTAssertFalse(model.apply(action))
        XCTAssertEqual(model.collection(for: parent)?.parentID, nil)
    }

    // MARK: - Tags

    func testTagLifecycleAndDropToTag() throws {
        let model = try makeModel(itemCount: 2)
        model.createTag(name: "hero")

        let tag = try XCTUnwrap(model.tags.first)
        XCTAssertEqual(model.selection, .tag(tag.id))
        XCTAssertEqual(model.selectionTitle, "#hero")

        model.select(.all)
        let ids = model.items.map(\.id)
        let action = SidebarTree.resolve(
            payload: .items(ids),
            target: .tag(try XCTUnwrap(model.tag(for: tag.id))),
            zone: .onto,
            tree: model.tree
        )
        XCTAssertTrue(model.apply(action))
        XCTAssertEqual(model.tag(for: tag.id)?.itemCount, 2)

        // Selecting the tag filters the grid to its members.
        model.select(.tag(tag.id))
        XCTAssertEqual(model.items.count, 2)

        model.renameTag(tag.id, name: "picked")
        XCTAssertEqual(model.tag(for: tag.id)?.name, "picked")
        XCTAssertEqual(model.selectionTitle, "#picked")

        model.deleteTag(tag.id)
        XCTAssertTrue(model.tags.isEmpty)
        XCTAssertEqual(model.selection, .inbox, "deleting the selected tag falls back to Inbox")
    }

    func testCreateTagIsIdempotentFromTheModel() throws {
        let model = try makeModel()
        model.createTag(name: "hero")
        model.createTag(name: "HERO")
        XCTAssertEqual(model.tags.count, 1)
    }
}
