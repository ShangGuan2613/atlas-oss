# Status
- Route: Mac native Swift (locked 2026-10-27)
- P0: green (build + 21 tests; migrate connected; minimal viewer)
- P1 plan: `P1-PLAN.md` (A–F exemplars + slices P1a–P1f)
- **P1-A**: landed (grid feel)
- **P1-B**: landed — schema v2 + Inbox + nested collections + tags + tree sidebar
- **P1-C**: landed — schema v3 palette cache + Info inspector + colour filter
- **P1-D**: landed — design tokens + searchable Appearance settings (live apply)
- **P1-E**: landed — capture UX: window + collection-row drops, menu-bar pin, ⌘V
- **P1-F**: landed — disk thumbnail store + ladder/LRU loader + measured frame times;
  **NSCollectionView deferred** with evidence (`P1.5` follow-up below)
- **P1 gate**: closed by ghost 工头 (build/test re-verified 2026-10-28)
- **P2-A**: landed — schema v4 + Canvas board (free placement, pan/zoom, viewport culling,
  Reset Layout, Grid | Canvas switcher); Infinity is P2b
- **P2-A Feel**: landed 2026-10-28 — canvas misalignment fixed (real 4:3 footprint as the one
  source of geometry) + rendering rewritten to a single camera transform (world-space tiles,
  one `scaleEffect` + `offset`); no per-tile `viewPoint`
- **P2-A Native Board**: landed — AppKit CALayer board (hit-test == draw matrix)
- Now: **paused by user 2026-10-28** (Canvas Native Board awaiting manual verify); next when resumed: P2-B / parity queue
- GitHub: https://github.com/ShangGuan2613/atlas-oss (`main` @ first push 2026-10-28)
- Bugfix: sidebar click steal (2026-10-28)
- Tools: `~/.local/bin/pi` 1.1.0; Xcode at `/Applications/Xcode.app`; grok at `~/.grok/bin/grok`



## Sync — 2026-10-28 (Asia/Shanghai)

- User paused construction (`终止`).
- Repo: https://github.com/ShangGuan2613/atlas-oss (public, `main`)
- Snapshot pushed: P0–P1 gate closed; P2-A + Feel + Native Board landed; P2-B Infinity paused.
- Manual Canvas verify (click/drag/zoom) still owed before declaring feel done.

## P2-A — Canvas core: persisted board, pan/zoom, culling (landed)

Pillar 2 of `ATLAS-PARITY.md`. Exemplars: **PureRef** for navigation feel, **tldraw** for
spatial culling. Explicitly *not* the Excalidraw shape: no full-scene walk per frame, no
per-shape redraw bookkeeping — the camera is a value type and the visible set is one index
query per camera change. Clean-room: no Atlas assets, no decompilation.

### Schema v4 (`AtlasSchema.currentVersion = 4`)

```sql
CREATE TABLE item_positions (
    scope      TEXT NOT NULL,              -- 'all'  OR  '<collection uuid>'
    item_id    TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    x          REAL NOT NULL,              -- world points, tile top-left
    y          REAL NOT NULL,
    z_order    REAL NOT NULL DEFAULT 0,    -- paint order, higher paints later
    scale      REAL NOT NULL DEFAULT 1,
    updated_at REAL NOT NULL,
    PRIMARY KEY (scope, item_id)
);
CREATE INDEX ix_item_positions_item ON item_positions(item_id);
```

**Why a `scope` sentinel instead of a nullable `collection_id`.** The task allows
`collection_id` to be null for the All board. A genuinely `NULL` column cannot carry that
meaning inside a primary key: SQLite treats NULLs as *distinct* in unique constraints, so
`(NULL, item)` would accept a second row and `INSERT OR REPLACE` would pile up duplicates
instead of moving the tile. `'all'` is the null-free encoding of "no collection"
(`CanvasScope.storageKey`); the public API still speaks the spec's language —
`collectionID: UUID?` with `nil` == All.

**Migration is purely additive** (v3 → v4 adds one empty table): every item, collection, tag
and link survives untouched, and nothing is invented on disk. A migrated library therefore
opens with an *empty* board, which the app heals by packing the current sort order on first
open (see below) — so "migrate without data loss" holds for both directions.

### AtlasCore API — `AtlasLibrary+Canvas.swift`, `CanvasLayout.swift`

| Call | Job |
|---|---|
| `canvasPositions(collectionID:)` | rows for one board, in paint order (`nil` == All) |
| `canvasPositions(scope:)` | same, typed (`CanvasScope.all` / `.collection(UUID)`) |
| `canvasPositionCount(collectionID:)` | "has this board ever been opened?" |
| `setCanvasPosition(itemID:collectionID:x:y:z:scale:)` | single upsert |
| `setCanvasPositions(_:collectionID:)` | **batch** upsert, one transaction (multi-drag) |
| `removeCanvasPositions(itemIDs:collectionID:)` | drop rows, keep items |
| `resetCanvasLayout(collectionID:)` | repack as a grid in the **grid's own sort order** |

- Non-finite coordinates are **rejected at the edge** (`AtlasError.unsupported`): a `NaN`
  frame never intersects anything, so a tile placed with one would vanish and never return.
- `scale` is clamped to `CanvasLayout.minScale … maxScale` (0.25 … 4) on write *and* on read.
- `resetCanvasLayout` uses `items(collectionID:)` — the same query and ordering the Grid
  renders — so "Reset Layout" reproduces what the user can see behind the board.
- `CanvasLayout` is the pure geometry vocabulary: `tileSize` 220, `gap` 24 (`pitch` 244),
  `columns(n) = ceil(√n)`, block centred on the origin, `z = index`, board extent ±8 000 pt
  (≈ 65 × 65 packed tiles), `appendedPositions(existing:count:)` for imports.

### App

**View switcher.** `ViewMode` (`.grid` / `.canvas` / `.infinity`) with `isAvailable == false`
for Infinity. The toolbar shows a segmented `Grid | Canvas` picker plus a **disabled**
Infinity button whose tooltip says "coming in P2b" — a segmented control cannot disable one
segment, and a selectable segment that lies would be worse than an honest disabled button.
⌘1 / ⌘2 switch (⌘3 is swallowed for Infinity so it never beeps). The mode persists via
`@AppStorage("view.mode")` and `ViewMode.resolved` falls back to Grid for any storable value
this build cannot show.

**`CanvasView`** — the board. Gestures (PureRef feel):

| Gesture | Effect |
|---|---|
| drag empty board | pan |
| **Space**-drag (anywhere) | pan — the tile layer drops hit-testing while Space is held |
| two-finger scroll | pan |
| **⌘-scroll / pinch** | zoom, anchored on the **pointer** (world point under it is invariant) |
| drag a tile | move it; drags the whole selection when the tile is part of it |
| double-click a tile | open the shared lightbox |
| click / ⌘-click / ⇧-click | same selection semantics as the Grid |
| Space **tap** (no pan) | lightbox, exactly like the Grid |
| Escape | clear selection |
| ⌘⇧R / toolbar | **Reset Layout** — repack + refit the camera |

`ItemCell` is reused verbatim, so the canvas tile inherits the disk-thumbnail tier and the
selection ring; it gained one parameter, `showsCaption` (default `true`), which the board
turns off below 0.45× zoom (see LOD).

**Culling (the tldraw reading).** `CanvasSpatialIndex` buckets tiles into a uniform grid of
one-pitch cells, rebuilt **once per layout change**, never per frame. A camera move costs one
query over the buckets the viewport touches; tiles are realised only inside
`visibleWorldRect(margin: 600)`. Two details that came out of measurement rather than taste:

1. **Adaptive strategy.** Probing buckets is O(cells), scanning tiles is O(tiles). When the
   query rect covers more cells than there are tiles (zoomed out far enough that the whole
   board is on screen) the index scans instead. At 250 items a whole-board query dropped from
   **165 µs → 83 µs** with that switch, and the 1:1 case stays on the bucket path at 47 µs.
2. **Stepped LOD.** Below 0.45× the caption is dropped (`CanvasLOD`). Cheaper than painting
   1 000 unreadable labels, and calmer.

**Board model** (`LibraryModel+Canvas.swift`): the scope follows the sidebar — a collection is
its own board, while **All Items, Inbox and tag views all draw the `all` board** (a tag
filters items; it is not a place to file a tile, so it must not own a third layout). Missing
rows are **healed, not hidden**: a board with no rows is seeded with the packed layout on
first open, and items imported since are appended *below* the existing block and persisted, so
no tile ever moves because something new arrived. Every write is one transaction.

`GridEventMonitor` gained an optional `handleKeyUp` (Space is a held modifier on the board,
not a one-shot shortcut). `ContentView`'s grid-only paths — arrow keys, ⌘-scroll density zoom,
Space lightbox — now stand down while the Canvas is showing, and the board runs its own
monitor, so the two surfaces cannot answer the same event twice.

### Measurement — `scripts/bench-canvas.sh` (release, this machine)

250 items (the P2a acceptance size) and 1 000 items, `swift test -c release --filter CanvasBench`:

