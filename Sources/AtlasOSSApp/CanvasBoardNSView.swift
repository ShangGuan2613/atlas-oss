import AppKit
import AtlasCore
import QuartzCore

/// AppKit canvas board: one camera matrix, tiles as `CALayer`s, hit tests in world space.
///
/// SwiftUI `.scaleEffect` does not keep hit-testing in step with the drawn transform, and every
/// camera publish rebuilt the tile tree. This view draws tiles in world points and applies the
/// camera once, as `worldLayer.sublayerTransform`. A pointer is converted with the inverse of
/// that same matrix (`CanvasCamera.worldPoint(forView:)`), then tested against
/// `CanvasLayout.tileFrame`. Pan and zoom only rewrite the one transform; layers are added or
/// removed when they enter or leave the culled set.
@MainActor
final class CanvasBoardNSView: NSView {
    /// How far past the viewport tiles stay realised, matching the old SwiftUI cull margin.
    static let cullMargin: Double = 600

    var camera = CanvasCamera() {
        didSet { applyCameraTransform() }
    }

    /// Canvas clamps a drag to `CanvasLayout.boardRect` and draws a dashed frame. Infinity does neither.
    var bounded = true {
        didSet {
            guard bounded != oldValue else { return }
            updateBoardFrame()
        }
    }

    var spaceHeld = false

    /// Called with the item under the pointer (nil = empty board) and the current modifier flags.
    var onSelect: ((UUID?, NSEvent.ModifierFlags) -> Void)?
    var onOpenLightbox: ((UUID) -> Void)?
    /// World delta applied to `ids`. The host persists it (`LibraryModel.moveCanvasItems`).
    var onMoveItems: ((Set<UUID>, CGSize) -> Void)?
    /// Live world delta while a tile drag is in flight; nil when the drag ends.
    var onLiveDrag: ((CanvasBoardState.LiveDrag?) -> Void)?
    var onCameraChange: ((CanvasCamera) -> Void)?

    /// Items the board may draw, keyed by id. Positions that have no item are skipped.
    private var itemsByID: [UUID: AtlasCore.LibraryItem] = [:]
    private var requestsByID: [UUID: ThumbnailRequest] = [:]
    private var positionsByID: [UUID: CanvasItemPosition] = [:]
    private var selectedIDs: Set<UUID> = []
    private var index = CanvasSpatialIndex()

    private let worldLayer = CALayer()
    private let boardFrameLayer = CAShapeLayer()
    private var tileLayers: [UUID: CALayer] = [:]
    private var loadedKeys: [UUID: String] = [:]
    private var loadGeneration: [UUID: Int] = [:]

    private enum DragKind {
        case pan(startCamera: CanvasCamera, startPoint: CGPoint)
        case move(ids: Set<UUID>, startPositions: [UUID: CGPoint], startPoint: CGPoint)
    }

    private var drag: DragKind?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Top-left origin, matching SwiftUI and `CanvasCamera.viewPoint`.
        // The world layer is not flipped; the view is, so a world point maps 1:1.
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let layer else { return }
        layer.backgroundColor = NSColor.underPageBackgroundColor.withAlphaComponent(0.35).cgColor
        worldLayer.anchorPoint = .zero
        worldLayer.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        worldLayer.position = .zero
        if worldLayer.superlayer == nil {
            layer.addSublayer(worldLayer)
        }
        boardFrameLayer.fillColor = nil
        boardFrameLayer.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor
        boardFrameLayer.lineWidth = 1
        boardFrameLayer.lineDashPattern = [6, 6]
        boardFrameLayer.zPosition = -1
        if boardFrameLayer.superlayer == nil {
            worldLayer.addSublayer(boardFrameLayer)
        }
        applyCameraTransform()
        updateBoardFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func layout() {
        super.layout()
        // The camera matrix is independent of the view size; culling is not.
        syncVisibleLayers()
    }

    // MARK: - Host updates

    /// Replaces the board contents. Layers are diffed against the new visible set.
    func setBoard(
        items: [AtlasCore.LibraryItem],
        requests: [UUID: ThumbnailRequest],
        positions: [CanvasItemPosition],
        selected: Set<UUID>
    ) {
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        requestsByID = requests
        var placed: [UUID: CanvasItemPosition] = [:]
        for position in positions where itemsByID[position.itemID] != nil {
            placed[position.itemID] = position
        }
        positionsByID = placed
        selectedIDs = selected
        index.update(positions: Array(placed.values))
        syncVisibleLayers(forceContents: false)
        updateSelectionChrome()
    }

