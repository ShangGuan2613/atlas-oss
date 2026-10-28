# P2-B Task — Infinity view (Atlas parity pillar)

Repo: `~/devApple/atlas-oss`. Clean-room. See `ATLAS-PARITY.md`. Builds on P2-A Canvas.

## Goal
Ship **Infinity**: an edgeless camera over the same spatial board data as Canvas. Exemplars: **Are.na** browse + **PureRef** pan (no hard clip rect). Do not invent a second position store.

## Allow
AtlasOSSApp views/camera, reuse `item_positions` / Canvas APIs, tests, STATUS, ATLAS-PARITY. Small Core helpers only if needed for unbounded camera math.

## Forbid
Decompile Atlas; new schema unless proven necessary; browser ext; semantic search; outside repo.

## Implement
1. Enable `ViewMode.infinity` in toolbar (⌘3). Same placements as Canvas for the current scope.
2. Unbounded (or practically unbounded) pan — remove / relax the Canvas board clamp that keeps the camera from “losing” the board; keep a soft “find content” / Fit action.
3. Zoom pointer-anchored; cull with existing `CanvasSpatialIndex` (+ extend if needed for huge offsets).
4. Selection + Space lightbox + tile drag persist via existing Canvas APIs.
5. Grid | Canvas | Infinity switcher; remember last mode across collections if cheap (else note for later).

## Acceptance
1. `swift build --product AtlasOSSApp` + `swift test` green
2. 500+ items: no hard clip; selection/Space work; document FPS / limits if measured
3. Positions shared with Canvas (move in one → visible in the other after switch)
4. STATUS + short report; next slice per ATLAS-PARITY (P2c ⌘K/search)

## Out of scope
⌘K, Like/Trash/Undo, Waterfall, Links (those are later slices).
