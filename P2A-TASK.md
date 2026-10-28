# P2-A Task — Canvas core (Atlas parity pillar)

Repo: `~/devApple/atlas-oss`. Clean-room. See `ATLAS-PARITY.md`.

## Goal
Ship a **Canvas** view for the current collection (or All): freely place items on a 2D board, pan/zoom, persist positions, reset layout. Exemplars: **PureRef** navigation feel + **tldraw** spatial culling (do not port Excalidraw full-scene cost).

## Allow
AtlasCore schema bump if needed (e.g. `item_layout` / `canvas_positions`), AtlasOSSApp views, tests, STATUS, ATLAS-PARITY.

## Forbid
Decompile Atlas; Infinity polish can stub but full Infinity is P2b; browser ext; semantic search; outside repo.

## Implement

### Schema / API
- Persist per-collection (and All?) positions: `item_id`, `collection_id` (nullable for All), `x`, `y`, `z`/`order`, optional `scale`
- API: `canvasPositions(collectionID:)`, `setCanvasPosition`, `resetCanvasLayout(collectionID:)` — reset = packed grid from current sort
- Migrate existing libs without data loss

### App
- View switcher: **Grid | Canvas** (Infinity can be disabled placeholder labeled Coming)
- CanvasView: infinite-ish board (large finite OK for P2a), scroll/pan (Space-drag or middle-mouse if easy), pinch/⌘-scroll zoom anchored on pointer
- Drag items to reposition; multi-select drag moves together
- Selection + Space lightbox still work
- Offscreen culling: only realize tiles near viewport
- Toolbar: Reset Layout

### Acceptance
1. `swift build --product AtlasOSSApp` + `swift test` green
2. Positions survive relaunch
3. 200+ items: pan/zoom usable; document any limits
4. STATUS + short report; note Infinity as P2b

## Out of scope
Smart folders, crop, links, MCP.