    func setSelected(_ ids: Set<UUID>) {
        guard ids != selectedIDs else { return }
        selectedIDs = ids
        updateSelectionChrome()
    }

    // MARK: - Camera

    private func applyCameraTransform() {
        let zoom = camera.zoom
        // One matrix for drawing. Hit-testing uses the inverse (`worldPoint(forView:)`).
        worldLayer.sublayerTransform = CATransform3DMakeAffineTransform(camera.viewTransform)
        // Stroke stays 1 px in view space.
        boardFrameLayer.lineWidth = 1 / max(zoom, 0.0001)
        boardFrameLayer.lineDashPattern = [
            NSNumber(value: 6 / max(zoom, 0.0001)),
            NSNumber(value: 6 / max(zoom, 0.0001)),
        ]
    }

    private func updateBoardFrame() {
        guard bounded else {
            boardFrameLayer.isHidden = true
            return
        }
        boardFrameLayer.isHidden = false
        let rect = CanvasLayout.boardRect
        // Position in world space. `frame` would be re-interpreted through the layer's own
        // transform; `bounds` + `position` with a zero anchor is the tile convention.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boardFrameLayer.anchorPoint = .zero
        boardFrameLayer.bounds = CGRect(origin: .zero, size: rect.size)
        boardFrameLayer.position = CGPoint(x: rect.minX, y: rect.minY)
        boardFrameLayer.path = CGPath(rect: boardFrameLayer.bounds, transform: nil)
        CATransaction.commit()
    }

    private func publishCamera(_ next: CanvasCamera) {
        let sanitized = next.sanitized()
        guard sanitized != camera else { return }
        camera = sanitized
        onCameraChange?(sanitized)
        syncVisibleLayers()
    }

    // MARK: - Layers

    private func visibleIDs() -> [UUID] {
        guard bounds.width > 1, bounds.height > 1, !index.isEmpty else { return [] }
        let rect = camera.visibleWorldRect(
            viewport: CGSize(width: bounds.width, height: bounds.height),
            margin: Self.cullMargin
        )
        return index.itemIDs(in: rect)
    }

    private func syncVisibleLayers(forceContents: Bool = false) {
        let visible = Set(visibleIDs())
        let existing = Set(tileLayers.keys)

        for id in existing.subtracting(visible) {
            tileLayers[id]?.removeFromSuperlayer()
            tileLayers[id] = nil
            loadedKeys[id] = nil
        }

        for id in visible {
            guard let position = positionsByID[id] else { continue }
            let layer = tileLayers[id] ?? makeTileLayer(id: id)
            tileLayers[id] = layer
            place(layer, for: position)
            if layer.superlayer == nil {
                worldLayer.addSublayer(layer)
            }
            let pixel = CanvasLOD.decodePixelWidth(
                tileWorldWidth: CanvasLayout.tileWidth,
                scale: position.scale,
                zoom: camera.zoom
            )
            loadThumbnail(for: id, maxPixel: pixel, force: forceContents)
        }
        updateSelectionChrome()
    }

    private func makeTileLayer(id: UUID) -> CALayer {
        let layer = CALayer()
        layer.name = id.uuidString
        layer.anchorPoint = .zero
        layer.contentsGravity = .resizeAspect
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
        layer.cornerRadius = 4
        layer.borderWidth = 0
        layer.borderColor = NSColor.controlAccentColor.cgColor
        return layer
    }

    private func place(_ layer: CALayer, for position: CanvasItemPosition) {
        let frame = CanvasLayout.tileFrame(for: position)
        // Disable the implicit position animation so a drag tracks the pointer.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.minX, y: frame.minY)
        layer.zPosition = position.z
        CATransaction.commit()
    }

    private func updateSelectionChrome() {
        for (id, layer) in tileLayers {
            let on = selectedIDs.contains(id)
            layer.borderWidth = on ? 2 / max(camera.zoom, 0.0001) : 0
        }
    }

