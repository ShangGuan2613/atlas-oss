# AtlasOSS ↔ Atlas public parity (clean-room)

Sources: [atlasformac.com](https://atlasformac.com/), [release-notes](https://atlasformac.com/release-notes) (through **1.8.2 / 26 Oct 2026**), guides, switch-from-eagle. No decompile / no Atlas assets.

Status vs shipped atlas-oss (2026-10-28). Assumptions marked.

## Capability matrix

| Atlas capability | atlas-oss | Notes / exemplar for gap |
|---|---|---|
| Local-first library | **Have** | — |
| Copy-import | **Have** | — |
| Connected import (index in place, 0 bytes into originals) | **Have** | digiKam |
| Connected folder *live watch* (FSEvents → refresh) | **Missing** | digiKam / Photos |
| Nested collections + reorder | **Have** | — |
| Inbox + menu-bar pin | **Have** | — |
| Tags | **Have** | Eagle IA polish |
| Tag folders | **Missing** | Eagle |
| Sidebar folders / multi-select rows | **Partial** | Nested Have; Atlas Folders section may differ |
| Grid + density zoom | **Have** | Immich / Finder |
| Multi-select + Space lightbox | **Have** | — |
| Waterfall / justified layouts | **Missing** | Immich / Eagle |
| Canvas | **Have (P2-A)** | Free placement, pan/zoom, persisted board (`item_positions`), viewport culling, Reset Layout. Exemplars: PureRef nav + tldraw cull |
| Infinity | **Missing** | **P2b** — unbounded camera over the same `item_positions` rows; Are.na + PureRef |
| Preserve view mode across collections | **Partial** | Grid\|Canvas persists across launches and survives collection switches (one global mode); per-collection memory still Missing |
| Info panel + colour swatches | **Have** | — |
| Colors folder / eyedropper / hex search UI | **Missing** | Eagle (probe API Exists) |
| Camera EXIF / author / location | **Missing** | digiKam |
| Item notes + rich Notes | **Missing** | Obsidian |
| Appearance + searchable Settings | **Have** | — |
| Browser extensions | **Missing** | Eagle / Raindrop |
| Links + snapshots | **Missing** | Are.na / Raindrop |
| Video/GIF hover scrub | **Missing** | Photos / QL |
| Crop + rotate (non-destructive) | **Missing** | Photos |
| Like / Likes | **Missing** | Photos favorites |
| Trash / Put Back | **Partial** | Delete exists; polish TBD |
| Undo/Redo | **Missing** | Finder / Photos |
| ⌘K palette + ⌘F search | **Missing** | Raycast / VS Code / Eagle |
| Semantic / CLIP + find similar | **Missing** | Immich |
| Suggested tags | **Missing** | Immich |
| Smart folders | **Missing** | Finder Smart Folders |
| Random / shuffle | **Missing** | — |
| Sort + scroll memory | **Partial** | — |
| Custom shortcuts | **Missing** | Obsidian keymap |
| Multi-library switcher | **Partial** | Path known |
| Eagle connect / import | **Missing** | digiKam wizards |
| Duplicate cleanup / virtual copies | **Missing** | digiKam |
| Rename / Export | **Missing** | Finder |
| MCP + deep CLI | **Partial** | `atlasoss` import/list only |
| Disk thumb ladder + LRU | **Have** | Beat on measured p95 |
| SVG/PDF/RAW/AI preview matrix | **Partial** | — |
| iOS companion | **Missing** | Atlas Fall '26; later |
| Localization | **Missing** | — |
| Licensing / trial | **Out of scope** | Business |

## Run order (self-driven)

| Slice | Goal | Exemplar | Exit |
|---|---|---|---|
| ~~Stability sidebar~~ | Done 2026-10-28 | Finder | click lower→upper works |
| ~~P2a Canvas~~ | **Done 2026-10-28** — free layout, pan/zoom, persisted positions, culling | PureRef + tldraw | quit/reopen positions identical (verified, 220 items); build+test green |
| **P2b Infinity** | Edgeless camera on same spatial data | Are.na + PureRef | 500 items no hard clip |
| **P2c ⌘K + search** | Palette + name/tag/note | Raycast / Eagle | warm open; 1k filter snappy |
| **P2d Like / Trash / Undo** | Likes, Trash+Put Back, ⌘Z | Photos + Finder | 10 undo steps; confirm permanent |
| **P2e Waterfall** | Masonry toggle | Immich / Eagle | keep selection; scroll budget |
| **P2f Links** | URL items + paste | Are.na | paste https → Inbox card |
| **P2g Connected watch** | FSEvents refresh | digiKam | add 100 files → &lt;2s |
| **P2h Video/GIF** | Hover scrub | Photos | memory bounded |
| **P2i Crop/rotate** | Non-destructive | Photos | original bytes intact |
| **P2j Smart folders** | Rules | Finder | live count |
| **P2k Notes** | Item + rich | Obsidian | searchable via P2c |
| **P2l Colors UI** | Section + eyedropper | Eagle | paste hex → filter |
| **P2m Browser ext** | Save → Inbox | Eagle ext | &lt;3s local round-trip |
| **P2n Semantic** | On-device embed | Immich CLIP | nothing leaves machine |
| **P2o Multi-lib + Eagle import** | New/Open; Eagle adapter | digiKam | idempotent |
| **P2p Shortcuts + Random** | Remap; `R` | Obsidian | conflict detect |
| **P2q MCP/CLI** | Agent tools | public MCP | write via Trash |
| **P2r Perf** | Beat P1f under new views | PhotoPrism | published benches |

Bugfixes interrupt anytime. Principle scope (what to ship) = user; params = ghost.

## Clean-room forbid
Decompile Atlas; copy assets/pixels/IDs; claim Atlas-compatible binary; Atlas branding in UI.

## Allowed
Public marketing/RN as capability lists; mechanisms from Eagle, PureRef, Are.na, Immich, digiKam, Obsidian, Photos/Finder; own measurements.
