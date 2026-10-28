import AtlasCore
import Foundation

/// One entry in the sidebar: the "All items" pseudo-collection, the pinned Inbox, a
/// collection node, or a tag.
enum SidebarEntry: Hashable, Identifiable {
    case all
    case inbox
    case collection(UUID)
    case tag(UUID)

    var id: String {
        switch self {
        case .all: return "__all__"
        case .inbox: return "__inbox__"
        case .collection(let id): return "collection:\(id.uuidString)"
        case .tag(let id): return "tag:\(id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .all: return "All Items"
        case .inbox: return "Inbox"
        case .collection: return "Collection"
        case .tag: return "Tag"
        }
    }
}

/// Loads the default library and exposes it to SwiftUI.
///
/// `AtlasLibrary` is a synchronous SQLite wrapper, so reads and writes happen here on the
/// main actor. Queries are indexed and small; thumbnails decode off-main.
@MainActor
final class LibraryModel: ObservableObject {

    // MARK: - Published state

    @Published var selection: SidebarEntry? = .inbox {
        didSet {
            guard selection != oldValue else { return }
            reloadItems()
        }
    }

    @Published private(set) var tree: [LibraryCollection] = []
    @Published private(set) var tags: [LibraryTag] = []
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var libraryPath: String = ""
    @Published private(set) var totalItemCount = 0
    @Published private(set) var inboxItemCount = 0
    @Published private(set) var loadError: String?
    @Published private(set) var isLoaded = false

    /// Which collection nodes are disclosed. Kept here so a reload keeps the shape.
    @Published var expanded: Set<UUID> = []

    /// Info-panel + colour-filter state (P1-C). A value type so the panel state is one
    /// published write; the bridge lives in `LibraryModel+Info.swift`.
    @Published var info = InfoState()

    // MARK: - Canvas (P2-A)

    /// Placements for the board the sidebar currently points at, in paint order.
    ///
    /// The truth lives in SQLite (`item_positions`); this is the loaded copy the board
    /// renders. Empty therefore means "not loaded yet", not "no layout" — the loader
    /// seeds a packed layout the first time a board is opened.
    ///
    /// The setter is internal rather than `private(set)` because the whole board bridge lives
    /// in `LibraryModel+Canvas.swift`, mirroring how `AtlasLibrary.database` is opened up for
    /// its own extensions. Writes go through that file, never through a view.
    @Published var canvasPositions: [CanvasItemPosition] = []

    /// Which board those placements belong to: the selected collection, or `all`.
    @Published var canvasScope: CanvasScope = .all

    /// Module-internal so the Info/colour bridge (`LibraryModel+Info.swift`) can share the
    /// connection, mirroring how `AtlasLibrary.database` is shared by the Core extensions.
    var library: AtlasLibrary?

    // MARK: - Lifecycle