    /// Applies an in-flight world delta to the dragged layers only. No model write.
    func applyLiveDelta(_ delta: CGSize, ids: Set<UUID>) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in ids {
            guard let position = positionsByID[id], let layer = tileLayers[id] else { continue }
            layer.position = CGPoint(x: position.x + delta.width, y: position.y + delta.height)
        }
        CATransaction.commit()
    }

    private func loadThumbnail(for id: UUID, maxPixel: Int, force: Bool) {
        guard let request = requestsByID[id] else { return }
        let key = request.contentHash + "#" + String(maxPixel)
        if !force, loadedKeys[id] == key { return }
        loadedKeys[id] = key
        loadGeneration[id, default: 0] += 1
        let generation = loadGeneration[id] ?? 0
        let loader = ThumbnailLoader.shared
        Task { @MainActor in
            let image = await loader.image(for: request, maxPixel: maxPixel)
            guard self.loadGeneration[id] == generation, let image else { return }
            self.tileLayers[id]?.contents = image
        }
    }

    // MARK: - Hit testing

    /// World point under a point in this view. Inverse of the camera matrix.
    func worldPoint(forViewPoint point: CGPoint) -> CGPoint {
        camera.worldPoint(forView: point)
    }

    /// Topmost tile whose world frame contains `point` (a view point), or nil.
    func itemID(atViewPoint point: CGPoint) -> UUID? {
        let world = worldPoint(forViewPoint: point)
        let probe = CGRect(x: world.x, y: world.y, width: 0.5, height: 0.5)
        // Back-to-front; the last intersecting id paints on top.
        return index.itemIDs(in: probe).last
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The whole view is the hit target. Tile identity is resolved in world space so a
        // zoomed board cannot return a neighbour the way SwiftUI `scaleEffect` did.
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return self
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags

        if event.clickCount >= 2, let id = itemID(atViewPoint: point) {
            onSelect?(id, [])
            onOpenLightbox?(id)
            drag = nil
            return
        }

        if spaceHeld || itemID(atViewPoint: point) == nil {
            if itemID(atViewPoint: point) == nil, !flags.contains(.command), !flags.contains(.shift) {
                onSelect?(nil, [])
            }
            drag = .pan(startCamera: camera, startPoint: point)
            return
        }

        guard let id = itemID(atViewPoint: point) else {
            drag = .pan(startCamera: camera, startPoint: point)
            return
        }

        let already = selectedIDs.contains(id)
        // The host applies selection synchronously (`onSelect` mutates a Binding), so the
        // drag set below sees the selection *after* the click.
        if !already || flags.contains(.command) || flags.contains(.shift) {
            onSelect?(id, flags)
        }

        let moving: Set<UUID>
        if selectedIDs.contains(id) {
            moving = selectedIDs
        } else {
            // ⌘-click toggled this tile off: a drag should not move a tile the user just dropped.
            moving = already ? [] : [id]
        }
        guard !moving.isEmpty else {
            drag = nil
            return
        }
        var starts: [UUID: CGPoint] = [:]
        for itemID in moving {
            if let position = positionsByID[itemID] {
                starts[itemID] = CGPoint(x: position.x, y: position.y)
            }
        }
        drag = .move(ids: moving, startPositions: starts, startPoint: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .pan(let startCamera, let startPoint):
            let delta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
            publishCamera(startCamera.panned(byViewDelta: delta))
        case .move(let ids, _, let startPoint):
            let viewDelta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
            let world = camera.worldDelta(forViewTranslation: viewDelta)
            applyLiveDelta(world, ids: ids)
            onLiveDrag?(CanvasBoardState.LiveDrag(ids: ids, delta: world))
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            drag = nil
            onLiveDrag?(nil)
        }
        guard case .move(let ids, _, let startPoint) = drag else { return }
        let viewDelta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
        guard hypot(viewDelta.width, viewDelta.height) > 1 else { return }
        let world = camera.worldDelta(forViewTranslation: viewDelta)
        onMoveItems?(ids, world)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let precise = event.hasPreciseScrollingDeltas
        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        if event.modifierFlags.contains(.command) {
            let step = precise ? delta.height * 0.01 : delta.height * 0.06
            guard abs(step) > 0.0001 else { return }
            publishCamera(camera.zoomed(by: max(0.05, 1 + step), anchoredAt: point))
        } else {
            guard delta != .zero else { return }
            publishCamera(camera.panned(byViewDelta: CGSize(width: -delta.width, height: -delta.height)))
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let factor = 1 + event.magnification
        guard factor > 0 else { return }
        publishCamera(camera.zoomed(by: factor, anchoredAt: point))
    }
}