| Pass | 250 items | 1 000 items |
|---|---|---|
| `reset` (one tx, whole board) | 1.3 ms (0.005 ms/row) | 4.9 ms |
| `read` at open | 0.2 ms | 1.0 ms |
| `index` rebuild | 0.4 ms | 3.5 ms |
| `cull` (fit: whole board on screen) | 83 µs / 250 realised | 396 µs / 1 000 realised |
| `cull` (1:1: a normal viewport) | 47 µs / 120 realised | 40 µs / 120 realised |
| `zoom` step (pointer-anchored) | 0.002 µs | 0.002 µs |
| drag commit (1 row, 1 tx) | 0.14 ms | 0.14 ms |
| multi-drag commit (40 rows) | 0.24 ms | 0.36 ms |

Pan/zoom at 200+ items is comfortable: the per-move index query is 40–90 µs against a 16 ms
frame budget, and the camera maths is free. The cost that *does* grow at the far end of the
zoom range is SwiftUI layout — when a fit view realises every tile (396 µs/query at 1 000
items), the board is drawing the whole collection, which is the same thing the Grid does.

### Verification

- `swift build --product AtlasOSSApp` — clean, no warnings (all three products build).
- `swift test` — **287 tests, 0 failures**: 172 XCTest (2 skipped = the opt-in benches) +
  115 Swift Testing. Before P2-A: 247. New: 17 core (`P2-A · canvas layout`) + 20 app
  (`CanvasTests`) + 2 offscreen render + 1 bench.
  P0/P1-A…P1-F suites all still pass, and `SchemaV3Tests` now asserts against
  `AtlasSchema.currentVersion` rather than a hard-coded 3.
- **Live smoke, 220 items**: seeded a throwaway library with the CLI (`import --connected`,
  `copied originals 0`), launched the app with `-view.mode canvas` → `info` reports
  **schema v4**, and `item_positions` holds **220 rows scoped `all`** — proof the board
  loaded, seeded and persisted. Two launches later the 220 `(item_id, x, y)` tuples hash
  identically → **positions survive relaunch**.
- **Offscreen render** (`ATLAS_RENDER_OUT`): the board rasterises a 3×2 packed block with
  captions at 99 % and drops them at 10 %, with the dot grid stepping with the camera.
- Screenshot of the running app was blocked (no screen-recording permission, same constraint
  as P1-A/B/C/F), so the launch check is process liveness + database effect, not a picture.

### Known gaps / limits

- **Interactive gestures are still not automated** (unchanged constraint): drag-to-place,
  multi-drag, Space-drag, pinch and ⌘-scroll are covered by pure-math + model integration
  tests and the offscreen render, not by synthetic input. A manual pass is owed on: tile drag
  (single + multi), pan (background / Space / scroll), pointer-anchored zoom, Reset Layout.
- **Space is dual-purpose.** Held = pan-armed; a tap opens the lightbox. If you hold Space,
  pan, and release, the lightbox deliberately does not open (`spaceWasUsed`). If you hold
  Space and click a tile to drag it, the tile will not move — the board pans instead.
- **No marquee selection** on the board (the Grid has arrow keys + ⇧-ranges; the Canvas has
  click/⌘/⇧ only).
- **No drag-out to the sidebar from the Canvas.** Tiles use a `DragGesture` for placement;
  adding `.onDrag` to the same tile makes the two gestures ambiguous, so filing a tile into a
  collection still goes through the Grid. Revisit with a modifier or a drag handle in P2c.
- `scale` is persisted and clamped but there is **no UI to change it** (resize handles are
  P2d crop/rotate territory). `z_order` only ever rises — dragging a tile lifts it, and there
  is no send-to-back.
- **Tag views share the All board.** Documented consequence: dragging a tile while a tag is
  selected moves it on the All board.
- The board is a **large finite** world (±8 000 pt) and the camera is clamped so the board can
  never be lost; an unbounded camera is Infinity (**P2b**), which is also where LOD gains a
  third step and the tile budget stops being "whatever fits".
- The camera is **not persisted** per board: opening a board fits its content. Cheap to add
  later (`camera` is already a `Codable`-able value type) if it turns out to be wanted.
- No undo for moves — ⌘Z arrives with P2c.


## P2-A Feel — Canvas alignment + single camera transform (landed 2026-10-28)

User report (原话): 「错位，且不好用不流畅。Atlas究竟是怎么写的，你先模仿，然后超越」.
Clean-room: no decompilation of `/Applications/Atlas.app`, no Atlas assets. Mechanisms were
copied from public behaviour + PureRef/tldraw geometry, not from the binary.

### Root causes (both were in the code, not guessed)

1. **Misalignment — two geometries.** `CanvasSpatialIndex`, `packedBounds`/`packedPosition`,
   `canvasContentBounds` and `CanvasDrag.positions` all used a **square** `tileSize × tileSize`
   (220 × 220) footprint, while `ItemCell` drew the image box as `width × width × 0.75`.
   So the board reserved 55 pt of height per tile that never existed on screen, rows drifted,
   the culled set and the drawn set disagreed at band edges, and a drag "felt" clamped 55 pt
   before the visible edge. Four call sites, four private copies of the same wrong number.
2. **Jank — N per-tile transforms.** Every visible tile called
   `camera.viewPoint(forWorld:)` in the SwiftUI body **and** carried its own `.offset` **and**
   its own zoom-scaled `cellWidth` (so `ItemCell` re-laid-out and re-decoded on every zoom
   step). A camera move re-laid-out every realised view — the Excalidraw shape the repo
   explicitly rejects.

### A. Geometry — one footprint, everywhere (`AtlasCore/CanvasLayout.swift`)

- `tileAspect = 0.75`, `tileWidth = tileSize (220)`, `tileHeight = 165`.
- `pitchX = tileWidth + gap (244)`, `pitchY = tileHeight + gap (189)`. `pitch` is **gone** —
  one number for both axes was the bug. Packing, the dot grid and the bench all use the pair.
- `CanvasLayout.tileFrame(x:y:scale:captions:)` is now the **single** source of a tile's world
  rect. `CanvasSpatialIndex.update`, `contentBounds`, `LibraryModel.canvasContentBounds`,
  `CanvasDrag.positions` (board clamp) and `packedBounds` all go through it, so "what the index
  culls" and "what the user sees" cannot disagree again.
- **Captions off on the board** (`CanvasView.showsCaptions = false`) — Atlas/PureRef moodboard
  behaviour, and the honest one: a caption block is height the layout model does not contain.
  The Grid still shows captions. `CanvasLayout.captionHeight (34)` + `tileFrame(captions: true)`
  keep the budget modelled and tested, so re-enabling is one flag plus that argument.
- Migration: `item_positions` rows are untouched — no schema change, no renumbering. Only
  **Reset Layout** repacks, and it repacks with the new geometry.

### B. Single camera transform (`CanvasOSSApp/CanvasView.swift`)

- Tiles are laid out in **world points** (`CanvasLayout.tileWidth × tileHeight × position.scale`)
  and the camera is applied **once**, to the container:
  `.scaleEffect(zoom, anchor: .topLeading)` + `.offset(-origin * zoom)`. That is one Core
  Animation transform on one layer instead of N per-tile offsets.
- `CanvasCamera.layerTransform` (`scale`, `offset`) is the camera hoisted out of the loop, and
  `CanvasTests.testLayerTransformIsTheCameraHoistedOutOfTheLoop` asserts it equals
  `viewPoint(forWorld:)` to 0.0001 pt across four cameras (incl. ±950 000 pt) × four world
  points — so the single transform can never silently drift from the maths culling and the
  pointer anchor use. A second test pins the visible world rect onto the viewport exactly.
- Culling is unchanged and still world-space (`visibleWorldRect` + margin → index query); only
  visible IDs are instantiated. `zIndex` still orders the stack.
- **Gesture coordinate space is load-bearing**: tile drags are
  `DragGesture(minimumDistance: 2, coordinateSpace: .global)`. Inside the scaled layer `.local`
  would report the translation already divided by the zoom, and `worldDelta(forViewTranslation:)`
  would divide a second time (a 2× drag would move half as far). Documented at both ends.
- LOD changed meaning: the board draws no captions, so `CanvasLOD` now selects a **decode rung**
  (`decodePixelWidth(tileWorldWidth:scale:zoom:)`) instead of dropping text. A full zoom sweep
  hits at most 5 rungs (`ThumbnailStore.bucketSizes`), so a now-cheap camera move cannot become
  decode-bound; the `.task(id:)` decode in `ItemCell` no longer re-fires per frame.
  `ItemCell` gained an optional `decodePixelWidth` override (Grid passes `nil`, unchanged).

### C. `objectWillChange` flood (the other half of "不流畅")

Two writes were rebuilding the whole board body for free:

- `CanvasBoardState.pointer` is no longer `@Published`. `onContinuousHover` fires on every
  pointer move, so moving the mouse across the canvas re-evaluated the entire board 60–120×/s
  for a value only the zoom anchor reads. It is now a plain stored property.
- `refreshOffscreen` assigns `contentIsOffscreen` **only when it flips**; `@Published` fires
  `objectWillChange` on every write, so the old unconditional assignment bought a second full
  re-evaluation per camera step.

### D. NSView / CALayer board — **not** added, and why (evidence, not taste)