    /// Opens (creating if absent) `~/Library/Application Support/AtlasOSS/default.atlaslibrary`.
    ///
    /// `ATLAS_LIBRARY_PATH` overrides the location — used by the bench scripts to point the
    /// app at a throwaway library instead of the user's. Nothing else reads it.
    func open() {
        if let override = ProcessInfo.processInfo.environment["ATLAS_LIBRARY_PATH"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            open(at: URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
            return
        }
        open(at: LibraryPaths.defaultRoot)
    }

    /// Opens a specific library. Split out of `open()` so tests can drive the model
    /// against a throwaway `.atlaslibrary` instead of the user's real one.
    func open(at root: URL) {
        guard library == nil else { return }
        do {
            let library = try AtlasLibrary(url: root)
            self.library = library
            self.libraryPath = library.paths.root.path
            self.isLoaded = true
            self.expanded = Set(try library.allCollections().map(\.id))
            reloadAll()
            // Inbox is the landing view, but a *migrated* v1 library was deliberately not
            // retro-filed into it (migration does not rewrite the user's filing). Landing
            // on an empty Inbox while the library is full would just look broken.
            if inboxItemCount == 0, totalItemCount > 0 {
                selection = .all
            }
        } catch {
            self.libraryPath = root.path
            self.loadError = "Could not open library: \(error)"
        }
    }

    /// Reloads the sidebar tree, tags, counts and the current item query.
    func reloadAll() {
        reloadSidebar()
        reloadItems()
    }

    /// Reloads everything *except* the current item query — used after a metadata edit
    /// (tagging from the Info panel) that should not move the selection under the user.
    func reloadSidebar() {
        guard let library else { return }
        do {
            tree = try library.collectionTree()
            tags = try library.tags()
            totalItemCount = try library.itemCount()
            inboxItemCount = try library.inboxItemCount()

            // Keep the disclosure set honest: drop ids that no longer exist, and make sure
            // anything with children starts open so nesting is discoverable.
            let liveIDs = Set(try library.allCollections().map(\.id))
            expanded.formIntersection(liveIDs)
            for node in SidebarTree.allNodes(tree) where !node.children.isEmpty {
                expanded.insert(node.id)
            }

            loadError = nil
        } catch {
            loadError = "Could not read library: \(error)"
        }
    }

    func reloadItems() {
        guard let library else { return }
        do {
            let base: [LibraryItem]
            switch selection {
            case .all, .none:
                base = try library.items()
            case .inbox:
                base = try library.items(collectionID: library.inboxCollection().id)
            case .collection(let id):
                base = try library.items(collectionID: id)
            case .tag(let id):
                base = try library.items(tagID: id)
            }
            // P1-C: a colour filter layers on top of the sidebar query instead of
            // replacing it, so clearing the filter restores exactly what was there.
            items = filteredByColor(base, library: library)
            loadError = nil
        } catch {
            items = []
            loadError = "Could not read items: \(error)"
        }
    }

    /// Lets extensions in other files surface failures without loosening `private(set)`.
    func reportLoadError(_ message: String) {
        loadError = message
    }

    func select(_ entry: SidebarEntry?) {
        selection = entry
    }

    // MARK: - Lookups

    func collection(for id: UUID) -> LibraryCollection? {
        SidebarTree.allNodes(tree).first { $0.id == id }
    }

    func tag(for id: UUID) -> LibraryTag? {
        tags.first { $0.id == id }
    }

    /// Title for the detail pane header.
    var selectionTitle: String {
        switch selection {
        case .all, .none: return "All Items"
        case .inbox: return "Inbox"
        case .collection(let id): return collection(for: id)?.name ?? "Collection"
        case .tag(let id): return "#\(tag(for: id)?.name ?? "tag")"
        }
    }

    /// Absolute file URL backing an item: `originals/<storedName>` for copied items,
    /// `sourcePath` for connected ones.
    func fileURL(for item: LibraryItem) -> URL? {
        if let storedName = item.storedName, let library {
            return library.paths.url(forStoredName: storedName)
        }
        if let sourcePath = item.sourcePath {
            return URL(fileURLWithPath: sourcePath)
        }
        return nil
    }

    // MARK: - Thumbnails (P1f)

    /// `<library>/thumbnails` — the disk tier. `nil` until the library is open.
    var thumbnailsRoot: URL? {
        library?.paths.thumbnailsURL
    }

    /// Everything a grid cell needs to fetch its picture. The cell never sees the original
    /// URL directly, so it cannot accidentally decode it on the hot path: the loader always
    /// tries the disk tier first and only falls back to `sourceURL` when there is no thumb.
    func thumbnailRequest(for item: LibraryItem) -> ThumbnailRequest {
        ThumbnailRequest(item: item, sourceURL: fileURL(for: item), thumbnailsRoot: thumbnailsRoot)
    }

    /// Number of thumbnail files on disk for the current library (P1f bench + diagnostics).
    var thumbnailFileCount: Int {
        library?.thumbnails.fileCount() ?? 0
    }

    // MARK: - Disclosure

    func toggleExpansion(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    // MARK: - Collections

    /// Creates a collection and selects it. `parentID` of `nil` means root.
    @discardableResult
    func createCollection(name: String, parentID: UUID? = nil) -> UUID? {
        guard let library else { return nil }
        do {
            let id = try library.createCollection(name: name, parentID: parentID)
            if let parentID { expanded.insert(parentID) }
            reloadAll()
            selection = .collection(id)
            return id
        } catch {
            loadError = "Could not create collection: \(error)"
            return nil
        }
    }

    func renameCollection(_ id: UUID, name: String) {
        guard let library else { return }
        do {
            try library.renameCollection(id: id, name: name)
            reloadAll()
        } catch {
            loadError = "Could not rename collection: \(error)"
        }
    }

    func deleteCollection(_ id: UUID) {
        guard let library else { return }
        do {
            let childIDs = Set(collection(for: id)?.children.map(\.id) ?? [])
            try library.deleteCollection(id: id)
            expanded.subtract([id])
            expanded.formUnion(childIDs)
            if case .collection(let selected) = selection, selected == id {
                selection = .inbox
            }
            reloadAll()
        } catch {
            loadError = "Could not delete collection: \(error)"
        }
    }

    func createTag(name: String) {
        guard let library else { return }
        do {
            let id = try library.createTag(name: name)
            reloadAll()
            selection = .tag(id)
        } catch {
            loadError = "Could not create tag: \(error)"
        }
    }

    func renameTag(_ id: UUID, name: String) {
        guard let library else { return }
        do {
            try library.renameTag(id: id, name: name)
            reloadAll()
        } catch {
            loadError = "Could not rename tag: \(error)"
        }
    }

    func deleteTag(_ id: UUID) {
        guard let library else { return }
        do {
            try library.deleteTag(id: id)
            if case .tag(let selected) = selection, selected == id {
                selection = .inbox
            }
            reloadAll()
        } catch {
            loadError = "Could not delete tag: \(error)"
        }
    }

    // MARK: - Applying a drop

    /// Executes a resolved drag-and-drop. Returns `true` when something changed.
    @discardableResult
    func apply(_ action: SidebarDropAction) -> Bool {
        guard let library else { return false }
        do {
            switch action {
            case .none:
                return false

            case let .reorder(collectionID, parentID, before):
                try library.reorderCollection(collectionID, parentID: parentID, before: before)
                if let parentID { expanded.insert(parentID) }
                reloadAll()
                return true

            case let .nest(collectionID, into):
                try library.reorderCollection(collectionID, parentID: into, before: nil)
                expanded.insert(into)
                reloadAll()
                return true

            case let .addItems(itemIDs, collectionID):
                // Drop onto a collection files the item: membership is added and the item
                // leaves the Inbox (see the Inbox rule in AtlasCore).
                try library.assignItems(itemIDs, toCollection: collectionID)
                reloadAll()
                return true

            case let .tagItems(itemIDs, tagID):
                try library.setTags(itemIDs: itemIDs, tagIDs: [tagID], mode: .add)
                reloadAll()
                return true
            }
        } catch {
            loadError = "Could not drop: \(error)"
            return false
        }
    }
}
