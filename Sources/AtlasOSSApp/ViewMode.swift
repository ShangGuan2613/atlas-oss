import Foundation

/// Which surface the detail pane shows.
///
/// The three pillars share one selection, one sort order, one lightbox and — for Canvas and
/// Infinity — **one set of `item_positions` rows**. They are views of one library, not modes of
/// the app:
///
/// | Mode | Camera | Tile drag | Reads/writes |
/// |---|---|---|---|
/// | Grid | scroll view | — | `items` |
/// | Canvas | unbounded, board frame drawn | clamped to ±`CanvasLayout.boardExtent` | `item_positions` |
/// | Infinity | unbounded, no frame | unclamped | `item_positions` |
///
/// P2-A listed Infinity but reported `isAvailable == false` so the switcher could not lie about
/// what existed. P2-B ships it, so every case is selectable and ⌘3 lands on the board.
enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case grid
    case canvas
    case infinity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .canvas: return "Canvas"
        case .infinity: return "Infinity"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .canvas: return "rectangle.3.group"
        case .infinity: return "infinity"
        }
    }

    /// ⌘1 / ⌘2 / ⌘3 — the digit that selects this mode.
    var shortcutKey: String {
        switch self {
        case .grid: return "1"
        case .canvas: return "2"
        case .infinity: return "3"
        }
    }

    /// "Grid (⌘1)" — used for tooltips so the switcher documents its own keys.
    var shortcutLabel: String { "\(title) (⌘\(shortcutKey))" }

    /// Modes the toolbar offers as segments — all three, as of P2-B.
    static var selectable: [ViewMode] { allCases }

    /// True when the mode draws a board (`CanvasView`) rather than the scroll grid. Both board
    /// modes read and write the same placements, which is the P2-B acceptance criterion.
    var usesBoard: Bool { self != .grid }

    /// The mode to land on when a persisted value names something that does not exist.
    /// A storable value this build cannot show must never leave the pane blank.
    static func resolved(_ rawValue: String) -> ViewMode {
        ViewMode(rawValue: rawValue) ?? .grid
    }
}