After B the per-frame work is: one cull query (**50.7 µs** mean per camera move at 250 tiles,
`P2A-BENCH cull (1:1)`, release) + one `CATransform3D` + a SwiftUI diff of ~50 realised tiles
whose values did not change. There is no measurement in this environment showing the SwiftUI
host as the bottleneck, so a `CanvasBoardNSView` would be a rewrite of the working selection /
drag / lightbox hit-testing surface for an unmeasured gain — and it cannot be validated here
(no screen recording / accessibility permission, so no interactive FPS capture).
**Trigger to build it:** Instruments → Time Profiler on a 500-tile pan, main thread > 8 ms per
frame or dropped frames in the render server. **Seam:** `CanvasBoardNSView` behind an
`NSViewRepresentable` with `wantsLayer`, one `sublayerTransform` (or a parent `CALayer` affine
transform) over tile `CALayer`s whose `contents` are the same thumbnails; gestures, selection
and persistence stay in `CanvasBoardState`, so both hosts share one state object.

### Numbers (re-run, don't trust — `./scripts/bench-canvas.sh`, release)

```
P2A-BENCH  reset        n= 250  total=     1.1ms  per-row= 0.004ms
P2A-BENCH  index        n= 250  total=     0.4ms
P2A-BENCH  cull (fit)   queries=1000  mean=109.51µs  p95=140.58µs  realized(mean)=250.0 of 250
P2A-BENCH  cull (1:1)   queries=1000  mean= 50.68µs  p95= 64.54µs  realized(mean)=144.0 of 250
P2B-BENCH  index        n= 500  total=     1.2ms  span=   957650 ×   952067 pt
P2B-BENCH  cull 950k    queries=1000  mean=  6.82µs  p95=  8.75µs  realized(mean)= 15.0 of 500
P2B-BENCH  fit zoom     0.0100  (overview floor 0.01)
```

### Verification

- `swift build --product AtlasOSSApp` — clean, 0 warnings (whole-package `swift build` also clean).
- `swift test` — green: **116** swift-testing cases (16 suites) + **187** XCTest cases
  (3 skipped = the opt-in `ATLAS_BENCH=1` harnesses), 0 failures.
- New/updated tests: geometry (`CanvasLayoutTests`: row pitch = `tileHeight + gap`, column pitch
  = `tileWidth + gap`, packed block disjoint and inside its bounds, append lands a whole row
  below with the new pitch); footprint (`testBoardTileFootprintIsTheDrawnTile` pins
  `tileAspect == GridDensity.thumbnailAspect` and footprint height == drawn height,
  `testCaptionBudgetIsOptIn`, `testIndexBucketsTheAspectFootprint`, `testDragClampUsesTheRealFootprint`);
  transform (`testLayerTransformIsTheCameraHoistedOutOfTheLoop`,
  `testLayerTransformMapsTheVisibleRectOntoTheViewport`); LOD decode ladder.
- Offscreen render, eyeballed (`ATLAS_RENDER_OUT=/tmp/atlas-render swift test --filter RenderSmokeTests`):
  `canvas-board-fitted.png` shows 3 × 2 tiles, 4:3, even 24 pt gutters both axes, no captions,
  centred; `canvas-board-zoomed-out.png` keeps the aspect at 0.2×. Canvas still differs from
  Infinity (framed vs frameless) as before.

### API changes a reader may trip over

| Was | Now |
|---|---|
| `CanvasLayout.pitch` | `pitchX` / `pitchY` |
| `CanvasSpatialIndex(positions:tileSize:cellSize:)`, `update(positions:tileSize:)` | `positions:` / `update(positions:)` (footprint from `CanvasLayout.tileFrame`) |
| `CanvasDrag.positions(… tileSize:)` | dropped (footprint from `CanvasLayout.tileFrame`) |
| `CanvasLOD.labelThreshold` / `.level(forZoom:)` | `CanvasLOD.decodePixelWidth(tileWorldWidth:scale:zoom:)` |
| `CanvasBoardState.pointer` (`@Published`) | plain property |

### Known gaps — superseded for interaction by P2-A Native Board

The SwiftUI `.scaleEffect` board described above is **no longer the interactive path**.
Hit-testing on that transform was the cursor-misalignment bug. See **P2-A Native Board**.

- **No live FPS number.** Still true: no Instruments capture in this environment.
- **No Metal.** Tiles are `CALayer.contents` now, not SwiftUI `Image`s. A `CAMetalLayer`
  board is still the ceiling at 1 000+ tiles.
- **No inertia.** Pan stops dead on lift-off. PureRef-style momentum + rubber-band at content
  edges is the single biggest remaining "feel" delta, and it is cheap (predictive deceleration
  on the existing `Camera.panned`), but it is a separate slice.
- **Zoom is a step, not a curve.** Wheel zoom is linear in delta; no eased/spring zoom, no
  zoom-to-fit animation, no semantic zoom (grid → 3-up → single) as you cross rungs.
- **Tile `scale` is modelled but unused.** `item_positions.scale` is packed, culled and clamped
  correctly now, but no gesture sets it (no corner-resize like PureRef).
- **Captions are off, not "smart".** No hover title, no zoom-dependent reveal.
- **Board frame/dot grid are drawn in view space** (deliberately — stroke width must not scale),
  so they are the one remaining non-world-space path; at extreme zoom they can shimmer where a
  world-space grid would not.


## P2-A Native Board

User report (2026-10-28): 「完全不跟手，光标和实际操作是错位的。而且非常卡顿」.

The P2-A Feel board laid tiles in world space and applied one SwiftUI
`.scaleEffect` + `.offset` on the container. That fixed per-tile layout, and it was
**not sufficient**: SwiftUI hit-testing does not track that transform, so the tile
under the cursor was not the tile that received the click. Every camera and
`liveDrag` publish still rebuilt the SwiftUI tile tree.

### What landed

- `Sources/AtlasOSSApp/CanvasBoardNSView.swift` — layer-backed `NSView`, flipped.
  Tiles are `CALayer`s at `CanvasLayout.tileFrame` in world space. The camera is one
  `worldLayer.sublayerTransform` (`CanvasCamera.viewTransform`). Hit-testing converts
  the pointer with the inverse (`worldPoint(forView:)`) and probes
  `CanvasSpatialIndex` in world space. Visible layers are diffed on camera change;
  pan/zoom does not rebuild them. Thumbs come from `ThumbnailLoader.shared` at the
  `CanvasLOD` rung and land in `layer.contents`. Click selects (⌘ / ⇧), empty drag
  and Space-drag pan, tile drag moves in world (`viewDelta / zoom`) and persists
  through `LibraryModel.moveCanvasItems`, scroll pans, ⌘-scroll and pinch zoom at
  the cursor in this view, double-click opens the lightbox. `bounded` draws the
  dashed board frame and is what the host uses to clamp drags; Infinity passes
  `bounded == false`.
- `Sources/AtlasOSSApp/CanvasBoardRepresentable.swift` — `NSViewRepresentable`.
  Pushes items, requests, positions, selection, camera and `spaceHeld`. Forwards
  selection, lightbox and moves. Writes camera changes onto `CanvasBoardState` so
  the HUD stays live.
- `CanvasView` is a shell: the representable plus the zoom / Fit HUD. No SwiftUI
  tile gestures and no `.scaleEffect` on the board. The grid is untouched.
- `CanvasCamera.viewTransform` is the matrix the layer uses.
  `CanvasTests.testCameraMatrixRoundTripsWorldAndView` checks world → view → world
  against `viewPoint` / `worldPoint` at 1×, 2×, 0.5× and a fractional zoom.

### Verification

- `swift build --product AtlasOSSApp` — clean.
- `swift test` — green (swift-testing 116 cases; XCTest green, 3 skipped benches).
- No interactive cursor pass in this environment (no window). The alignment guarantee
  is the shared matrix: drawing and `itemID(atViewPoint:)` use the same transform.

### Still out

Inertia, Metal, and a measured FPS number on a 200-tile pan.

## Bugfix — sidebar click steal (2026-10-28)

Symptom: after selecting a lower collection, upper rows stopped accepting clicks.

Cause: per-row `FileDropNSView` (P1-E) participated in ordinary hit-testing and stacked
under `LazyVStack`, so lower rows intercepted clicks meant for upper ones.

Fix:
1. `FileDropNSView.hitTest` returns `nil` unless a *file* drag is in flight (`NSPasteboard.Name.drag`).
2. Sidebar list uses `VStack` instead of `LazyVStack` so NSViewRepresentable rows are not recycled.
3. Rows get an explicit `contentShape(Rectangle())` before `onTapGesture`.

## P1-F — Perf floor: disk thumbnails + viewport discipline (landed, grid host deferred)

Shipped **P1 plan dimension F, layers 1–3**: originals are no longer decoded on the hot
path. A thumbnail is generated **once** per (content hash, size bucket), stored as JPEG under
`<library>/thumbnails/`, and every later cell — including after a relaunch — reads that file
instead of the original. The app reads disk → memory → original, in that order, and the
original is only touched when there is no disk tier or generation failed.

