import Foundation
import Testing
@testable import AtlasCore

// MARK: - Tags

@Suite("P1-B · tags")
struct TagTests {

    @Test("createTag is idempotent on name")
    func createIsIdempotent() throws {
        let workspace = try TemporaryWorkspace(label: "tag-create")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let first = try library.createTag(name: "hero")
        let again = try library.createTag(name: "  HERO  ")
        #expect(first == again)
        #expect(try library.tags().count == 1)
        #expect(try library.tags().first?.name == "hero")
        #expect(try library.tags().first?.itemCount == 0)

        #expect(throws: AtlasError.self) { try library.createTag(name: "   ") }
    }

    @Test("renameTag rejects collisions and empty names")
    func renameValidates() throws {
        let workspace = try TemporaryWorkspace(label: "tag-rename")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let a = try library.createTag(name: "alpha")
        let b = try library.createTag(name: "beta")

        try library.renameTag(id: a, name: "gamma")
        #expect(try library.tag(id: a)?.name == "gamma")

        #expect(throws: AtlasError.self) { try library.renameTag(id: a, name: "Beta") }
        #expect(throws: AtlasError.self) { try library.renameTag(id: a, name: " ") }
        #expect(try library.tag(id: b)?.name == "beta")
    }

    @Test("setTags add/remove/replace reconcile memberships")
    func setTagsModes() throws {
        let workspace = try TemporaryWorkspace(label: "tag-set")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        let hero = try library.createTag(name: "hero")
        let dark = try library.createTag(name: "dark")

        // add
        let added = try library.setTags(itemIDs: items.map(\.id), tagIDs: [hero], mode: .add)
        #expect(added == 2)
        #expect(try library.itemCount(tagID: hero) == 2)
        #expect(try library.tags(forItemID: items[0].id).map(\.name) == ["hero"])

        // add is a no-op the second time
        #expect(try library.setTags(itemIDs: items.map(\.id), tagIDs: [hero], mode: .add) == 0)

        // add a second tag, then remove just one
        try library.setTags(itemIDs: items.map(\.id), tagIDs: [dark], mode: .add)
        #expect(try library.tags(forItemID: items[0].id).map(\.name) == ["dark", "hero"])
        try library.setTags(itemIDs: [items[0].id], tagIDs: [dark], mode: .remove)
        #expect(try library.tags(forItemID: items[0].id).map(\.name) == ["hero"])
        #expect(try library.itemCount(tagID: dark) == 1)

        // replace makes each item carry exactly the given tags
        try library.setTags(itemIDs: items.map(\.id), tagIDs: [dark], mode: .replace)
        #expect(try library.tags(forItemID: items[0].id).map(\.name) == ["dark"])
        #expect(try library.tags(forItemID: items[1].id).map(\.name) == ["dark"])
        #expect(try library.itemCount(tagID: hero) == 0)
        #expect(try library.itemCount(tagID: dark) == 2)

        // replace with an empty set clears everything
        try library.setTags(itemIDs: items.map(\.id), tagIDs: [], mode: .replace)
        #expect(try library.itemCount(tagID: dark) == 0)
    }

    @Test("items(tagID:) filters by tag")
    func itemsByTag() throws {
        let workspace = try TemporaryWorkspace(label: "tag-items")
        let fixtures = try workspace.makeFixtures(count: 3)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        let tag = try library.createTag(name: "picked")

        try library.setTags(itemIDs: [items[1].id], tagIDs: [tag])

        #expect(try library.items(tagID: tag).map(\.id) == [items[1].id])
        #expect(try library.items(tagID: tag).count == 1)
        #expect(try library.items().count == 3)
    }

    @Test("deleting a tag cascades its memberships but keeps the items")
    func deleteTagCascades() throws {
        let workspace = try TemporaryWorkspace(label: "tag-delete")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        let tag = try library.createTag(name: "temp", color: "#FF0000")
        try library.setTags(itemIDs: items.map(\.id), tagIDs: [tag])

        #expect(try library.tags().first?.color == "#FF0000")
        try library.deleteTag(id: tag)

        #expect(try library.tags().isEmpty)
        #expect(try library.items(tagID: tag).isEmpty)
        #expect(try library.items().count == 2)
        #expect(try library.itemCount() == 2)
    }

    @Test("tags(forItemIDs:) batches lookups")
    func batchedTags() throws {
        let workspace = try TemporaryWorkspace(label: "tag-batch")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        let tag = try library.createTag(name: "solo")
        try library.setTags(itemIDs: [items[0].id], tagIDs: [tag])

        let map = try library.tags(forItemIDs: items.map(\.id))
        #expect(map[items[0].id]?.map(\.name) == ["solo"])
        #expect(map[items[1].id]?.isEmpty == true)
    }
}

