import AppKit
import AtlasCore
import SwiftUI

// MARK: - Board state

/// Camera + transient interaction state for one Canvas pane.
///
/// Positions live in `LibraryModel` (they are persisted); everything here is view state, so
/// a scope switch or a window resize never touches the database. `@StateObject`-owned by
/// `ContentView` so the toolbar can refit the camera from outside the board.
@MainActor
final class CanvasBoardState: ObservableObject {
    @Published var camera = CanvasCamera()
    @Published var viewport: CGSize = .zero
    /// Pointer position in view points, from `onContinuousHover`; the zoom anchor.
    ///
    /// Deliberately **not** `@Published`: nothing on screen depends on it — only the zoom
    /// anchor reads it — and `onContinuousHover` fires on every pointer move. Publishing it
    /// re-evaluated the whole board body 60–120 times a second just for moving the mouse over
    /// canvas, which is the `objectWillChange` flood P2-A-FEEL set out to kill.
    var pointer: CGPoint?
    /// True while Space is held: tiles stop taking hit tests so a drag pans instead.
    @Published var spaceHeld = false
    /// In-flight drag, drawn as an offset over the committed positions.
    @Published var liveDrag: LiveDrag?
    /// Set when the camera should frame the content on the next layout pass.
    @Published var needsFit = true

    /// True while the board is showing content the viewport cannot see. Unbounded panning
    /// means this is a normal state, not an error: the HUD turns it into a **Fit** button.
    @Published var contentIsOffscreen = false

    struct LiveDrag: Equatable {
        let ids: Set<UUID>
        /// World points, so the preview and the commit use the same units.
        let delta: CGSize
    }

    /// Where a zoom gesture is anchored: the pointer, else the middle of the pane.
    func anchorPoint() -> CGPoint {
        pointer ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
    }

    /// P2-B: **no containment**. The camera is sanitised (zoom on the ladder, finite origin)
    /// and otherwise left exactly where the gesture put it.
    func apply(_ camera: CanvasCamera) {
        self.camera = camera.sanitized()
    }

    func zoom(by factor: Double, anchoredAt anchor: CGPoint? = nil) {
        apply(camera.zoomed(by: factor, anchoredAt: anchor ?? anchorPoint()))
    }

    func pan(byViewDelta delta: CGSize) {
        apply(camera.panned(byViewDelta: delta))
    }

    func fit(content: CGRect) {
        guard viewport.width > 1, viewport.height > 1 else {
            needsFit = true
            return
        }
        let bounds = content.isEmpty ? CanvasLayout.packedBounds(count: 1) : content
        camera = CanvasCamera.fitting(content: bounds, viewport: viewport)
        needsFit = false
        contentIsOffscreen = false
    }

    /// Re-evaluates the "is the content reachable?" flag the HUD reads.
    ///
    /// Assigned only when it actually flips: `@Published` fires `objectWillChange` on every
    /// write, so an unconditional assignment here would buy a second full board re-evaluation
    /// on each camera step — the board itself would be doing the flood.
    func refreshOffscreen(content: CGRect) {
        guard !content.isEmpty, viewport.width > 1, viewport.height > 1 else {
            if contentIsOffscreen { contentIsOffscreen = false }
            return
        }
        let next = !camera.shows(content, viewport: viewport)
        if next != contentIsOffscreen { contentIsOffscreen = next }
    }

    func resetCamera(content: CGRect) {
        needsFit = true
        fit(content: content)
    }
}

// MARK: - Canvas view

