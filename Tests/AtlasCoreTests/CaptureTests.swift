import Foundation
import Testing
@testable import AtlasCore

/// P1-E capture engine.
///
/// `importURLs(_:mode:target:)` is what every drop, paste and menu-bar drop funnels through,
/// so this suite is the contract for three things: **connected is the default**, the P1-B
/// Inbox rule still holds, and duplicates are reported rather than silently absorbed.
@Suite("P1-E · capture")
struct CaptureTests {

    // MARK: - Connected is the default

    @Test("a drop imports connected and never writes into originals/")
    func connectedIsTheDefault() throws {
        let workspace = try TemporaryWorkspace(label: "capture-connected")
        let folder = try workspace.makeFixtures(count: 3)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let urls = Fixtures.all.prefix(3).map { folder.appendingPathComponent($0.name) }
        let report = try library.importURLs(urls)

        #expect(report.mode == .connected)
        #expect(report.destinationLabel == "Inbox")
        #expect(report.scanned == 3)
        #expect(report.imported == 3)
        #expect(report.updated == 0)
        #expect(report.duplicates == 0)
        #expect(report.skipped == 0)
        #expect(report.copiedOriginals == 0)

        #expect(try library.itemCount() == 3)
        #expect(try library.itemCount(mode: .connected) == 3)
        #expect(try library.itemCount(mode: .copy) == 0)
        #expect(DirectoryStats.fileCount(in: library.paths.originalsURL) == 0)
        #expect(try library.inboxItemCount() == 3)
    }

    @Test("a dropped folder is enumerated, not turned into a collection")
    func droppedFolderIsEnumerated() throws {
        let workspace = try TemporaryWorkspace(label: "capture-folder")
        let folder = try workspace.makeFixtures(count: 4)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let report = try library.importURLs([folder])

        #expect(report.scanned == 4)
        #expect(report.imported == 4)
        #expect(report.copiedOriginals == 0)
        // `importFolder` names a collection after the folder; a drop must not, or every drag
        // would litter the sidebar.
        #expect(try library.collections().count == 0)
        #expect(try library.inboxItemCount() == 4)
    }

    // MARK: - Duplicates

    @Test("re-dropping the same files reports them as already in the library")
    func reimportReportsAlreadyPresent() throws {
        let workspace = try TemporaryWorkspace(label: "capture-dupe")
        let folder = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let urls = Fixtures.all.prefix(2).map { folder.appendingPathComponent($0.name) }
        let first = try library.importURLs(urls)
        #expect(first.imported == 2)
        #expect(!first.hasDuplicates)

        let second = try library.importURLs(urls)
        #expect(second.imported == 0)
        #expect(second.updated == 2)
        #expect(second.alreadyPresent == 2)
        #expect(second.hasDuplicates)
        #expect(second.summary.contains("already in library"))
        #expect(try library.itemCount() == 2)
    }

    @Test("the same file through two path spellings is one item")
    func canonicalPathsDedupe() throws {
        let workspace = try TemporaryWorkspace(label: "capture-canonical")
        let folder = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let url = folder.appendingPathComponent(Fixtures.all[0].name)
        // `/var/folders/…` vs `/private/var/folders/…` — the same file, two spellings.
        let canonical = URL(fileURLWithPath: PathUtilities.canonicalPath(url.path))

        let report = try library.importURLs([url, url, canonical])

        #expect(report.scanned == 1)
        #expect(report.imported == 1)
        #expect(try library.itemCount() == 1)
    }