// MARK: - Inbox rule

@Suite("P1-B · inbox")
struct InboxRuleTests {

    @Test("every import lands in the Inbox as well as its folder collection")
    func importCapturesToInbox() throws {
        let workspace = try TemporaryWorkspace(label: "inbox-import")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let report = try library.importFolder(fixtures, mode: .connected)
        #expect(report.copiedOriginals == 0)   // P0 gate survives P1-B

        let inbox = try library.inboxCollection()
        #expect(inbox.itemCount == 4)

        let items = try library.items()
        #expect(items.count == 4)
        #expect(try items.allSatisfy { try library.isInInbox($0.id) })
        let folder = try #require(try library.collections().first { $0.name == "fixtures" })
        #expect(folder.itemCount == 4)

        // Both memberships exist, so the item is reachable from either path.
        #expect(try library.items(collectionID: inbox.id).count == 4)
        #expect(try library.items(collectionID: folder.id).count == 4)
    }

    @Test("filing an item into a collection clears it from the Inbox")
    func assignClearsInbox() throws {
        let workspace = try TemporaryWorkspace(label: "inbox-assign")
        let fixtures = try workspace.makeFixtures(count: 3)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        let inbox = try library.inboxCollection()
        let moodboard = try library.createCollection(name: "Moodboard")

        try library.assignItems([items[0].id], toCollection: moodboard)

        #expect(try library.isInInbox(items[0].id) == false)
        #expect(try library.isInInbox(items[1].id) == true)
        #expect(try library.itemCount(inCollection: inbox.id) == 2)
        #expect(try library.itemCount(inCollection: moodboard) == 1)

        // The item keeps its folder membership too — assignment adds, it never moves.
        #expect(try library.items(collectionID: moodboard).map(\.id) == [items[0].id])
        #expect(try library.items().count == 3)
    }

    @Test("removing the last real home restores the Inbox link")
    func removalRestoresInbox() throws {
        let workspace = try TemporaryWorkspace(label: "inbox-restore")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        let inbox = try library.inboxCollection()
        let folder = try #require(try library.collections().first { $0.name == "fixtures" })
        let filed = try library.createCollection(name: "Filed")

        try library.assignItems(items.map(\.id), toCollection: filed)
        #expect(try library.itemCount(inCollection: inbox.id) == 0)

        // Still filed elsewhere (the import folder) -> still not back in the Inbox.
        try library.removeItems(items.map(\.id), fromCollection: folder.id)
        #expect(try library.itemCount(inCollection: inbox.id) == 0)

        // Removing from the last home restores the Inbox link, so nothing disappears.
        try library.removeItems(items.map(\.id), fromCollection: filed)
        #expect(try library.itemCount(inCollection: inbox.id) == 2)

        // …and removing from one of two remaining homes does not.
        let other = try library.createCollection(name: "Other")
        try library.assignItems(items.map(\.id), toCollection: other)
        try library.assignItems(items.map(\.id), toCollection: filed)
        try library.removeItems(items.map(\.id), fromCollection: filed)
        #expect(try library.itemCount(inCollection: inbox.id) == 0)
        #expect(try library.itemCount(inCollection: other) == 2)
    }

    @Test("Inbox membership can only ever be added to")
    func inboxIsNeverUnlinkedByAdd() throws {
        let workspace = try TemporaryWorkspace(label: "inbox-add-only")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        let items = try library.items()
        let inbox = try library.inboxCollection()

        try library.assignItems(items.map(\.id), toCollection: inbox.id)
        #expect(try library.itemCount(inCollection: inbox.id) == 2)
    }

    @Test("inbox item count matches the info badge")
    func badgeMatchesInfo() throws {
        let workspace = try TemporaryWorkspace(label: "inbox-badge")
        let fixtures = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .connected)
        #expect(try library.info().inboxItemCount == 4)

        let target = try library.createCollection(name: "Sorted")
        try library.assignItems(try library.items().prefix(2).map(\.id), toCollection: target)
        #expect(try library.info().inboxItemCount == 2)
        #expect(try library.info().itemCount == 4)
    }

    @Test("copy-mode imports also capture to the Inbox")
    func copyModeCaptures() throws {
        let workspace = try TemporaryWorkspace(label: "inbox-copy")
        let fixtures = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        _ = try library.importFolder(fixtures, mode: .copy)
        #expect(try library.info().inboxItemCount == 2)
        #expect(try library.itemCount() == 2)
    }
}