/// The Canvas board: an AppKit `NSView` (`CanvasBoardNSView`) plus a SwiftUI HUD.
///
/// Tiles are `CALayer`s in world space. The camera is one `sublayerTransform`. Hit-testing
/// converts the pointer with the inverse camera matrix and tests `CanvasLayout.tileFrame`,
/// so a click lands on the tile under the cursor at any zoom. The P2-A Feel SwiftUI board
/// (world-space tiles inside `.scaleEffect` + `.offset`) is no longer the interactive path:
/// SwiftUI hit-testing does not track that transform, and every camera publish rebuilt the
/// tile tree.
///
/// **Two surfaces, one view (P2-B).** `unbounded == false` is Canvas: tile drags clamp to the
/// board rect and a dashed frame is drawn. `unbounded == true` is Infinity: same rows, same
/// view, no frame, no clamp. `Fit` and the off-screen pill stay in the SwiftUI HUD.
struct CanvasView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.appearance) private var tokens

    @ObservedObject var board: CanvasBoardState
    @Binding var selection: ItemSelection
    /// Infinity: no board frame, no drag containment. Canvas: both.
    let unbounded: Bool
    /// Opens the shared lightbox for an item.
    let onOpenLightbox: (UUID) -> Void

    @StateObject private var events = GridEventMonitor()

    /// World union of the current tiles. The HUD's off-screen pill reads this.
    @State private var contentBounds: CGRect = .zero
    /// True when Space was used to pan, so releasing it does not also open the lightbox.
    @State private var spaceWasUsed = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasBoardRepresentable(
                    board: board,
                    items: model.items,
                    requests: thumbnailRequests,
                    positions: model.canvasPositions,
                    selectedIDs: selection.ids,
                    bounded: !unbounded,
                    onSelect: { id, flags in
                        handleSelect(id, flags: flags)
                    },
                    onOpenLightbox: onOpenLightbox,
                    onMoveItems: { ids, delta in
                        model.moveCanvasItems(ids, byWorld: delta, bounded: !unbounded)
                    }
                )
                hud
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background(tokens.backgroundFill ?? Color.clear)
            .clipped()
            .onAppear {
                board.viewport = proxy.size
                reload()
                wireEvents()
            }
            .onDisappear {
                events.stop()
                board.spaceHeld = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                board.spaceHeld = false
            }
            .onChange(of: proxy.size) { _, size in
                board.viewport = size
                if board.needsFit { fitCamera() }
            }
            .onChange(of: model.canvasPositions) { _, positions in
                contentBounds = Self.bounds(of: positions)
                if board.needsFit { fitCamera() }
                board.refreshOffscreen(content: contentBounds)
            }
            .onChange(of: model.items) { _, _ in
                model.reloadCanvasPositions()
                board.needsFit = true
                reload()
            }
            .onChange(of: model.selection) { _, _ in
                model.reloadCanvasPositions()
                board.needsFit = true
                reload()
            }
            .onChange(of: board.camera) { _, _ in
                board.refreshOffscreen(content: contentBounds)
            }
        }
    }

    /// Requests built once per body from the current items. The native board loads them.
    private var thumbnailRequests: [UUID: ThumbnailRequest] {
        Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, model.thumbnailRequest(for: $0)) })
    }

    private static func bounds(of positions: [CanvasItemPosition]) -> CGRect {
        guard !positions.isEmpty else { return .zero }
        let frames = positions.map { CanvasLayout.tileFrame(for: $0) }
        return frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    }

    /// Zoom readout plus the soft **find content** affordance. Unbounded panning means content
    /// can leave the screen — so the board says where it went and offers one click back,
    /// instead of P2-A's clamp refusing to let you leave in the first place.
    private var hud: some View {
        VStack {
            HStack {
                Spacer()
                if board.contentIsOffscreen {
                    Button {
                        fitCamera()
                    } label: {
                        Label("Content is off-screen — Fit", systemImage: "scope")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Frame the content of this board (⌘⇧F)")
                }
            }
            .padding(.horizontal, tokens.contentPadding)
            .padding(.top, 8)
            Spacer()
            HStack(spacing: 8) {
                Text("\(Int((board.camera.zoom * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(
                    unbounded
                        ? "edgeless · drag to pan · ⌘-scroll or pinch to zoom · ⌘⇧F to find content"
                        : "drag to pan · ⌘-scroll or pinch to zoom · drag a tile to place it"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, tokens.contentPadding)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Data

    /// Refreshes content bounds and fits when the board asked for it. The native view owns
    /// the spatial index and the layer diff; this only keeps the HUD honest.
    private func reload() {
        contentBounds = Self.bounds(of: model.canvasPositions)
        if board.needsFit { fitCamera() }
        board.refreshOffscreen(content: contentBounds)
    }

    private func fitCamera() {
        guard !contentBounds.isEmpty else {
            if board.viewport.width > 1 { board.fit(content: .zero) }
            return
        }
        board.fit(content: contentBounds)
    }

    // MARK: - Selection

    /// Click from the native board. `nil` clears. Modifier flags come from the mouse event,
    /// not from a SwiftUI gesture (those reported the wrong coordinate space).
    private func handleSelect(_ id: UUID?, flags: NSEvent.ModifierFlags) {
        guard let id else {
            selection.clear()
            return
        }
        let ids = model.items.map(\.id)
        if flags.contains(.shift) {
            selection.extend(to: id, in: ids, additive: flags.contains(.command))
        } else if flags.contains(.command) {
            selection.toggle(id)
        } else {
            selection.select(id)
        }
    }

    // MARK: - Events

    private func wireEvents() {
        // Pan and zoom live on `CanvasBoardNSView` (`scrollWheel` / `magnify`), where the
        // anchor is a point in that view. A second local monitor here would move the camera
        // twice per wheel event.
        events.handleScroll = nil

        events.handleKey = { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌘⇧F — Fit / find content. The single recovery gesture an edgeless camera needs.
            if flags.contains(.command), flags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                fitCamera()
                return true
            }

            // ⌘A selects the board; Escape clears it; Space arms panning.
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
                selection.selectAll(model.items.map(\.id))
                return true
            }
            switch event.keyCode {
            case GridKey.escape:
                guard !selection.isEmpty else { return false }
                selection.clear()
                return true
            case GridKey.space:
                if !board.spaceHeld {
                    board.spaceHeld = true
                    spaceWasUsed = false
                }
                return true
            default:
                return false
            }
        }

        events.handleKeyUp = { event in
            guard event.keyCode == GridKey.space else { return false }
            let panned = spaceWasUsed
            board.spaceHeld = false
            // A Space *tap* (no pan in between) still opens the lightbox, like the grid.
            if !panned, let focused = selection.focusedID ?? selection.ids.first {
                onOpenLightbox(focused)
            }
            return true
        }

        events.start()
    }
}

// MARK: - Camera ↔ drag helpers

extension CanvasCamera {
    /// A drag's view-point translation as world points.
    ///
    /// - Parameter translation: **view** points — i.e. from a `.global` drag, not from the
    ///   board's scaled tile layer, whose local space is already world space.
    func worldDelta(forViewTranslation translation: CGSize) -> CGSize {
        CGSize(
            width: translation.width * worldPerViewPoint,
            height: translation.height * worldPerViewPoint
        )
    }
}
