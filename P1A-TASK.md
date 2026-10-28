# P1-A Task — Grid feel (density + multi-select + lightbox + keyboard)

Repo: `~/devApple/atlas-oss`. Clean-room: do **not** decompile Atlas.app; do not copy Atlas assets/branding.

## Goal
Turn the minimal LazyVGrid viewer into a usable daily grid matching **P1 plan dimension A** (Immich keyboard/lightbox semantics + PureRef-style pointer-anchored density).

## Allow
- `Sources/AtlasOSSApp/**` (primary)
- Small helpers under AtlasOSSApp only
- `Tests/**` if you add pure-logic unit tests (selection math, density clamp)
- `STATUS.md`, this task file notes
- `scripts/run-app.sh` only if launch needs a flag

## Forbid
- AtlasCore schema/API changes unless truly required (prefer UI-only)
- Canvas / Infinity / Inbox / Tags / Info panel / menu bar pin / Appearance settings (later slices)
- New SPM dependencies for this slice (no Nuke yet — keep ThumbnailLoader)
- Decompile Atlas; force-push; touch files outside this repo

## Implement (must ship)

### 1. Density zoom (pointer-anchored)
- Replace fixed `GridItem(.adaptive(minimum: 190…))` with a `@AppStorage` / `@State` density (e.g. cell target width 80…360, default ~200).
- ⌘ + scroll (or trackpad magnify) changes density continuously; clamp to range.
- **Pointer anchor**: when density changes, keep the item under the cursor (or center of viewport if unknown) visually stable — at minimum preserve approximate scroll offset relative to that item’s id (document the approach in a short comment).
- Persist density across launches (`@AppStorage("grid.cellWidth")` or equivalent).

### 2. Selection
- Single click = select one; ⌘-click toggle; ⇧-click range when possible (ordered by current `items` array).
- Selected cells show a clear ring / overlay (system accent).
- Esc clears selection (when lightbox closed).
- Keep `Set<LibraryItem.ID>` (or stable id) on `LibraryModel` or a focused selection store.

### 3. Keyboard
- Arrow keys move the focused/selected item in the grid (compute columns from current width + cellWidth + spacing).
- ⌘A select all in current view (optional but preferred).
- Focus must work when the grid is key (`.focusable` / onKeyPress / NSEvent monitor — pick the reliable macOS SwiftUI path).

### 4. Lightbox / Quick Look
- Space (or double-click) opens a full-window overlay for the focused/selected item showing a larger preview (decode larger maxPixelSize, e.g. 1600).
- Left/Right in lightbox move among `items` (wrap or stop at ends — stop is fine).
- Esc or Space closes lightbox.
- **Must restore scroll position** of the underlying grid after close (capture before open; restore after).

### 5. Multi-select chrome
- When `selection.count >= 2`, show a thin bottom bar: `"N selected"` + Clear button. No batch actions yet.

## Acceptance (verify yourself with commands)
1. `swift build --product AtlasOSSApp` succeeds
2. `swift test` still green (do not break AtlasCoreTests)
3. Launch `./scripts/run-app.sh` (or equivalent); manually confirm or script what you can:
   - density changes with ⌘-scroll / magnify and persists after relaunch
   - click / ⌘-click / ⇧-click selection works; Esc clears
   - arrows move selection; Space opens/closes lightbox; close restores scroll
4. Update `STATUS.md` with what landed + any known gaps
5. Print a short report: files changed, how to verify, residual risks

## Out of scope this run
P1b Inbox/tags, P1c Info, P1d Appearance tokens, P1e menu bar drop, NSCollectionView rewrite (P1f later — keep LazyVGrid but wire density to ThumbnailLoader `maxPixelSize` steps if easy: e.g. cellWidth→maxPixel ≈ 1.5×).

## Style
- Swift 5 language mode as in Package.swift
- Prefer small, readable files; extract `GridDensity`, `ItemSelection`, `LightboxView` if ContentView grows
- No AI slop comments; one sentence only where algorithm is non-obvious (anchor scroll)

---

## Run notes (2026-10-27)

Landed as specified. Two implementation choices worth recording:

- **Scroll offset** — SwiftUI on macOS 14 exposes no scroll-position API, so `ScrollOffsetBridge`
  reaches the enclosing `NSScrollView` and drives `bounds.origin.y`. Used for both pointer anchoring
  and lightbox scroll restore; verified to attach at runtime (`docH 1614`).
- **Keyboard** — `onKeyPress` only fires for a focused view and fights the sidebar list, so the grid
  uses a local `NSEvent` monitor (also the only way to intercept ⌘-scroll) that yields while an
  `NSTableView`/`NSTextView` is first responder.

Tests: `Tests/AtlasOSSAppTests/` (21 logic + 3 offscreen render). See `STATUS.md` for gaps.