Layer 4 of the task (bridge the grid onto `NSCollectionView` + diffable) was **not** landed.
It is deferred *with measurements*, not on a hunch: at 1 000 **and** 4 000 items the
`LazyVGrid` host holds one-vsync frames (p95 16.70 ms, 99.2 % of frames on time), so the
rewrite would have been risk without a problem to point at. See *Grid host decision*.

| Layer | Exemplar copied | Deliberately not copied |
|---|---|---|
| Thumbs | PhotoPrism size ladder + digiKam thread sense: one JPEG per (hash, bucket), generated off the caller's actor, content-addressed | Nuke (no SPM dependency added — ~200 lines of ladder + LRU instead); `IntersectionObserver` port |
| Reuse | Nuke-style memory tier in front of the disk tier; one in-flight generation per item | main-thread ImageIO of originals |
| Grid host | viewport-only realisation (already `LazyVGrid`), disk-backed tiles | **NSCollectionView + Diffable — not copied this slice** (see decision below) |
| Measure | Instruments-style honesty: seeded library, reported method + p50/p95/p99 | vanity FPS, "assume <16 ms" |

### Core API — `Sources/AtlasCore/Thumbnails.swift`

```swift
public struct ThumbnailStore: Sendable {
    static let bucketSizes: [Int]          // [180, 270, 360, 450, 540] — the ladder
    static func bucket(forMaxPixel:) -> Int
    static func isDiskBacked(maxPixel:) -> Bool

    func url(forContentHash:maxPixel:) -> URL          // deterministic, hash-sharded
    func existingURL(forContentHash:maxPixel:) -> URL? // one `stat`, no decode
    func ensure(contentHash:maxPixel:sourceURL:) throws -> URL     // generate once
    func ensureAsync(...) async throws -> URL                      // off the caller's actor
    func fingerprint(contentHash:maxPixel:sourceURL:) -> String
    func storedFingerprint(at:) -> String?
    func isCurrent(_:contentHash:maxPixel:sourceURL:) -> Bool
    static func downsample(url:maxPixel:) -> CGImage?  // the only decode allowed in a cell
}

// Convenience on the library itself: the exact shape the task asked for.
extension AtlasLibrary {
    var thumbnails: ThumbnailStore
    func sourceURL(for:) -> URL?
    func thumbnailURL(for:maxPixel:) -> URL
    func thumbnailURLIfExists(for:maxPixel:) -> URL?
    func ensureThumbnail(for:maxPixel:) throws -> URL
    func ensureThumbnailAsync(for:maxPixel:) async throws -> URL
}
```

- **Layout.** `thumbnails/<first 2 hex of sha256>/<sha256>_<bucket>.jpg`. Two-character shard
  so a 10 k library spreads over 256 directories instead of one flat one. The name is derived
  from the **content hash already in the database**, so identity is free — no new table, no
  sidecar manifest, and deleting `thumbnails/` can never desync the catalogue.
- **Generate once.** The file is only rewritten when the recorded fingerprint stops matching.
  The fingerprint is `v1|<contentHash>|<bucket>|<source size>|<live source mtime ms>` and rides
  inside the JPEG's **EXIF `UserComment`** — re-reading it is a header parse, not a decode.
  (`kCGImagePropertyTIFFImageDescription` is silently rerouted into IPTC Caption on JPEG
  output, which is why EXIF is used; TIFF and IPTC are still read as fallbacks.)
- **Live mtime, not imported mtime.** An in-place edit of a *connected* original invalidates
  its thumbnail without a re-import — same rule as the P1-C palette signature.
- **Atomic.** Encoded into `.tmp-<uuid>.jpg` beside the destination, then `rename(2)`. A crash
  or a concurrent writer can never leave a half-written thumbnail; a reader sees the previous
  complete file or the new complete file.
- **Both import modes.** Copied items read `originals/<storedName>`, connected items read the
  linked file in place. Neither mode is asked to copy bytes to make a picture — asserted
  (`originals/` stays at 0 files in the connected tests).

### App loader — `Sources/AtlasOSSApp/ThumbnailLoader.swift`

| Tier | Holds | p95 on this machine | When |
|---|---|---|---|
| memory | decoded `NSImage`, LRU: 512 entries / 96 MB | **0.0005 ms** | scrolling back over seen tiles (~250 tiles resident) |
| disk | one JPEG per (hash, bucket), 53 KB | **1.13 ms** | every later browse, including after relaunch |
| original | the user's file | **12.05 ms** (pre-P1f behaviour) | only when the disk tier is off or generation failed |

- `ThumbnailLoader.shared` is `@MainActor`; generation and decode run in a
  utility-priority `Task.detached`, so a scroll never blocks the main actor.
- **In-flight dedupe**: 12 cells realising the same item produce **one** generation
  (`statistics().generations == 1`), not 12.
- **Never the original when a thumb exists** — `statistics().originalFallbacks` is 0 across the
  whole 1 000-item warm pass, and a test asserts it.
- If the linked source disappears (moved file, unmounted volume), the last known thumbnail is
  still served rather than the tile going blank.
- `LRUCache` (`ThumbnailCache.swift`) replaces `NSCache` so eviction is deterministic and
  testable: count limit **and** byte budget, promotion on hit, `contains` does not promote.
- `GridDensity.decodeSteps` is now *literally* `ThumbnailStore.bucketSizes` — there is one
  ladder in the codebase, so a cell can never ask for a size the store cannot serve. Shipping
  density (200 pt) still decodes 360 px, i.e. no visual change from P1-A.

### Measurement

Harness: `scripts/bench-thumbs.sh` (pipeline) and `scripts/bench-scroll.sh` (frames). Both are
reproducible; the gated test skips unless `ATLAS_BENCH=1`, so `swift test` stays fast.

**Method.** 1 000 (and 4 000) synthetic 1600×1200 high-entropy JPEGs (1.8 MB each, 1.78 GB,
26 ms/file to write) imported `.connected`. Four passes over the same library, release build
(the shipping configuration, so debug slowness cannot flatter or damn the numbers):

| Pass | What it is |
|---|---|
| `baseline` | decode the **original** per tile — the pre-P1f hot path |
| `cold` | P1f with nothing cached: generate + encode + decode one thumbnail per item |
| `warm` | P1f after a relaunch: memory empty, every thumbnail on disk |
| `memory` | a 240-tile resident window (LRU hits) |

Machine: Apple M2, 8 cores, 24 GB, macOS 27.0, internal 60 Hz 2560×1664 panel.

**Per-tile cost (thumbnails @ 360 px bucket, 200 pt cells):**

| Pass | n | mean | p50 | p95 | p99 |
|---|---|---|---|---|---|
| baseline (original decode) | 1000 | 11.77 ms | 11.67 ms | **12.05 ms** | 12.55 ms |
| cold (generate + decode) | 1000 | 14.22 ms | 14.04 ms | 14.74 ms | 16.24 ms |
| warm (disk thumb) | 1000 | 1.05 ms | 0.99 ms | **1.13 ms** | 1.68 ms |
| memory (LRU hit) | 240 | 0.0005 ms | 0.0000 ms | 0.001 ms | 0.001 ms |
| baseline | 4000 | — | — | 15.68 ms | — |
| warm | 4000 | 0.99 ms | 0.98 ms | **1.09 ms** | 1.13 ms |

- **10.6× less per-tile work** at 1 k (12.05 ms → 1.13 ms p95), **14.4×** at 4 k.
- Against a 16.67 ms frame budget: warm p95 is **6.8 %** of one frame; the pre-P1f baseline
  p95 was **72 %** of it *for a single tile* — i.e. the old path could not draw a viewport of
  30+ tiles in a frame at any library size.
- **Disk cost:** 53 KB/item → 51.6 MB per 1 000 items, **2.9 %** of the source volume
  (206 MB for 4 000).
- **Cold first browse** costs 14–16 ms of *background* CPU per item (≈14 s of generation
  spread across a utility task for 1 k). That work is what keeps the scroll smooth; it is not
  on the main thread (measured below).

**Frame times while scrolling** — `scripts/bench-scroll.sh` drives the real app at 18 pt/frame
and reports the wall-clock gap between `CADisplayLink` callbacks (a missed frame shows up as a
33 ms interval, not as a smoothed average). Palette prefetch (P1-C) is disabled during a run so
the number is the grid's, not the colour extractor's.

| Library | thumbs | frames | avg FPS | p50 | p95 | p99 | max | dropped (≥2 vsync) |
|---|---|---|---|---|---|---|---|---|
| 60 items | cold | 179 / 3 s | 59.3 | 16.67 ms | 16.71 ms | 31.35 ms | 33.33 ms | 2 (1.1 %) |
| 200 items | warm | 294 / 5 s | 58.6 | 16.67 ms | 16.71 ms | 33.34 ms | 33.34 ms | 9 (3.1 %) |
| **1 000 items** | **warm** | **480 / 8 s** | **59.9** | **16.67 ms** | **16.70 ms** | **16.93 ms** | 33.33 ms | **1 (0.2 %)** |
| 1 000 items | cold | 471 / 8 s | 58.8 | 16.67 ms | 16.71 ms | 33.33 ms | 85.66 ms | 7 (1.5 %) |
| 4 000 items | warm | 358 / 6 s | 59.5 | 16.67 ms | 16.70 ms | 22.92 ms | 33.35 ms | 3 (0.8 %) |

