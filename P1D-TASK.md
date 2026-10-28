# P1-D Task — Appearance tokens + searchable settings

Repo: `~/devApple/atlas-oss`. Clean-room. See also `P1-REMAINING.md` dimension C.

## Goal
Central design tokens (Obsidian-style) + Appearance settings page with search (VS Code-style). Live apply to grid/sidebar/Info. No theme marketplace.

## Exemplars (binding)
| Layer | Copy from | Don't |
|---|---|---|
| Tokens | Obsidian CSS vars → spacing, radius, bg, selection, light/dark | user CSS, marketplace |
| Settings | VS Code settings search | megamenu dump |
| Apply | env injection / AppStorage | require relaunch |

## Allow
`Sources/AtlasOSSApp/**`, tests, `STATUS.md`. AtlasCore only if a tiny prefs-free helper is needed (prefer App-only).

## Forbid
P1e menu bar, P1f NSCollectionView rewrite, Canvas, decompile Atlas, outside-repo edits.

## Implement

### 1. `AppearanceTokens` (or `DesignTokens`)
- Named values persisted via `@AppStorage` / UserDefaults suite:
  - `spacing` (e.g. 4…24, default ~14) — grid gutter + cell padding scale
  - `cornerRadius` (0…20)
  - `backgroundStyle` enum: system / subtle / solid (map to NSColor/SwiftUI)
  - `colorScheme` override: system / light / dark
  - optional `selectionOpacity`
- Clamp helpers + `Equatable` for tests.
- Inject via `EnvironmentValues` so `ItemCell`, `ContentView` grid, `SidebarView`, `InfoPanelView` read tokens instead of hard-coded `14` / `8`.

### 2. Wire consumers
- Replace hard-coded spacing/corners in grid cells, LazyVGrid, selection ring radius, Info panel chrome where obvious.
- Density zoom (P1a `cellWidth`) stays independent but uses token spacing between cells.
- Appearance change must update UI without restart.

### 3. Settings scene
- `Settings { ... }` or dedicated Window: **Appearance** section.
- Controls for each token; live preview strip optional.
- **Search field** at top: filtering/scrolling to matching rows; typing `spacing` reveals the spacing control (test the filter pure function).
- Toolbar or menu **AtlasOSS → Settings…** standard.

### 4. Light/dark
- Prefer `.preferredColorScheme` from token; avoid white flash (no full window recreate if possible).

## Acceptance
1. `swift build --product AtlasOSSApp` clean
2. `swift test` all green — add token clamp + settings search filter tests; keep P1a–c suites
3. Manual: change spacing/corners → grid updates; search finds spacing; scheme flip OK
4. Update `STATUS.md` + short report

## Out of scope
Custom CSS themes, plugin contributes, menu bar pin, Nuke.
