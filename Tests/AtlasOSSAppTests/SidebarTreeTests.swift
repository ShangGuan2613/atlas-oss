import AtlasCore
import XCTest
@testable import AtlasOSSApp

/// Pure-logic coverage for the P1-B sidebar: drag payloads, drop-zone geometry, drop
/// resolution (nest vs reorder vs assign), and the flattened row model.
final class SidebarTreeTests: XCTestCase {

    // MARK: - Fixtures

    private let inboxID = UUID()
    private let projectsID = UUID()
    private let roundsID = UUID()
    private let refsID = UUID()
    private let tagID = UUID()

    /// Inbox ─┬ Projects ── Rounds
    ///        └ References
    private func makeTree() -> [LibraryCollection] {
        let rounds = LibraryCollection(
            id: roundsID, name: "Rounds", createdAt: .init(), updatedAt: .init(),
            itemCount: 2, parentID: projectsID, sortOrder: 0
        )
        let projects = LibraryCollection(
            id: projectsID, name: "Projects", createdAt: .init(), updatedAt: .init(),
            itemCount: 1, parentID: nil, sortOrder: 0, totalItemCount: 3, children: [rounds]
        )
        let references = LibraryCollection(
            id: refsID, name: "References", createdAt: .init(), updatedAt: .init(),
            itemCount: 4, parentID: nil, sortOrder: 1
        )
        let inbox = LibraryCollection(
            id: inboxID, name: "Inbox", createdAt: .init(), updatedAt: .init(),
            itemCount: 5, parentID: nil, sortOrder: AtlasSchema.inboxSortOrder, isInbox: true
        )
        return [inbox, projects, references]
    }

    private func collection(_ id: UUID) -> LibraryCollection {
        SidebarTree.allNodes(makeTree()).first { $0.id == id }!
    }

    private var tag: LibraryTag {
        LibraryTag(id: tagID, name: "hero", createdAt: .init(), color: nil, itemCount: 0)
    }

    // MARK: - Payload

    func testPayloadRoundTrips() {
        let ids = [UUID(), UUID()]
        XCTAssertEqual(SidebarDragPayload(raw: SidebarDragPayload.items(ids).encoded), .items(ids))

        let one = UUID()
        XCTAssertEqual(SidebarDragPayload(raw: SidebarDragPayload.collection(one).encoded), .collection(one))
    }

    func testPayloadRejectsGarbage() {
        XCTAssertNil(SidebarDragPayload(raw: ""))
        XCTAssertNil(SidebarDragPayload(raw: "not-a-payload"))
        XCTAssertNil(SidebarDragPayload(raw: "atlas.drag.collection:nonsense"))
        XCTAssertNil(SidebarDragPayload(raw: "atlas.drag.items:"))
        XCTAssertNil(SidebarDragPayload(raw: "atlas.drag.items:abc,def"))
    }

    // MARK: - Zone geometry

    func testZoneSplitsRowIntoThirds() {
        let height: CGFloat = 26
        XCTAssertEqual(SidebarTree.zone(locationY: 0, rowHeight: height), .before)
        XCTAssertEqual(SidebarTree.zone(locationY: 3, rowHeight: height), .before)
        XCTAssertEqual(SidebarTree.zone(locationY: 13, rowHeight: height), .onto)
        XCTAssertEqual(SidebarTree.zone(locationY: 24, rowHeight: height), .after)
        XCTAssertEqual(SidebarTree.zone(locationY: height, rowHeight: height), .after)
        XCTAssertEqual(SidebarTree.zone(locationY: 10, rowHeight: 0), .onto, "degenerate rows accept")
    }

    // MARK: - Tree maths

    func testDescendantsIncludeSelfAndDepth() {
        let descendants = SidebarTree.descendants(of: projectsID, in: makeTree())
        XCTAssertEqual(descendants, [projectsID, roundsID])
        XCTAssertEqual(SidebarTree.descendants(of: refsID, in: makeTree()), [refsID])
        // Unknown ids conservatively report themselves, so a stale drag cannot bypass
        // the cycle check.
        let unknown = UUID()
        XCTAssertEqual(SidebarTree.descendants(of: unknown, in: makeTree()), [unknown])
    }