Reading: p50 == 16.67 ms on a 60 Hz panel means *every* vsync produced a frame; the entire
distribution sits at one frame interval. Even the cold pass — generating 1 000 thumbnails
while scrolling — keeps 98.5 % of frames on time.

### Grid host decision (layer 4, deferred)

The task's grid-host exemplar is `NSCollectionView` + diffable data source. **Not done in this
slice.** The decision rule in `P1F-TASK.md` allowed deferral only with measured proof that
`LazyVGrid` + disk thumbs is acceptable at 1 k; that proof is the table above (1 k warm p95
16.70 ms, 99.8 % of frames on time; 4 k p95 16.70 ms, 99.2 %). Bridging would mean
re-implementing, inside a diffable data source, everything P1-A already ships — pointer-anchored
zoom, arrow-key reveal via measured cell frames, drag payloads, selection mirroring, lightbox
scroll restore — i.e. a large regression surface bought with no measured frame to win back.

**P1.5 / P2 follow-up — file it, don't claim it:**
1. **Trigger conditions** to revisit: a 10 k+ library, jank on window *resize* (LazyVGrid
   re-lays out the realised window; a collection view does not), select-all / batch selection
   with 10 k rows, or per-item mutations (rename, tag) that currently republish `model.items`
   as a whole array.
2. **What to keep** during the swap: `ScrollingCellFrame` data is the contract for zoom
   anchoring and keyboard reveal — an `NSCollectionView` bridge must publish
   `layoutAttributes.frame` for the same ids, or P1-A regresses silently.
3. **Diffable ID is already free**: `LibraryItem.id` is a stable UUID from the database, so a
   `NSCollectionViewDiffableDataSource<Section, UUID>` needs no new model.
4. Do not delete the disk tier during that work — it is the thing that made frame times
   one-vsync.

### Tests

- `Tests/AtlasCoreTests/ThumbnailStoreTests.swift` — **15** tests: ladder snapping, deterministic
  sharded paths, ensure creates, second call does **not** rewrite (bytes + mtime unchanged), 
  separate files per bucket, EXIF fingerprint recorded and matched, in-place edit invalidates and
  regenerates, copied items read `originals/`, connected items read the linked file **and leave it
  untouched** (bytes + mtime), no upscale / aspect kept, missing source throws with no placeholder,
  `ensureAsync`, survives reopen, 8-way concurrent ensure lands one complete file.
- `Tests/AtlasOSSAppTests/ThumbnailLoaderTests.swift` — **9 + 6 + 3**: loader tiers (disk miss →
  generate, memory hit, fresh-loader disk hit with `originalFallbacks == 0`, broken source still
  serves its cached thumb, no-disk-tier counts the fallback, video-like source degrades to `nil`,
  12 concurrent cells → 1 generation, stats reset/purge, two items × two buckets); `LRUCache`
  eviction semantics (6); wiring (`GridDensity.decodeSteps == ThumbnailStore.bucketSizes`,
  shipping density still 360 px, `LibraryModel.thumbnailRequest` carries the library root).

### Verification

- `swift build --product AtlasOSSApp` — clean, **0 warnings**.
- `swift test` — **all green: 139 XCTest + 98 swift-testing = 237 tests executed**, plus the
  1 gated bench test reported as skipped. Baseline before this slice was 121 + 83 = 204, so
  **+33 tests**, none removed or weakened. P0/P1-A..E suites unchanged.
- Acceptance #3 checked end-to-end against a real library: 60-item `.connected` library, app
  launched with `ATLAS_LIBRARY_PATH`, `thumbnails/` went **0 → 60 files** after browsing
  (`…/thumbnails/92/924412…d3_360.jpg` shape), `originals/` stayed at **0 files**.

### Known gaps / residual risks

- **Grid host is still `LazyVGrid`.** Fine to 4 k on this machine; not proved at 10 k. See the
  follow-up above. This is the one place where P1-F does not match its exemplar table.
- **No thumbnail garbage collection.** Removing an item leaves its JPEG behind. Cost is bounded
  by the 2.9 % figure and the files are content-addressed, so a future sweep only needs to diff
  `items.content_hash` against the directory listing — but today it is unbounded.
- **Cold first browse is ~14 s of background CPU per 1 k items.** The grid stays smooth
  (measured) but the tiles arrive progressively and a fast flick outruns generation.
- **Memory tier holds ~250 tiles at 360 px** (96 MB budget). Scrolling back further than that
  is a disk read — 1 ms/tile, so it stays inside a frame, but it is not free.
- **Videos get no poster frame.** No AVFoundation path yet, so a `.mov` falls back to the SF
  Symbol placeholder and is counted in `originalFallbacks`. PhotoPrism/digiKam parity needs a
  video thumbnail pass.
- **HEIC/AVIF are untested**: ImageIO handles HEIC/AVIF in principle and the code paths are
  format-agnostic, but the repo carries no such fixture, so only PNG/JPEG are exercised.
- **Fingerprint is mtime+size based.** A same-size in-place edit with a preserved mtime (restored
  from a backup, `touch -r`) would keep a stale thumbnail. The palette cache has the same
  property; it is documented, not fixed.
- **Frame numbers are `CADisplayLink` deltas, not Instruments**: no GPU counters, no allocation
  graph, no thermal control, single machine, 60 Hz panel (no ProMotion / 8.33 ms budget measured).
- **Synthetic library, not a real one.** 1600×1200 JPEGs; a real 12 MP HEIC library would make
  the *baseline* slower (strengthening the case for the disk tier) and leave the warm number
  roughly where it is.
- **Dev env switches ship in the binary**: `ATLAS_LIBRARY_PATH`, `ATLAS_SCROLL_PROBE`,
  `ATLAS_SCROLL_STEP`, `ATLAS_BENCH*`. Harmless (no effect unless set) but they are not a UI
  feature and should move behind a debug flag before a real release.
- Bench runs leave temp workspaces when `--keep`/`--keep`-style runs are used (~11 GB across
  five directories under `$TMPDIR/atlasoss-bench-*`); they are throwaway and safe to delete.

## P1-E — Capture UX (landed)

Shipped **P1 plan dimension D**: every surface accepts files into the library. Main window,
sidebar collection rows and a menu-bar pin all drop into the Inbox or file into the hovered
collection; ⌘V imports from the pasteboard with Finder semantics; **connected is the default**
for anything that has a file on disk, and every batch ends in exactly one non-blocking
message that names duplicates. P1-A grid feel, P1-B organisation, P1-C inspector and P1-D
tokens are untouched (same commands, same defaults, all prior suites still green).

| Layer | Exemplar copied | Deliberately not copied |
|---|---|---|
| Drop targets | Atlas menu-bar pin + macOS Services: window / sidebar / status item all accept files → Inbox or hovered collection | browser extension (Later), Share Extension |
| Status item | `BCStatusItem` / droplet pattern: template symbol, drag → Inbox, transient confirmation | full Share Extension App Store store flow |
| Paste | Finder paste semantics: ⌘V of file URLs (and image data) imports connected by default | X/IG special paste policies |

### Core API (`AtlasLibrary+Capture.swift`, `Capture.swift`)

```swift
public func importURLs(_ urls: [URL],
                       mode: ImportMode = .connected,     // connected is the default
                       target: CaptureTarget = .inbox) throws -> CaptureReport
```

| `CaptureTarget` | Item linked to | In the Inbox afterwards? | Who uses it |
|---|---|---|---|
| `.inbox` | Inbox | yes | window drop on Inbox/All Items, ⌘V, menu-bar pin |
| `.collection(id)` | collection **and** Inbox | yes (bulk-import semantics, mirrors `importFolder`) | API parity only |
| `.assignedCollection(id)` | collection only | no — filed on capture | drop on a selected user collection / a sidebar row |

- **Same engine as `importFolder`.** Capture calls the same `importSingleFile`, so duplicate
detection, content hashing and `copiedOriginals` accounting cannot drift between the CLI and
the app. `.connected` captures write **0** files into `originals/` (asserted).
- **A folder stays a folder.** `importFolder` names a collection after the folder; a *drop*
of the same folder enumerates it into the target instead. Dragging `Screenshots/` onto the
window must not litter the sidebar with a “Screenshots” collection (asserted).
- **Canonicalised + de-duplicated per batch.** `/var/folders/…` and `/private/var/folders/…`
  are the same file; the same URL twice, or a folder plus one of its children, is one item.
  Re-dropping later reports `updated` (connected) or `duplicates` (copy) instead of growing
the library.
- **Bad input is reported, not thrown.** A missing path or an unsupported file increments
  `skipped` and appends to `errors`; the other nine files in the drop still import.
- `CaptureReport` carries `imported / updated / duplicates / skipped / copiedOriginals /
  bytesHashed / errors` plus a display-ready `summary` (`"Inbox: Imported 3 items · 2 already
  in library · 1 skipped"`), so the UI never composes copy and the copy is testable.

### Surfaces (`CaptureCenter` is the single funnel)

