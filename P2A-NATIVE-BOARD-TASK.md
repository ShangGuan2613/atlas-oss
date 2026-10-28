# P2-A Native Board — fix cursor misalignment + jank (Grok Build)

Repo: `~/devApple/atlas-oss`. Clean-room. Prefer AppKit. Do **not** decompile Atlas.app.

## User report (2026-10-28)
「完全不跟手，光标和实际操作是错位的。而且非常卡顿，性能非常不好」

## Root cause (confirmed)
Current `CanvasView` puts tiles in world space then applies SwiftUI `.scaleEffect` + `.offset` on the container. **SwiftUI hit-testing does not reliably track that transform** → click/drag target ≠ cursor. Every camera/`liveDrag` publish still rebuilds SwiftUI tile trees → jank.

The Feel fix (aspect 0.75 + single transform) was necessary but **not sufficient**. Need a native board.

## Goal
Replace the SwiftUI tile layer with an **AppKit board** (`NSView` + `CALayer` / `sublayerTransform`) so:
1. Hit-test uses the same affine transform as drawing (`convert` / `hitTest` in view coords).
2. Pan/zoom updates **one** `CATransform3D` (or `affineTransform`) — no per-tile SwiftUI layout.
3. Drag follows the pointer 1:1 at any zoom.

## Exemplar mechanisms
- PureRef: one camera matrix, content in world space, native hit test
- AppKit photo boards: `CALayer` contents for thumbs, transform on parent

## Implement

### `CanvasBoardNSView` (new)
- `NSView` subclass, `wantsLayer = true`, layer-backed.
- Camera: `origin` + `zoom` → set parent layer `affineTransform` / `sublayerTransform` so world→view is one matrix.
- Each visible item: a `CALayer` (or `NSImageView` in a layer-hosting subview) positioned at world `(x,y)` with size `tileWidth×tileHeight×scale`.
- Cull with existing `CanvasSpatialIndex` / `visibleWorldRect`; on camera change only add/remove layers that enter/leave (diff), don't rebuild all.
- Thumbnails: pull from `ThumbnailLoader` / NSImage asynchronously; set `layer.contents`. Low-res while gesturing OK.
- **Mouse:**
  - click → select (respect ⌘/⇧ if easy)
  - drag on empty / Space → pan (change camera origin)
  - drag on tile → move tile(s) in **world** = viewDelta / zoom; live update layer position; on mouseUp persist via existing `LibraryModel.moveCanvasItems`
  - scroll → pan; ⌘-scroll → zoom anchored at cursor location **in this view**
  - double-click → lightbox callback
- Hit testing: convert window/point to world with inverse camera matrix, then test tile frames in world space. **Never** rely on SwiftUI gesture coordinate spaces for the board.

### Wire-up
- `CanvasView` becomes a thin SwiftUI shell: `CanvasBoardRepresentable` + HUD overlays (zoom %, Fit button). Selection / lightbox / model APIs stay.
- Keep Grid path untouched.
- Canvas vs Infinity: same NSView; `bounded` flag only affects drag clamp + optional board frame layer.

### Tests
- Pure geometry tests already cover packing; add camera matrix invertibility / world↔view round-trip tests if not present.
- Build + `swift test` green.

### Acceptance
1. Cursor over a tile selects/drags **that** tile (no offset), at zoom 0.5×, 1×, 2×.
2. Dragging a tile: layer tracks pointer with no laggy jump; release persists.
3. Pan/zoom of 200+ items feels continuous (transform only; no full SwiftUI re-layout).
4. STATUS: `## P2-A Native Board` section; note Feel SwiftUI board superseded for interaction.
5. Short report.

## Forbid
Decompile Atlas; rewrite Grid; unrelated features; leaving SwiftUI scaleEffect board as the interactive path.

## Out of scope
Inertia/Metal (can note as next); ⌘K; Infinity polish beyond shared NSView.
