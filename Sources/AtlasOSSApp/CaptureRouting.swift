import AtlasCore
import Foundation

/// Pure "where does this capture land?" rule, shared by every P1-E surface.
///
/// Keeping it out of the views means the window drop, the sidebar row drop and ⌘V cannot
/// drift apart, and it can be tested without a window.
enum CaptureRouting {

    struct Decision: Equatable {
        let target: CaptureTarget
        /// What the drop overlay and the banner call the destination.
        let label: String
    }

    /// Destination for a capture started with the given sidebar selection:
    ///
    /// - A selected **user collection** → `.assignedCollection`: import *and* file. The item
    ///   does not stay in the Inbox, which is exactly what dragging an existing item onto
    ///   that row does (`assignItems`, see the Inbox rule in AtlasCore).
    /// - Inbox, All Items, a tag, or nothing → `.inbox` only. Tags are a lens over the
    ///   library, not a home, so a drop there must not silently file into some collection.
    static func decision(for selection: SidebarEntry?, tree: [LibraryCollection]) -> Decision {
        guard case .collection(let id) = selection else {
            return Decision(target: .inbox, label: AtlasSchema.inboxCollectionName)
        }
        guard let node = allNodes(tree).first(where: { $0.id == id }), node.isUserEditable else {
            // Defensive: a `.collection` entry pointing at the Inbox (or a deleted node)
            // is still a capture to the Inbox.
            return Decision(target: .inbox, label: AtlasSchema.inboxCollectionName)
        }
        return Decision(target: .assignedCollection(node.id), label: node.name)
    }

    static func allNodes(_ tree: [LibraryCollection]) -> [LibraryCollection] {
        tree.flatMap { $0.flattened() }
    }
}