| Surface | Where | Destination | Feedback |
|---|---|---|---|
| Window / grid drop | `.dropDestination(for: URL.self)` on the detail pane (covers grid, empty state, error state) | user collection → **assign**; Inbox/All/tag → Inbox | dashed accent outline + “Add to ‹label›”, then banner |
| Collection row drop | `FileDropArea` (AppKit) behind each sidebar row | that collection (assign) | row `.onto` outline, then banner |
| Menu-bar pin | `NSStatusItem` + `StatusDropView` | always **Inbox** (ignores the window selection) | status title flash `+3` / `2 dup` / `!` for 1.8 s, then banner |
| ⌘V | local key monitor in `ContentView` | same rule as a window drop | banner |

The pin is a template SF Symbol (`tray.and.arrow.down`) — an AppKit system symbol, no Atlas
asset — with a transparent `FileDropNSView` pinned over the button: transparent so the symbol
*and* the flash title stay visible underneath, registered for `public.file-url` so a drag is
routed to it. Left click focuses the main window (`AppWindow.focusMain`), right click shows
Open / Quit so a windowless state is never a trap, and `willTerminate` removes the item.

### Duplicate UX

One `CaptureBanner` per batch, never an alert: auto-dismissed after 3.5 s, manually
dismissable, and a second drop replaces the first rather than stacking. Style is chosen from
the report — `success` (all new), `notice` (anything already in the library), `failure`
(per-file errors). The message is `CaptureReport.summary`, i.e. it names the count and the
destination instead of saying “import failed”. An **empty** batch (a folder with no media)
produces no banner at all, so dragging an empty folder is not reported as an error.

### Two deliberate deviations (documented, both one-line-revertible)

1. **Pasted bitmaps use `.copy`, not connected.** A screenshot on the pasteboard has no file,
   so bytes go to a scratch PNG and are imported with `.copy` (the brief's
   “connected-or-copy” branch). Connected here would key an item to a `$TMPDIR` path, which
   the OS purges — the thumbnail would break within days. The scratch file is deleted as soon
   as the library owns the bytes (asserted).
2. **The app still terminates when the last window closes.** A menu-bar pin normally implies
   an agent process that outlives its window; that would require solving SwiftUI `Window`
   scene *recreation* from AppKit (no `openWindow` outside a view), and a half-working version
   is worse than a documented limit. The pin therefore covers “window is open but behind other
   apps”, which is the real capture case. Revisit with the P2 agent-mode work.

### Verification

- `swift build --product AtlasOSSApp` — clean, **0 warnings**.
- `swift test` — **204 tests green**: 83 `AtlasCore` (swift-testing, 14 suites) + 121
  `AtlasOSSApp` (XCTest: **17 capture** + 24 appearance + 21 grid feel + 21 sidebar tree +
  14 model integration + 13 info/colour + 11 offscreen render). Every prior suite unchanged
  and passing.
- New coverage — core: connected default + `originals/` untouched, folder enumeration
  without a collection, re-drop → `updated`/“already in library”, two path spellings → one
  item, copy-mode content-hash duplicate, assign-vs-collection Inbox rule, unknown collection
  throws, bad/missing URLs reported, empty batch, summary copy, target flags. App: pasteboard
  file-URLs-beat-bitmap-preview, TIFF→PNG normalisation, text pasteboard not captured, scratch
  PNG write, destination routing (collection / Inbox / All / tag / dangling id), drop → model
  refresh + banner, second drop → `notice` banner + no duplicate rows, collection drop files
  out of the Inbox, menu-bar drop ignores the window selection, pasted bitmap stored as copy +
  scratch cleaned, text ⌘V falls through, banner dismiss, empty batch silent, flash tokens.
- **Status item verified at runtime**, not just compiled: launched the built binary and asked
  the accessibility server about the app's status bar —
  `tell application "System Events" to tell application process "AtlasOSSApp" to tell menu bar item 1 of menu bar 2 to return {AXDescription, AXPosition, AXSize}` →
  `AtlasOSS capture, 844, 4, 36, 24` (in the 24 pt menu-bar strip, one item). Quitting removed
  it. No crash, empty stderr log.
- `swift build` (all products, including `atlasoss`) still clean.

### Known gaps

- **Drag gesture itself is not automated.** The status item's existence/position is verified
  above; the *drop* still needs a human hand. 60-second manual pass:
  1. `./scripts/run-app.sh`, note the `tray.and.arrow.down` pin in the menu bar.
  2. Drag a folder of images from Finder onto the **pin** → title flashes `+N`, a banner says
     “Inbox: Imported N items”, Inbox badge rises by N. `originals/` stays empty (connected).
  3. Drag one of those same files onto the **grid** → notice banner “1 already in library”.
  4. Select a collection in the sidebar, drag a new file onto the grid → the file appears in
     that collection and **not** in the Inbox (assign rule).
  5. Drag a file from Finder onto a **collection row** → same as 4 (this is the AppKit
     background drop view; also confirm a normal row click still selects the row and that
     dragging an item tile onto a row still files it — the P1-B path).
  6. Copy an image (⇧⌃⌘4), press **⌘V** in the window → item appears, stored as `copy`.
  7. Click the pin → window comes forward. Right-click → Open / Quit.
- **No Notification Center feedback.** `UNUserNotificationCenter` needs a bundle identifier,
  which an SPM executable does not have, so the pin flashes its own title instead. A real
  `.app` bundle (P2 packaging) can swap this in without touching the capture path.
- **No entitlement or Info.plist needed** — `NSStatusItem`, `registerForDraggedTypes` and
  reading `NSPasteboard.general` on a user-initiated ⌘V require none. Nothing was added.
- Only `.fileURL` drags are accepted; promised/streamed drags (Photos, Mail attachments) are
  not virtualised into temp files yet.
- Dropping onto the **Tags** section still files to the Inbox; there is no “drop = tag”
  gesture (tags are a lens, not a home — see `CaptureRouting`).
- The window's drop highlight is a static dashed outline; no per-item preview stack (Atlas's
  stack preview was judged not cheap enough to be worth it in this slice).

## P1-D — Appearance tokens + searchable settings (landed)

Shipped **P1 plan dimension C**: Obsidian-style named design tokens, injected through the
SwiftUI environment, plus a VS Code-style searchable *Appearance* settings page that
applies live. P1-A grid feel, P1-B organisation and P1-C inspector are untouched
behaviourally — at the shipping defaults every token resolves to the exact literals it
replaced.

| Layer | Exemplar copied | Deliberately not copied |
|---|---|---|
| Token model | Obsidian CSS variables: named spacing / radius / background / selection / light-dark | user-authored CSS, theme marketplace |
| Settings UX | VS Code settings search (one page, search jumps to the control) | settings megamenu dump |
| Live apply | SwiftUI environment + `UserDefaults` write-through | themes that need a relaunch |

### Tokens (`AppearanceTokens`, App target)

| Token | Range | Default | Drives |
|---|---|---|---|
| `spacing` | 4…24 | **14** | grid gutter, grid content padding, cell caption gap, sidebar row height, inspector rhythm |
| `cornerRadius` | 0…20 | **8** | tile radius, sidebar row radius, inspector preview radius |
| `backgroundStyle` | `system` / `subtle` / `solid` | `system` | backdrop behind the grid (`system` = no fill, window untouched) |
| `colorScheme` | `system` / `light` / `dark` | `system` | `.preferredColorScheme` on every window |
| `selectionOpacity` | 0…0.6 | **0.14** | accent wash behind selected tiles and sidebar rows |

Derived tokens (so no view invents its own number): `contentPadding = spacing + 2`
(14 → 16), `innerRadius = cornerRadius − 3` (8 → 5), `largeRadius = cornerRadius + 2`
(8 → 10), `cellPadding = round(spacing/3)` (14 → 5), `thumbnailInset = cellPadding − 1`
(14 → 4), `sidebarRowHeight = 26 + (spacing − 14)/2` (14 → 26). Those six equalities are
asserted in `AppearanceTests.testDefaultTokensReproduceP1Chrome`, which is what makes the
claim “tokens are invisible until you move a slider” testable rather than aspirational.

- **Clamping is total.** `spacing`, `cornerRadius` and `selectionOpacity` clamp in *both*
the initialiser and a `didSet`, so a slider drag (`tokens.spacing = 999`), a restored
value and a hand-edited `UserDefaults` entry all land inside range. Non-finite input
(`NaN`, `±∞`) falls back to the token default instead of poisoning a layout pass.
- **`Equatable`** for change detection/tests; enums are `RawRepresentable` so they persist
  as strings.
- **Three backgrounds are three real colours.** `.windowBackgroundColor`,
  `.textBackgroundColor` and `.controlBackgroundColor` all resolve to the *same* white in
  light mode, so `solid` is `windowBackground.blended(0.08, of: black)` — a visibly
  distinct flat panel. A test asserts `subtle != solid`.

### Persistence & injection

- Keys `appearance.spacing`, `appearance.cornerRadius`, `appearance.backgroundStyle`,
  `appearance.colorScheme`, `appearance.selectionOpacity` in `UserDefaults.standard`
  (alongside the existing `grid.cellWidth` / `info.panelVisible`). Reads use
  `object(forKey:)`, not `double(forKey:)`, because `cornerRadius = 0` is legal and must
  not be mistaken for “absent”. Unknown enum strings and out-of-range numbers fall back to
  defaults (covered by tests).
