import Foundation
import Testing
@testable import AtlasCore

// MARK: - Nested collections

@Suite("P1-B · collection tree")
struct CollectionTreeTests {

    /// Depth-first lookup so assertions do not depend on sibling positions created by
    /// the import path (which always adds a folder-named collection at the root).
    private func node(_ name: String, in tree: [LibraryCollection]) -> LibraryCollection? {
        tree.flatMap { $0.flattened() }.first { $0.name == name }
    }

    private func userRoots(_ library: AtlasLibrary) throws -> [String] {
        try library.collectionTree(includingSystem: false).map(\.name)
    }

    @Test("nesting builds a tree with rolled-up totals")
    func nestingBuildsTree() throws {
        let workspace = try TemporaryWorkspace(label: "nest")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let parent = try library.createCollection(name: "Projects")
        let child = try library.createCollection(name: "Client A", parentID: parent)
        let grandchild = try library.createCollection(name: "Rounds", parentID: child)

        let items = try library.items()
        try library.addItems(items.prefix(2).map(\.id), toCollection: grandchild)
        try library.addItems(items.prefix(3).map(\.id), toCollection: parent)

        let tree = try library.collectionTree(includingSystem: false)
        let projects = try #require(node("Projects", in: tree))
        #expect(projects.itemCount == 3)
        #expect(projects.totalItemCount == 5)   // 3 direct + 2 in Rounds
        #expect(projects.children.map(\.name) == ["Client A"])

        let clientA = try #require(node("Client A", in: tree))
        #expect(clientA.parentID == parent)
        #expect(clientA.itemCount == 0)
        #expect(clientA.totalItemCount == 2)
        #expect(clientA.children.map(\.name) == ["Rounds"])

        let rounds = try #require(node("Rounds", in: tree))
        #expect(rounds.parentID == child)
        #expect(rounds.children.isEmpty)

        // `flattened()` walks depth-first, self first.
        #expect(projects.flattened().map(\.name) == ["Projects", "Client A", "Rounds"])
    }

