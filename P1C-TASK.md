# P1-C Task — Info panel + color swatches

Repo: `~/devApple/atlas-oss`. Clean-room. Do **not** decompile Atlas.app.

## Goal
Ship **P1 plan dimension E** (Info / 色票): digiKam-style right inspector + Atlas-like dominant color chips. Keep P1-A grid and P1-B sidebar working.

## Current state
- Items already have width/height/byteSize/kind/paths/hash/dates; tags + collections APIs exist.
- No Info panel; no dominant-color extraction or color filter.
- Selection lives in `ItemSelection` + bottom bar in `ContentView`.

## Allow
- `Sources/AtlasCore/**` — optional schema v3 for cached colors; color probe API
- `Sources/AtlasOSSApp/**` — Info pane UI, key `I`, color filter into LibraryModel
- `Tests/**`, `STATUS.md`, `Package.swift` only if needed

## Forbid
- Appearance tokens (P1d), menu bar pin (P1e), NSCollectionView rewrite (P1f), Canvas
- Histogram/ICC full digiKam suite; cloud suggested tags
- Decompile Atlas; touch files outside repo; break P0 connected `copiedOriginals == 0`

---

## 1. Dominant colors (Core)

Implement a small, testable extractor (e.g. `ColorProbe` / `DominantColors`):

- Input: file URL (image); sample via ImageIO thumbnail or downsample (do **not** full-decode huge originals on main thread).
- Output: ≥3 hex colors (sRGB), ordered by weight/prominence. Video/other → empty array.
- Optional persistence: schema **v3** table `item_colors(item_id, rank, hex, weight)` OR columns/JSON — migrate idempotently. If caching, extract lazily on first Info open and store; re-extract if file mtime/hash changes.
- Public API examples: `dominantColors(for itemID:) async/throws -> [Swatch]`, `items(matchingColorHex:tolerance:)` (simple RGB distance is fine for P1c).
- Unit tests with PNG fixtures asserting ≥3 distinct-ish swatches and stable hex format `#RRGGBB`.

## 2. Info panel (App)

- Toggle with **`I`** (and a toolbar/button). Remember open/closed in `@AppStorage`.
- Right-hand inspector (NavigationSplitView inspector or trailing `HStack` pane ≥260pt).
- **Single selection**:
  - Large preview optional (reuse ThumbnailLoader larger size) OR skip if lightbox covers it
  - Big type: dimensions `W×H`, byte size (human), kind, file name
  - Path / location (selectable text)
  - Dates: imported / file modified if present
  - Collection chips (memberships) + Tag chips (clickable → select that sidebar filter if easy)
  - Color swatches ≥3; click a swatch → filter grid to items matching that color (tolerance documented, e.g. ΔE-ish or RGB L2)
- **Multi selection (≥2)**:
  - Show counts (“N items”)
  - Intersection of tags (editable: add/remove tag applies to all selected via existing `setTags`)
  - Shared dimensions only if all equal; otherwise “Multiple”
  - Union or average swatches — prefer **intersection of approximate colors** or “top colors across selection”; document choice
- Empty selection: short placeholder (“Select an item”)
- Esc still clears selection / closes lightbox first; don’t fight P1-A key monitor — coordinate with `GridEventMonitor` so `I` works when grid engaged and doesn’t break text fields.

## 3. LibraryModel / selection bridge

- Expose `infoTargetItems` from current selection (or focused item).
- Color filter as a sidebar-like filter mode or overlay chip on the detail header (“Color #AABBCC ✕”).
- Clearing color filter restores previous sidebar selection query.

## 4. Acceptance (you run; ghost 工头 re-runs)

1. `swift build --product AtlasOSSApp` clean
2. `swift test` all green (Core + App); add Info/color tests
3. Live app opens; `I` toggles pane; single-select shows meta + ≥3 swatches; click swatch filters; multi-select shows intersection tags
4. Update `STATUS.md` + short report (files, verify, gaps)

## Out of scope
Full ICC/histogram, semantic search, Appearance settings page, menu bar drop.

## Style
Swift 5 language mode; small files (`InfoPanelView`, `ColorProbe`, …); no Atlas branding assets.