- One `AppearanceStore` (`ObservableObject`) is a `@StateObject` in the `App`; it writes
  through on every change and injects `\EnvironmentValues.appearance` into the main window
  and the Settings scene. A Settings edit therefore re-renders the existing window in the
  same run loop: **no relaunch, no window recreation, no white flash** on a light/dark flip
  (the flip is a `.preferredColorScheme` change on the mounted tree).
- Views never take tokens as parameters — `ItemCell`, `ContentView`, `SidebarView`,
  `InfoPanelView`/`InfoPreview` read `@Environment(\.appearance)`, whose static default is
the shipping look, so offscreen renders, previews and `RenderSmokeTests` keep working
  without any setup.

### Consumers wired

- **Grid (`ContentView`)** — `LazyVGrid` spacing, `GridItem` spacing, content padding,
  `GridDensity.columns(spacing:padding:)` and `gridWidth(spacing:)` all take `tokens.spacing`,
  so the P1-A pointer anchor and the keyboard row maths stay exact after a change
  (`currentColumns` uses the same two values). Optional background fill behind the grid.
- **`ItemCell`** — tile radius, thumbnail inset, caption gap, selection wash
  (`tokens.selectionOpacity`); the accent ring keeps its 3 pt weight.
- **`SidebarView` / `SidebarRowLabel`** — row radius, selection wash and row height.
  Height and drop-zone hit-testing both read the same `rowHeight`, so P1-B
  before/onto/after dragging still resolves correctly at any density.
- **`InfoPanelView` / `InfoPreview`** — content padding, section rhythm and preview radius.
- **Density zoom stays independent**: `grid.cellWidth` (⌘-scroll / pinch) is unchanged and
  still owns tile size; it now simply picks up the token gutter.

### Settings scene

New files: `AppearanceSettingsView.swift` (UI), `AppearanceSettingsModel.swift` (pure
catalogue + search), `AppearanceTokens.swift` (tokens + store + environment key).

- `Settings { AppearanceSettingsView() }` gives the standard **AtlasOSS → Settings…** (⌘,),
  plus an explicit **“Appearance Settings… ” (⌥⌘,)** command registered through
  `@Environment(\.openSettings)` in case an SPM executable launched from a terminal does
  not get the app-menu plumbing.
- **Search** is a pure function over a data catalogue (`AppearanceSetting`): multi-word
  queries are AND-ed, each word matches any word of the title, aliases, section, summary
  or raw value, matching is case-insensitive, punctuation-tolerant and camelCase-splitting
  (`cornerRadius` ≡ `corner radius`). Typing `spacing` yields exactly the spacing row and
  `scrollTo` jumps to it; section headers with no hits disappear; a count badge and a
  “no settings match” state round it out.
- Controls: sliders for spacing / corner radius / selection opacity (clamped on write),
  segmented pickers for background and colour scheme, a **live preview strip** that uses
  the tokens (tile radius + gutter + selection wash + sidebar row), and **Reset to defaults**.

### Verification

- `swift build --product AtlasOSSApp` — clean, **0 warnings**; `swift build` (all products)
  also clean.
- `swift test` — **175 tests green**: 71 `AtlasCore` (swift-testing, 13 suites) + 104
  `AtlasOSSApp` (XCTest: **24 appearance** + 21 grid feel + 21 sidebar tree + 14 model
  integration + 13 info/colour + **11 offscreen render**). P0 and P1-A/B/C suites all still
  pass, unchanged.
- New coverage: clamp bounds + non-finite fallback, member-wise clamping, initialiser
  clamping, `Equatable`, derived-token defaults vs the P1-A/B/C literals, token-aware
  column/grid math, `UserDefaults` round-trip (including `radius = 0`), corrupt-value
  recovery, store write-through + reset, **a nested token mutation notifying observers**
  (the live-apply contract), environment default, and the search filter
  (empty/alias/case/punctuation/multi-word/no-match/section grouping/every row findable by
  its own title and raw value).
- Offscreen renders: the settings page at defaults and at token extremes, the preview strip
  at three densities, `ItemCell` with injected extreme tokens, and a **pixel-diff test**
  proving a token change actually changes what rasterises (the headless stand-in for “move
  the slider, grid updates”).
- Launch smoke: ran the built executable for 8 s — stayed up, no crash report logged.

### Known gaps

- **No UI automation** (same constraint as P1-A/B/C): sliders, pickers and the search field
  are covered by pure-function tests + offscreen renders, not synthetic clicks. A manual
  pass of “drag spacing → grid changes; type `spacing`; flip to dark” is still owed on an
  attached display.
- Only the tokens this slice needed: no typography, accent-colour or icon-size tokens yet,
  and no per-library/per-view token overrides (one global appearance).
- `SwatchStrip` chip radii and the lightbox chrome still carry small literals — they are
  cosmetic at token scale and were left alone to keep the diff honest.

## P1-C — Info panel + colour swatches (landed)

Shipped **P1 plan dimension E**: a digiKam-style right inspector with Atlas-like dominant
colour chips. P1-A grid feel and P1-B sidebar are untouched (only additive wiring in
`ContentView`).

### Colour extraction (`ColorProbe`, Core)

- `CGImageSourceCreateThumbnailAtIndex` downsamples to a **≤64 px edge first**, so a 50 MP
  HEIC costs about what a 64 px PNG does — no full decode on the main thread.
- Pixels are quantised into 5-bit-per-channel buckets (32³), then buckets are greedily
  merged farthest-first: a candidate survives only when it is ≥32 RGB-L2 away from every
  swatch already picked. A second pass relaxes the distance to 8 so a near-flat image still
  reports three shades instead of one lonely swatch.
- Output is `[Swatch]` — canonical uppercase `#RRGGBB` plus `weight` (share of sampled
  pixels), ordered by prominence. Videos, missing files, unreadable files and fully
  transparent images return `[]`.
- Matching distance is documented as **Euclidean RGB (0–255)**, default tolerance **40**
  (`ColorProbe.defaultTolerance`) — “same colour family, visibly different shade allowed”.

### Schema v3 (`AtlasSchema.currentVersion = 3`)

| change | detail |
|---|---|
| `item_colors` | `(item_id, rank, hex, weight)` PK `(item_id, rank)`; `rank 0` = most prominent; `ix_item_colors_hex` |
| `item_palette` | `(item_id PK, signature, extracted_at)` — the cache fingerprint |
| migration | additive and idempotent; v1 → v2 → v3 runs in one open, existing libraries keep every row, no palette is invented for legacy items |

`item_palette` exists separately from `item_colors` because a legitimately palette-less
item (a video, a transparent PNG) has **zero** colour rows — without a fingerprint row it
would be re-probed on every Info open.

The fingerprint is `contentHash | live file mtime (ms) | byteSize`. Using the *live* mtime
is what makes an in-place edit invalidate the cache without a re-import.

### AtlasCore API added

- `ColorProbe.swatches(for:maxColors:)`, `ColorProbe.distance(_:_:)`,
  `distance(betweenHex:andHex:)`, `hex(red:green:blue:)`, `normalizedHex(_:)`,
  `rgbComponents(fromHex:)`; `Swatch` (`hex` + `weight`)
- `dominantColors(for:refresh:)` — lazy extract + cache, `cachedColors(forItemID:)`,
  `cachedColors(forItemIDs:)`, `paletteSignature(for:)`, `hasCurrentPalette(for:)`
- `itemIDs(matchingColor:tolerance:)`, `items(matchingColor:tolerance:limit:)`
- `item(id:)`, `fileURL(for:)`, `collections(forItemIDs:)` (membership chips, one query
  pair), `items(itemIDs:)` (new optional filter on the standard query)
- `tags(forItemIDs:)` now sorts each item's tags by name, matching `tags(forItemID:)`

### App UI

New files: `ColorProbe` (Core), `AtlasLibrary+Colors` (Core), `InfoSummary` (pure),
`LibraryModel+Info` (bridge), `InfoPanelView`, `SwatchStrip`.

- **`I` toggles the inspector** (toolbar button too; visibility in `@AppStorage`
  `info.panelVisible`). The key is handled before the “grid engaged” guards so it also
  works with an empty view, but never while the lightbox is open and never while a text
  control owns the keyboard — `GridEventMonitor`'s stand-down rule is unchanged.
- **Pane** is a trailing `HStack` child (≥260 pt, 300 ideal, 380 max) instead of
  `.inspector`, so the grid keeps its single `GeometryReader` and the P1-A pointer-anchored
  zoom maths stay byte-identical.
- **Single selection:** preview (reuses `ThumbnailLoader` at 640 px), big-type `W×H`,
  human size · kind, file name, selectable path, imported/modified dates, storage mode,
  collection chips, tag chips, colour swatches. Chips navigate the sidebar;
  **clicking a swatch filters the grid**.
- **Multi selection:** “N items”, combined size, `Multiple` when dimensions differ,
  per-item tag/collection counts with **shared entries first** (`2/3` when partial),
  editable tags — the ✕ removes from every selected item, the `+` menu adds to every
  selected item through `setTags` — and *top colours across the selection*.
