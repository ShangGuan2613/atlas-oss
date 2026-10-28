import Foundation

/// Keyboard cursor direction for the grid.
enum GridMove {
    case left, right, up, down

    func delta(columns: Int) -> Int {
        switch self {
        case .left: return -1
        case .right: return 1
        case .up: return -max(1, columns)
        case .down: return max(1, columns)
        }
    }
}

/// Selection state for the grid: a set of item ids plus the two cursors that make
/// modifier clicks and arrow keys behave predictably.
///
/// - `anchorID` is the origin of a ⇧-click range and only moves on a plain/⌘ click.
/// - `focusedID` is the keyboard cursor and what Space opens in the lightbox.
///
/// Pure value type with no SwiftUI dependency so the semantics stay unit-testable.
struct ItemSelection: Equatable {
    private(set) var ids: Set<UUID> = []
    private(set) var anchorID: UUID?
    private(set) var focusedID: UUID?

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func isSelected(_ id: UUID) -> Bool { ids.contains(id) }

    /// Plain click: replace the selection and reset both cursors.
    mutating func select(_ id: UUID) {
        ids = [id]
        anchorID = id
        focusedID = id
    }

    /// ⌘-click: add or remove one item, leaving the rest of the selection alone.
    mutating func toggle(_ id: UUID) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        anchorID = id
        focusedID = id
    }

    /// ⇧-click: select the inclusive range between the anchor and `id`.
    /// `additive` (⌘⇧-click) unions the range into the existing selection.
    mutating func extend(to id: UUID, in orderedIDs: [UUID], additive: Bool = false) {
        guard let start = anchorID ?? focusedID,
              let from = orderedIDs.firstIndex(of: start),
              let to = orderedIDs.firstIndex(of: id)
        else {
            select(id)
            return
        }
        let range = from <= to ? from ... to : to ... from
        let ranged = Set(orderedIDs[range])
        ids = additive ? ids.union(ranged) : ranged
        focusedID = id
        // `anchorID` deliberately stays put so repeated ⇧-clicks re-derive from the origin.
    }

    mutating func selectAll(_ orderedIDs: [UUID]) {
        ids = Set(orderedIDs)
        anchorID = orderedIDs.first
        focusedID = orderedIDs.first
    }

    mutating func clear() {
        ids.removeAll()
        anchorID = nil
        focusedID = nil
    }

    /// Arrow-key movement. Clamps at the edges rather than wrapping.
    mutating func move(_ direction: GridMove, in orderedIDs: [UUID], columns: Int, extending: Bool = false) {
        guard !orderedIDs.isEmpty else { return }

        let current: Int
        if let focusedID, let index = orderedIDs.firstIndex(of: focusedID) {
            current = index
        } else if let first = ids.first, let index = orderedIDs.firstIndex(of: first) {
            current = index
        } else {
            current = 0
        }

        let target = min(orderedIDs.count - 1, max(0, current + direction.delta(columns: columns)))
        let id = orderedIDs[target]

        if extending, !ids.isEmpty {
            extend(to: id, in: orderedIDs, additive: true)
        } else {
            select(id)
        }
    }

    /// Drops ids that are no longer in the current view (collection switch, reload).
    mutating func prune(to orderedIDs: [UUID]) {
        let live = Set(orderedIDs)
        ids.formIntersection(live)
        if let anchorID, !live.contains(anchorID) { self.anchorID = nil }
        if let focusedID, !live.contains(focusedID) { self.focusedID = nil }
    }
}