    @Test("copy mode treats identical bytes as one item")
    func copyModeContentDedupe() throws {
        let workspace = try TemporaryWorkspace(label: "capture-copy")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let folder = workspace.url.appendingPathComponent("same-bytes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Fixtures.all[0].data
        let first = folder.appendingPathComponent("one.png")
        let second = folder.appendingPathComponent("two.png")
        try bytes.write(to: first)
        try bytes.write(to: second)

        let report = try library.importURLs([first, second], mode: .copy)

        #expect(report.mode == .copy)
        #expect(report.imported == 1)
        #expect(report.duplicates == 1)
        #expect(report.copiedOriginals == 1)
        #expect(DirectoryStats.fileCount(in: library.paths.originalsURL) == 1)
        #expect(try library.itemCount() == 1)
    }

    // MARK: - Inbox rule

    @Test("dropping on a collection files the item out of the Inbox")
    func assignedCollectionFiles() throws {
        let workspace = try TemporaryWorkspace(label: "capture-assign")
        let folder = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let collectionID = try library.createCollection(name: "Shots")
        let report = try library.importURLs(
            Fixtures.all.prefix(2).map { folder.appendingPathComponent($0.name) },
            target: .assignedCollection(collectionID)
        )

        #expect(report.destinationLabel == "Shots")
        #expect(report.imported == 2)
        #expect(try library.itemCount(inCollection: collectionID) == 2)
        #expect(try library.inboxItemCount() == 0)
    }

    @Test("a collection import keeps the items in the Inbox")
    func collectionTargetKeepsInbox() throws {
        let workspace = try TemporaryWorkspace(label: "capture-collection")
        let folder = try workspace.makeFixtures(count: 2)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let collectionID = try library.createCollection(name: "Batch")
        _ = try library.importURLs(
            Fixtures.all.prefix(2).map { folder.appendingPathComponent($0.name) },
            target: .collection(collectionID)
        )

        #expect(try library.itemCount(inCollection: collectionID) == 2)
        #expect(try library.inboxItemCount() == 2)
    }

    @Test("an unknown collection target throws instead of capturing nowhere")
    func unknownCollectionThrows() throws {
        let workspace = try TemporaryWorkspace(label: "capture-unknown")
        let folder = try workspace.makeFixtures(count: 1)
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let url = folder.appendingPathComponent(Fixtures.all[0].name)
        #expect(throws: AtlasError.self) {
            try library.importURLs([url], target: .assignedCollection(UUID()))
        }
        #expect(try library.itemCount() == 0)
    }

    // MARK: - Bad input

    @Test("unsupported and missing URLs are reported, not thrown")
    func badInputIsReported() throws {
        let workspace = try TemporaryWorkspace(label: "capture-bad")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let folder = workspace.url.appendingPathComponent("mixed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = folder.appendingPathComponent(Fixtures.all[0].name)
        try Fixtures.all[0].data.write(to: png)
        let note = folder.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: note)
        let missing = folder.appendingPathComponent("gone.png")

        let report = try library.importURLs([note, missing, png])

        #expect(report.imported == 1)
        #expect(report.skipped == 2)
        #expect(report.errors.contains { $0.contains("not found") })
        #expect(report.summary.contains("2 skipped"))
        #expect(try library.itemCount() == 1)
    }

    @Test("an empty batch is an empty report")
    func emptyBatch() throws {
        let workspace = try TemporaryWorkspace(label: "capture-empty")
        let library = try workspace.makeLibrary()
        defer { library.close() }

        let report = try library.importURLs([])

        #expect(report.scanned == 0)
        #expect(report.isEmpty)
        #expect(report.summary == "Nothing to import")
    }

    // MARK: - Summary copy

    @Test("the summary line is deterministic")
    func summaryCopy() {
        var report = CaptureReport(mode: .connected, destinationLabel: "Inbox")
        #expect(report.summary == "Nothing to import")

        report.imported = 1
        #expect(report.summary == "Inbox: Imported 1 item")

        report.imported = 3
        #expect(report.summary == "Inbox: Imported 3 items")

        report.updated = 2
        #expect(report.summary == "Inbox: Imported 3 items · 2 already in library")
        #expect(report.alreadyPresent == 2)
        #expect(report.changed == 5)

        report.skipped = 1
        report.errors = ["broken.png: unreadable"]
        #expect(report.summary == "Inbox: Imported 3 items · 2 already in library · 1 skipped · 1 error")
    }

    // MARK: - Target semantics

    @Test("capture targets carry their Inbox-rule flag")
    func targetFlags() {
        let id = UUID()

        #expect(CaptureTarget.inbox.collectionID == nil)
        #expect(CaptureTarget.inbox.keepsInboxLink)

        #expect(CaptureTarget.collection(id).collectionID == id)
        #expect(CaptureTarget.collection(id).keepsInboxLink)

        #expect(CaptureTarget.assignedCollection(id).collectionID == id)
        #expect(!CaptureTarget.assignedCollection(id).keepsInboxLink)
    }
}