- **Colour aggregation choice:** a strict intersection is empty for two different photos,
  so per-item palettes are clustered (≤24 RGB-L2) and ranked by *how many selected items
  contain that shade*, then by pixel weight. Documented in `InfoComposition.swatches`.
- **Colour filter** layers on top of the sidebar query (`Color #AABBCC  n  ✕` chip on the
  detail header); clearing it re-runs the original query instead of resetting the sidebar.
  The empty state also offers “Clear color filter”.
- Palettes for the visible grid are warmed in the background (≤120 items, `Task.detached`,
  `utility`) so the filter never silently misses unprobed items and the panel opens without
  a decode stall.

### Verification

- `swift build --product AtlasOSSApp` — clean, 0 warnings (verified after `swift package clean`).
- `swift build` (all products) — clean, 0 warnings.
- `swift test` — **147 tests green**: 71 `AtlasCore` (13 suites) + 76 `AtlasOSSApp`
  (21 grid feel + 21 sidebar tree + 14 model integration + 13 info/colour + 7 offscreen
  render). P0 suites (connected/copy/layout/errors/schema) and P1-A/B suites all still pass.
- Live smoke on the real library (`~/Library/Application Support/AtlasOSS/default.atlaslibrary`):
  app launches, migrates to **schema v3**, `atlasoss info` still reports `copied items 0 /
  originals files 0` (P0 invariant), and the run wrote **11 `item_palette` rows / 53
  swatches** for the 11 real images (5 shades each).

### Known gaps

- Live *clicking* (swatch → filtered grid, ✕ on a tag chip) is covered by model-level tests
  and offscreen renders, not by UI automation — this session had no attached display, so
  the app was verified as “launches, migrates, prefetches, no crash report”.
- `I` was verified by code path + offscreen panel renders; no synthetic key injection.
- Palette extraction is single-threaded per view (bounded at 120 items); a full-library
  backfill belongs with the P1f thumbnail pipeline.
- Colour search only sees **cached** palettes by design; the CLI has no `colors` command yet
  (out of P1-C scope).

## P1-B — organization (landed)

Shipped **P1 plan dimension B**: nested collections with drag reorder, Inbox as the
default landing, tags with batch assign. Grid feel from P1-A is untouched.

### Schema v2 (`AtlasSchema.currentVersion = 2`)

Migration runs in place inside one transaction, then bumps `PRAGMA user_version`.

| change | detail |
|---|---|
| `collections.parent_id` | `TEXT NULL REFERENCES collections(id) ON DELETE SET NULL` |
| `collections.sort_order` | `REAL NOT NULL DEFAULT 0`, backfilled from `created_at` so migrated libraries get a stable, draggable order |
| name uniqueness | v1's global `UNIQUE(name)` is dropped and recreated **under the same index name** as `UNIQUE(COALESCE(parent_id,''), name)` — siblings under different parents may share a name, roots share the `''` sentinel, and v1 tooling still finds `ux_collections_name` |
| `tags` | `(id, name UNIQUE, created_at, color NULL)` |
| `item_tags` | `(tag_id, item_id, added_at)` PK `(tag_id, item_id)`, both FKs `ON DELETE CASCADE` |
| Inbox | seeded as a root collection with `sort_order = -1000`; id recorded in `library_meta.inbox_collection_id` (reserved name `Inbox` is the fallback, and an existing v1 collection called `Inbox` is **adopted**, not duplicated) |

Existing v1 libraries migrate in place. **Legacy items are deliberately not retro-filed
into the Inbox** — migration does not rewrite the user's filing decisions. The app
compensates: if the Inbox is empty while the library is not, it lands on *All Items*
instead of an empty grid.

### Inbox rule

Documented in `AtlasLibrary+Collections.swift` and covered by tests:

1. **Import captures** — `importFolder` links items to the Inbox *and* the folder collection.
2. **Filing clears it** — `assignItems(_:toCollection:)` (what a drop on a collection row
   does) adds membership and unlinks the item from the Inbox.
3. **Removal restores it** — removing an item from its last non-Inbox collection puts it
   back, so nothing disappears from the sidebar.
4. **The Inbox is inert** — no rename, no nesting under it, no reorder, no delete.
   Badge = Inbox membership count.

### AtlasCore API added

- Tree: `collectionTree(includingSystem:)`, `allCollections()`, `collection(id:)`,
  `inboxCollection()`, `inboxCollectionID()`, `inboxItemCount()`
- CRUD: `createCollection(name:parentID:)`, `renameCollection(id:name:)`,
  `moveCollection(id:newParentID:newSortOrder:)`, `reorderCollection(_:parentID:before:)`
  (drag-reorder primitive), `deleteCollection(id:)` — Inbox protected, children promoted to
  root and auto-suffixed when they would collide
- Membership: `addItems(_:toCollection:)`, `removeItems(_:fromCollection:)`,
  `assignItems(_:toCollection:)`, `itemCount(inCollection:)`, `items(collectionID:)`,
  `items(tagID:)`, `isInInbox(_:)`; `items(collectionName:)` kept for the CLI
- Tags: `tags()`, `tag(id:)`, `createTag(name:color:)` (idempotent on name),
  `renameTag`, `deleteTag`, `setTags(itemIDs:tagIDs:mode:)` with `.add/.remove/.replace`,
  `tags(forItemID:)`, `tags(forItemIDs:)`, `itemCount(tagID:)`
- `LibraryInfo` gained `tagCount` + `inboxItemCount`; `collectionCount` still counts user
  collections only (the system Inbox is reported separately), so P0 assertions hold

`AtlasLibrary.database` went from `private` to module-internal so the new
`+Collections` / `+Tags` extension files can share the connection. No other P0 behaviour
changed: `items(limit:mode:collectionName:)` is source-compatible, and connected import
still reports `copiedOriginals == 0`.

### App UI

New files `SidebarTree.swift` (pure), `SidebarView.swift`. Rewritten: `LibraryModel`,
`ContentView`'s sidebar (grid untouched apart from `.onDrag` on cells and a detail header).

- **Tree sidebar** — Inbox pinned at the top with its badge, then *All Items*, then a
  Collections section with disclosure chevrons and depth indentation, then Tags.
  Built from `ScrollView` + `LazyVStack` rather than `List`, because every row is both a
  drag source and a positional drop target and `List`'s `NSTableView` backing swallows both.
- **Drag reorder / nest** — a row is split into thirds: top 28 % = insert before,
  middle = nest inside, bottom 28 % = insert after. Dragging to the *Collections* header
  lifts a folder back to the top level; dropping right below the Inbox pins it to the top of
  the user section. Nesting into its own subtree, onto a tag, or onto itself resolves to
  `.none`.
- **Dropping items** — dragging from the grid carries the whole selection when the dragged
  cell is part of it (otherwise just that cell), in grid order. Dropping on a folder files
  the items (clears the Inbox); dropping on a tag adds the tag.
- **Chrome** — New Folder / New Subfolder / New Tag / Rename / Delete via the `+` buttons
  and per-row context menus, through a one-field sheet (`NameEntrySheet`).
- **Persistence** — order is `sort_order` in SQLite; reopening the library reproduces the
  sidebar exactly (verified in `LibraryModelTests`).
- `LibraryModel.open(at:)` is a test seam so the app layer can be driven against a
  throwaway `.atlaslibrary` instead of the user's real one.

### Verification

- `swift build --product AtlasOSSApp` — clean, 0 warnings (also verified for all products).
- `swift test` — **109 tests green**: 48 `AtlasCore` (9 suites) + 61 `AtlasOSSApp`
  (21 grid feel + 21 sidebar tree + 14 model integration + 5 offscreen render).
  P0 suites (connected/copy/layout/errors/schema) all still pass.
- Live CLI smoke against a throwaway v2 library: `import --mode connected` →
  `copied originals 0`, `info` reports `schema v2`, `collections 1`, Inbox holding 3 items.

### Known gaps

- **Interactive gestures are still not automated** (same constraint as P1-A): no screen
  recording / accessibility permission, so drag-reorder, nest-by-drag and the naming sheet
  are covered by pure drop-resolution tests + `LibraryModel` integration tests, not by
  synthetic gestures. A manual pass of drag-reorder, drag-nest, drop-onto-tag and the
  rename sheet is still owed.
- Drop **zone** highlighting only distinguishes "onto" (outline) from "before/after"
  (rule lines); SwiftUI's `dropDestination(isTargeted:)` does not report the pointer
  position, so the highlight is resolved on drop rather than live while dragging.
- Renaming a tag cannot clear its colour (`renameTag` keeps it; `color` is only set at
  creation). No colour picker yet.
- Collections nest to arbitrary depth and the tree renders all of it; there is no max-depth
  guard in the UI, and no "collapse all".
- Inbox and All Items show the same items right after an import (everything is unfiled at
  that point). That is the documented rule, not a bug, but it makes the two views look
  identical until you file something.
- `items(collectionID:)` is direct membership only — a parent does not aggregate its
  children's items in the grid (only `totalItemCount` rolls up).