    @Test("siblings of different parents may share a name")
    func perParentNameUniqueness() throws {
        let workspace = try TemporaryWorkspace(label: "names")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let a = try library.createCollection(name: "A")
        let b = try library.createCollection(name: "B")
        let aChild = try library.createCollection(name: "Reference", parentID: a)
        let bChild = try library.createCollection(name: "Reference", parentID: b)

        #expect(aChild != bChild)
        #expect(try library.collection(id: aChild)?.name == "Reference")
        #expect(try library.collection(id: bChild)?.name == "Reference")

        // Same-parent collisions are rejected on create (auto-suffixed)…
        let sibling = try library.createCollection(name: "reference", parentID: a)
        #expect(try library.collection(id: sibling)?.name == "reference 2")

        // …and on rename.
        #expect(throws: AtlasError.self) {
            try library.renameCollection(id: sibling, name: "Reference")
        }
        #expect(try library.collection(id: sibling)?.name == "reference 2")
    }

    @Test("rename trims and rejects empty names")
    func renameValidates() throws {
        let workspace = try TemporaryWorkspace(label: "rename")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let id = try library.createCollection(name: "Draft")
        try library.renameCollection(id: id, name: "  Final  ")
        #expect(try library.collection(id: id)?.name == "Final")

        #expect(throws: AtlasError.self) {
            try library.renameCollection(id: id, name: "   ")
        }
        #expect(throws: AtlasError.self) {
            try library.createCollection(name: "")
        }
    }

    @Test("move reparents and reorders, cycling is rejected")
    func moveReparents() throws {
        let workspace = try TemporaryWorkspace(label: "move")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let parent = try library.createCollection(name: "Parent")
        let child = try library.createCollection(name: "Child", parentID: parent)
        let loose = try library.createCollection(name: "Loose")

        try library.moveCollection(id: loose, newParentID: parent, newSortOrder: -5)
        var tree = try library.collectionTree(includingSystem: false)
        #expect(node("Parent", in: tree)?.children.map(\.name) == ["Loose", "Child"])

        // Back to root.
        try library.moveCollection(id: loose, newParentID: nil, newSortOrder: 10)
        tree = try library.collectionTree(includingSystem: false)
        #expect(try userRoots(library) == ["Parent", "Loose"])

        // A collection cannot be nested inside itself or its descendants.
        #expect(throws: AtlasError.self) {
            try library.moveCollection(id: parent, newParentID: child, newSortOrder: 0)
        }
        #expect(throws: AtlasError.self) {
            try library.moveCollection(id: parent, newParentID: parent, newSortOrder: 0)
        }
        #expect(try library.collection(id: parent)?.parentID == nil)
    }

    @Test("reorder places a collection immediately before a sibling")
    func reorderWithinParent() throws {
        let workspace = try TemporaryWorkspace(label: "reorder")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let a = try library.createCollection(name: "A")
        let b = try library.createCollection(name: "B")
        let c = try library.createCollection(name: "C")
        #expect(try userRoots(library) == ["A", "B", "C"])

        // Drag C above A.
        try library.reorderCollection(c, parentID: nil, before: a)
        #expect(try userRoots(library) == ["C", "A", "B"])

        // Drag C to the end.
        try library.reorderCollection(c, parentID: nil, before: nil)
        #expect(try userRoots(library) == ["A", "B", "C"])

        // Sort order stays contiguous and the Inbox keeps its pinned slot — this is what
        // survives relaunch.
        let all = try library.allCollections()
        #expect(all.filter { !$0.isInbox }.map(\.sortOrder).sorted() == [0, 1, 2])
        #expect(try library.allCollections().first { $0.isInbox }?.sortOrder == AtlasSchema.inboxSortOrder)
        _ = b
    }

    @Test("Inbox is pinned, immutable, and cannot be a parent")
    func inboxIsImmutable() throws {
        let workspace = try TemporaryWorkspace(label: "inbox-guard")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let inbox = try library.inboxCollection()
        let user = try library.createCollection(name: "User")

        #expect(throws: AtlasError.self) { try library.renameCollection(id: inbox.id, name: "Sorted") }
        #expect(throws: AtlasError.self) { try library.deleteCollection(id: inbox.id) }
        #expect(throws: AtlasError.self) {
            try library.moveCollection(id: user, newParentID: inbox.id, newSortOrder: 0)
        }
        #expect(throws: AtlasError.self) {
            try library.createCollection(name: "Child", parentID: inbox.id)
        }
        #expect(throws: AtlasError.self) {
            try library.reorderCollection(inbox.id, parentID: nil, before: user)
        }

        // The Inbox still sorts first even after user collections have orders.
        #expect(try library.collectionTree().first?.isInbox == true)
    }

    @Test("deleting a collection promotes children to the root")
    func deletePromotesChildren() throws {
        let workspace = try TemporaryWorkspace(label: "delete")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let parent = try library.createCollection(name: "Parent")
        let child = try library.createCollection(name: "Child", parentID: parent)
        try library.addItems(try library.items().map(\.id), toCollection: parent)
        #expect(try library.itemCount(inCollection: parent) == 2)

        try library.deleteCollection(id: parent)

        let tree = try library.collectionTree(includingSystem: false)
        #expect(node("Parent", in: tree) == nil)
        #expect(node("Child", in: tree)?.parentID == nil)
        #expect(try library.collection(id: child)?.parentID == nil)

        // Membership rows for the deleted collection are gone; the items survive.
        #expect(try library.items(collectionID: parent).isEmpty)
        #expect(try library.itemCount() == 2)
    }

    @Test("promoted children are renamed when the root would collide")
    func deleteRenamesCollisions() throws {
        let workspace = try TemporaryWorkspace(label: "delete-collide")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let parent = try library.createCollection(name: "Parent")
        _ = try library.createCollection(name: "Shared", parentID: parent)
        _ = try library.createCollection(name: "Shared")   // root sibling, same name

        try library.deleteCollection(id: parent)
        #expect(try userRoots(library).sorted() == ["Shared", "Shared 2"])
    }

    @Test("items(collectionID:) returns direct membership only")
    func directMembershipOnly() throws {
        let workspace = try TemporaryWorkspace(label: "direct")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        let parent = try library.createCollection(name: "Parent")
        let child = try library.createCollection(name: "Child", parentID: parent)

        try library.addItems([items[0].id], toCollection: parent)
        try library.addItems([items[1].id], toCollection: child)

        #expect(try library.items(collectionID: parent).map(\.id) == [items[0].id])
        #expect(try library.items(inCollection: child).map(\.id) == [items[1].id])
        #expect(try library.itemCount(inCollection: parent) == 1)
    }

    @Test("an item can live in many collections at once")
    func membershipIsManyToMany() throws {
        let workspace = try TemporaryWorkspace(label: "many-to-many")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        let a = try library.createCollection(name: "A")
        let b = try library.createCollection(name: "B")

        try library.addItems(items.map(\.id), toCollection: a)
        try library.addItems(items.map(\.id), toCollection: b)

        #expect(try library.items(collectionID: a).count == 2)
        #expect(try library.items(collectionID: b).count == 2)
        // Adding twice is a no-op, not a duplicate.
        #expect(try library.addItems(items.map(\.id), toCollection: a) == 0)
        #expect(try library.itemCount(inCollection: a) == 2)
    }
}
