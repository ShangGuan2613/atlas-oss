import AtlasCore
import CoreGraphics
import Foundation

// MARK: - Drag payload

/// What is being dragged. Encoded as a plain string so it can ride on
/// `NSItemProvider(object:)` without a custom `UTType` registration.
enum SidebarDragPayload: Equatable {
    case items([UUID])
    case collection(UUID)

    static let itemsPrefix = "atlas.drag.items:"
    static let collectionPrefix = "atlas.drag.collection:"

    init?(raw: String) {
        if raw.hasPrefix(Self.itemsPrefix) {
            let ids = raw
                .dropFirst(Self.itemsPrefix.count)
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return nil }
            self = .items(ids)
        } else if raw.hasPrefix(Self.collectionPrefix) {
            guard let id = UUID(uuidString: String(raw.dropFirst(Self.collectionPrefix.count))) else {
                return nil
            }
            self = .collection(id)
        } else {
            return nil
        }
    }

    var encoded: String {
        switch self {
        case .items(let ids):
            return Self.itemsPrefix + ids.map(\.uuidString).joined(separator: ",")
        case .collection(let id):
            return Self.collectionPrefix + id.uuidString
        }
    }
}

// MARK: - Drop target

enum SidebarDropTarget: Equatable {
    case collection(LibraryCollection)
    case tag(LibraryTag)
    /// The "Collections" section header — dropping a collection here un-nests it.
    case root
}

// MARK: - Drop zone

/// A row is split into thirds: the outer bands reorder, the middle nests/assigns.
enum SidebarDropZone: Equatable {
    case before
    case onto
    case after
}

// MARK: - Drop action

enum SidebarDropAction: Equatable {
    case none
    case reorder(collection: UUID, parentID: UUID?, before: UUID?)
    case nest(collection: UUID, into: UUID)
    case addItems(itemIDs: [UUID], collectionID: UUID)
    case tagItems(itemIDs: [UUID], tagID: UUID)
}

// MARK: - Tree maths (pure)

/// All sidebar geometry and drop-resolution logic, kept free of SwiftUI so it can be
/// unit-tested offscreen.
enum SidebarTree {

    /// Fraction of the row height at each end that counts as a reorder band.
    static let edgeFraction: CGFloat = 0.28

    static func zone(locationY: CGFloat, rowHeight: CGFloat) -> SidebarDropZone {
        guard rowHeight > 0 else { return .onto }
        let fraction = locationY / rowHeight
        if fraction < edgeFraction { return .before }
        if fraction > 1 - edgeFraction { return .after }
        return .onto
    }

    /// Depth-first flattening, `self` first.
    static func allNodes(_ tree: [LibraryCollection]) -> [LibraryCollection] {
        tree.flatMap { $0.flattened() }
    }

    /// A collection plus everything beneath it. Used to reject cycles.
    static func descendants(of id: UUID, in tree: [LibraryCollection]) -> Set<UUID> {
        guard let node = allNodes(tree).first(where: { $0.id == id }) else { return [id] }
        return Set(node.flattened().map(\.id))
    }

    /// Ordered sibling ids under one parent (root when `nil`).
    static func siblingIDs(parentID: UUID?, in tree: [LibraryCollection]) -> [UUID] {
        guard let parentID else { return tree.map(\.id) }
        return allNodes(tree).first { $0.id == parentID }?.children.map(\.id) ?? []
    }

    /// Resolves a drag into an action. Returns `.none` for anything invalid (self-drop,
    /// cycle, collection onto a tag, items onto a section header).
    static func resolve(
        payload: SidebarDragPayload,
        target: SidebarDropTarget,
        zone: SidebarDropZone,
        tree: [LibraryCollection]
    ) -> SidebarDropAction {
        switch payload {
        case .items(let itemIDs):
            guard !itemIDs.isEmpty else { return .none }
            switch target {
            case .collection(let collection):
                return .addItems(itemIDs: itemIDs, collectionID: collection.id)
            case .tag(let tag):
                return .tagItems(itemIDs: itemIDs, tagID: tag.id)
            case .root:
                return .none
            }

        case .collection(let draggedID):
            switch target {
            case .tag:
                return .none
            case .root:
                // Dropping on the section header lifts the collection back to the top level.
                return .reorder(collection: draggedID, parentID: nil, before: nil)
            case .collection(let target):
                if target.id == draggedID { return .none }
                if descendants(of: draggedID, in: tree).contains(target.id) { return .none }

                if target.isInbox {
                    // The Inbox is pinned and flat: only "drop right below it" makes sense.
                    guard zone == .after else { return .none }
                    let firstUserRoot = tree.first { !$0.isInbox }?.id
                    return .reorder(collection: draggedID, parentID: nil, before: firstUserRoot)
                }

                switch zone {
                case .onto:
                    return .nest(collection: draggedID, into: target.id)
                case .before:
                    return .reorder(collection: draggedID, parentID: target.parentID, before: target.id)
                case .after:
                    return .reorder(
                        collection: draggedID,
                        parentID: target.parentID,
                        before: siblingAfter(target, in: tree)
                    )
                }
            }
        }
    }

    /// Next sibling after `node`, or `nil` when it is the last one (append).
    static func siblingAfter(_ node: LibraryCollection, in tree: [LibraryCollection]) -> UUID? {
        let siblings = node.parentID
            .flatMap { parent in allNodes(tree).first { $0.id == parent }?.children }
            ?? tree
        guard let index = siblings.firstIndex(where: { $0.id == node.id }) else { return nil }
        let next = siblings.index(after: index)
        return next < siblings.endIndex ? siblings[next].id : nil
    }
}

// MARK: - Rows

/// One rendered line in the sidebar.
struct SidebarRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case inbox
        case collection
        case tag
    }

    let id: String
    let kind: Kind
    let title: String
    let itemCount: Int
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    let entry: SidebarEntry
    let collectionID: UUID?
    let tagID: UUID?

    /// Rows visible for the current disclosure state, depth-first.
    static func rows(
        tree: [LibraryCollection],
        tags: [LibraryTag],
        expanded: Set<UUID>
    ) -> [SidebarRow] {
        var rows: [SidebarRow] = []

        func append(_ node: LibraryCollection, depth: Int) {
            let isExpanded = expanded.contains(node.id)
            rows.append(
                SidebarRow(
                    id: "collection:\(node.id.uuidString)",
                    kind: node.isInbox ? .inbox : .collection,
                    title: node.name,
                    itemCount: node.itemCount,
                    depth: depth,
                    hasChildren: !node.children.isEmpty,
                    isExpanded: isExpanded,
                    entry: node.isInbox ? .inbox : .collection(node.id),
                    collectionID: node.id,
                    tagID: nil
                )
            )
            guard isExpanded else { return }
            for child in node.children {
                append(child, depth: depth + 1)
            }
        }

        for root in tree {
            append(root, depth: 0)
        }

        for tag in tags {
            rows.append(
                SidebarRow(
                    id: "tag:\(tag.id.uuidString)",
                    kind: .tag,
                    title: tag.name,
                    itemCount: tag.itemCount,
                    depth: 0,
                    hasChildren: false,
                    isExpanded: false,
                    entry: .tag(tag.id),
                    collectionID: nil,
                    tagID: tag.id
                )
            )
        }

        return rows
    }
}
