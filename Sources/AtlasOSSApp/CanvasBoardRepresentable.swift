import AtlasCore
import SwiftUI

/// SwiftUI host for `CanvasBoardNSView`.
///
/// The board owns hit-testing, pan, zoom and tile drags. This wrapper only pushes model state
/// in and forwards selection, lightbox and persistence back out. Camera changes are written
/// straight onto `CanvasBoardState` so the HUD (zoom %, Fit) stays in SwiftUI.
struct CanvasBoardRepresentable: NSViewRepresentable {
    @ObservedObject var board: CanvasBoardState
    var items: [AtlasCore.LibraryItem]
    var requests: [UUID: ThumbnailRequest]
    var positions: [CanvasItemPosition]
    var selectedIDs: Set<UUID>
    var bounded: Bool
    var onSelect: (UUID?, NSEvent.ModifierFlags) -> Void
    var onOpenLightbox: (UUID) -> Void
    var onMoveItems: (Set<UUID>, CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(board: board)
    }

    func makeNSView(context: Context) -> CanvasBoardNSView {
        let view = CanvasBoardNSView()
        let coordinator = context.coordinator
        view.onCameraChange = { camera in
            coordinator.board.camera = camera
            coordinator.board.refreshOffscreen(content: coordinator.contentBounds)
        }
        view.onSelect = { id, flags in
            coordinator.onSelect?(id, flags)
        }
        view.onOpenLightbox = { id in
            coordinator.onOpenLightbox?(id)
        }
        view.onMoveItems = { ids, delta in
            coordinator.onMoveItems?(ids, delta)
        }
        view.onLiveDrag = { live in
            coordinator.board.liveDrag = live
        }
        push(view, context: context)
        return view
    }

    func updateNSView(_ view: CanvasBoardNSView, context: Context) {
        context.coordinator.board = board
        context.coordinator.onSelect = onSelect
        context.coordinator.onOpenLightbox = onOpenLightbox
        context.coordinator.onMoveItems = onMoveItems
        push(view, context: context)
    }

    private func push(_ view: CanvasBoardNSView, context: Context) {
        let content = contentBounds
        context.coordinator.contentBounds = content
        // Gestures write the camera onto the view first, then publish. Skip the echo so a
        // SwiftUI update does not restart an in-flight pan from a stale value.
        if view.camera != board.camera {
            view.camera = board.camera
        }
        view.bounded = bounded
        view.spaceHeld = board.spaceHeld
        view.setBoard(
            items: items,
            requests: requests,
            positions: positions,
            selected: selectedIDs
        )
        if board.needsFit, view.bounds.width > 1, view.bounds.height > 1 {
            board.viewport = view.bounds.size
            board.fit(content: content.isEmpty ? .zero : content)
            view.camera = board.camera
        } else if view.bounds.size != .zero {
            board.viewport = view.bounds.size
        }
        board.refreshOffscreen(content: content)
    }

    private var contentBounds: CGRect {
        guard !positions.isEmpty else { return .zero }
        let frames = positions.map { CanvasLayout.tileFrame(for: $0) }
        return frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    }

    final class Coordinator {
        var board: CanvasBoardState
        var contentBounds: CGRect = .zero
        var onSelect: ((UUID?, NSEvent.ModifierFlags) -> Void)?
        var onOpenLightbox: ((UUID) -> Void)?
        var onMoveItems: ((Set<UUID>, CGSize) -> Void)?

        init(board: CanvasBoardState) {
            self.board = board
        }
    }
}