    func testSiblingIDsCoverRootAndNested() {
        XCTAssertEqual(SidebarTree.siblingIDs(parentID: nil, in: makeTree()), [inboxID, projectsID, refsID])
        XCTAssertEqual(SidebarTree.siblingIDs(parentID: projectsID, in: makeTree()), [roundsID])
    }

    func testSiblingAfterWalksToNextOrNilAtEnd() {
        XCTAssertEqual(SidebarTree.siblingAfter(collection(projectsID), in: makeTree()), refsID)
        XCTAssertNil(SidebarTree.siblingAfter(collection(refsID), in: makeTree()))
        XCTAssertNil(SidebarTree.siblingAfter(collection(roundsID), in: makeTree()))
    }

    // MARK: - Items dropped on rows

    func testItemsDroppedOnCollectionAreAssigned() {
        let ids = [UUID(), UUID()]
        let action = SidebarTree.resolve(
            payload: .items(ids),
            target: .collection(collection(projectsID)),
            zone: .onto,
            tree: makeTree()
        )
        XCTAssertEqual(action, .addItems(itemIDs: ids, collectionID: projectsID))
    }

    func testItemsDroppedOnTagAreTagged() {
        let ids = [UUID()]
        let action = SidebarTree.resolve(
            payload: .items(ids),
            target: .tag(tag),
            zone: .onto,
            tree: makeTree()
        )
        XCTAssertEqual(action, .tagItems(itemIDs: ids, tagID: tagID))
    }

    func testItemsDroppedOnSectionHeaderDoNothing() {
        XCTAssertEqual(
            SidebarTree.resolve(payload: .items([UUID()]), target: .root, zone: .onto, tree: makeTree()),
            .none
        )
        XCTAssertEqual(
            SidebarTree.resolve(payload: .items([]), target: .collection(collection(refsID)), zone: .onto, tree: makeTree()),
            .none
        )
    }

    // MARK: - Collections dragged onto rows

    func testCollectionDroppedInMiddleNests() {
        let action = SidebarTree.resolve(
            payload: .collection(refsID),
            target: .collection(collection(projectsID)),
            zone: .onto,
            tree: makeTree()
        )
        XCTAssertEqual(action, .nest(collection: refsID, into: projectsID))
    }

    func testCollectionDroppedOnTopEdgeReordersBeforeSibling() {
        let action = SidebarTree.resolve(
            payload: .collection(refsID),
            target: .collection(collection(projectsID)),
            zone: .before,
            tree: makeTree()
        )
        XCTAssertEqual(action, .reorder(collection: refsID, parentID: nil, before: projectsID))
    }

    func testCollectionDroppedOnBottomEdgeReordersAfterSibling() {
        let action = SidebarTree.resolve(
            payload: .collection(refsID),
            target: .collection(collection(projectsID)),
            zone: .after,
            tree: makeTree()
        )
        // "After Projects" == "before References", which is the next root sibling.
        XCTAssertEqual(action, .reorder(collection: refsID, parentID: nil, before: refsID))
    }

    func testCollectionDroppedOnLastSiblingAppendsToParent() {
        let action = SidebarTree.resolve(
            payload: .collection(projectsID),
            target: .collection(collection(refsID)),
            zone: .after,
            tree: makeTree()
        )
        XCTAssertEqual(action, .reorder(collection: projectsID, parentID: nil, before: nil))

        // Nested: dropping Rounds below itself inside Projects also appends.
        let nested = SidebarTree.resolve(
            payload: .collection(roundsID),
            target: .collection(collection(projectsID)),
            zone: .before,
            tree: makeTree()
        )
        XCTAssertEqual(nested, .reorder(collection: roundsID, parentID: nil, before: projectsID))
    }

    func testCollectionCannotNestInsideItsOwnSubtree() {
        for zone in [SidebarDropZone.onto, .before, .after] {
            XCTAssertEqual(
                SidebarTree.resolve(
                    payload: .collection(projectsID),
                    target: .collection(collection(roundsID)),
                    zone: zone,
                    tree: makeTree()
                ),
                .none
            )
        }
        // Dropping a collection on itself is a no-op.
        XCTAssertEqual(
            SidebarTree.resolve(
                payload: .collection(refsID),
                target: .collection(collection(refsID)),
                zone: .onto,
                tree: makeTree()
            ),
            .none
        )
    }

    func testInboxIsNotANestTargetButAcceptsBelowDrop() {
        XCTAssertEqual(
            SidebarTree.resolve(
                payload: .collection(refsID),
                target: .collection(collection(inboxID)),
                zone: .onto,
                tree: makeTree()
            ),
            .none
        )
        XCTAssertEqual(
            SidebarTree.resolve(
                payload: .collection(refsID),
                target: .collection(collection(inboxID)),
                zone: .before,
                tree: makeTree()
            ),
            .none
        )
        // "Below the Inbox" pins it to the top of the user section.
        XCTAssertEqual(
            SidebarTree.resolve(
                payload: .collection(refsID),
                target: .collection(collection(inboxID)),
                zone: .after,
                tree: makeTree()
            ),
            .reorder(collection: refsID, parentID: nil, before: projectsID)
        )
    }

    func testCollectionDroppedOnSectionHeaderUnnests() {
        XCTAssertEqual(
            SidebarTree.resolve(
                payload: .collection(roundsID),
                target: .root,
                zone: .onto,
                tree: makeTree()
            ),
            .reorder(collection: roundsID, parentID: nil, before: nil)
        )
    }

    func testCollectionDroppedOnTagDoesNothing() {
        XCTAssertEqual(
            SidebarTree.resolve(
                payload: .collection(refsID),
                target: .tag(tag),
                zone: .onto,
                tree: makeTree()
            ),
            .none
        )
    }

    // MARK: - Rows

    func testRowsAreDepthFirstAndRespectDisclosure() {
        let collapsed = SidebarRow.rows(tree: makeTree(), tags: [tag], expanded: [])
        XCTAssertEqual(collapsed.map(\.title), ["Inbox", "Projects", "References", "hero"])
        XCTAssertEqual(collapsed.map(\.depth), [0, 0, 0, 0])

        let expanded = SidebarRow.rows(tree: makeTree(), tags: [tag], expanded: [projectsID])
        XCTAssertEqual(expanded.map(\.title), ["Inbox", "Projects", "Rounds", "References", "hero"])
        XCTAssertEqual(expanded.map(\.depth), [0, 0, 1, 0, 0])
    }

    func testRowKindsAndEntries() {
        let rows = SidebarRow.rows(tree: makeTree(), tags: [tag], expanded: [projectsID])
        XCTAssertEqual(rows.first?.kind, .inbox)
        XCTAssertEqual(rows.first?.entry, .inbox)
        XCTAssertEqual(rows.first?.collectionID, inboxID)

        let projects = rows.first { $0.id == "collection:\(projectsID.uuidString)" }
        XCTAssertEqual(projects?.kind, .collection)
        XCTAssertEqual(projects?.entry, .collection(projectsID))
        XCTAssertEqual(projects?.hasChildren, true)
        XCTAssertEqual(projects?.isExpanded, true)

        let tagRow = rows.first { $0.kind == .tag }
        XCTAssertEqual(tagRow?.entry, .tag(tagID))
        XCTAssertEqual(tagRow?.tagID, tagID)
        XCTAssertNil(tagRow?.collectionID)
    }

    func testOnlyOneInboxRowIsProduced() {
        // The Inbox appears once, at the top: the view pins it and filters it out of the
        // Collections section, so the row model must not duplicate it.
        let rows = SidebarRow.rows(tree: makeTree(), tags: [tag], expanded: [projectsID])
        XCTAssertEqual(rows.filter { $0.kind == .inbox }.count, 1)
        XCTAssertEqual(rows.first?.kind, .inbox)
    }

    func testRowIdentifiersAreStableAndUnique() {
        let rows = SidebarRow.rows(tree: makeTree(), tags: [tag], expanded: [projectsID])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        let again = SidebarRow.rows(tree: makeTree(), tags: [tag], expanded: [projectsID])
        XCTAssertEqual(rows.map(\.id), again.map(\.id))
    }
}
