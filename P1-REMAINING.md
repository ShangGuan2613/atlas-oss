# P1 Remaining — self-driven schedule (ghost 工头)

Owner plans, picks exemplars per layer, drives Pi, verifies personally. No more go/no-go cards unless a principle changes.

## Done
| Slice | Exemplar axis | Status |
|---|---|---|
| P1a grid feel | Immich + Eagle layouts + PureRef anchor | landed |
| P1b organization | Atlas IA + Eagle tags + Are.na Inbox | landed |
| P1c Info + swatches | digiKam inspector + Atlas 1.7 palette | landed |

## Order (locked for remaining)
**P1d → P1e → P1f** then stop for P1 gate review (Canvas/Infinity stay Later unless metrics demand earlier).

Rationale: appearance tokens unlock consistent density/chrome before capture surfaces multiply entry points; capture needs stable UI chrome; perf rewrite (NSCollectionView / disk thumbs) is highest risk — do last with a loaded library.

---

## P1d — Appearance tokens (dimension C)

| Layer | Exemplar | Copy | Don't copy |
|---|---|---|---|
| Token model | Obsidian CSS variables | spacing / radius / bg / selection / light-dark as named tokens | theme marketplace; user CSS as v1 |
| Settings UX | VS Code Settings search + Atlas searchable settings | one Appearance page; search jumps to control | full settings megamenu |
| Live apply | SwiftUI environment / AppStorage | change spacing/corners → grid updates immediately; no flash on appearance flip | restart-required themes |

**Exit:** `@AppStorage` (or equivalent) for spacing, corner radius, background mode, accent/selection; Settings window/scene with search hitting “spacing”; light/dark switch without white flash (assume &lt;100ms); grid + sidebar + Info consume tokens; tests for token clamp + persistence; `STATUS.md` update.

## P1e — Capture UX (dimension D)

| Layer | Exemplar | Copy | Don't copy |
|---|---|---|---|
| Drop targets | Atlas menu-bar pin + macOS Services | window / sidebar / status item all accept files → Inbox (or hovered collection) | browser extension (Later) |
| Status item | BCStatusItem / droplet patterns | drag onto menu bar icon → Inbox; stack preview + count if cheap | full Share Extension App Store flow |
| Paste | Finder paste semantics | ⌘V file/image URLs into window → import connected by default | X/IG special paste policies |

**Exit:** drag files onto main window & collection rows (extend P1b); menu bar extra (`NSStatusItem`) drop→Inbox &lt;500ms visible (hypothesis→measure); duplicate import messaging; connected mode default for drops; tests for import-from-URLs helper; no schema break.

## P1f — Perf floor (dimension F)

| Layer | Exemplar | Copy | Don't copy |
|---|---|---|---|
| Grid host | NSCollectionView + Diffable (DigitalBlake macOS note) | cell reuse; stable IDs | pure LazyVGrid for 10k+ |
| Thumb pipeline | Nuke ideas + PhotoPrism size ladder + digiKam thread sense | disk thumbnails under `thumbnails/`; async decode; LRU; viewport-only full decode | IntersectionObserver port; main-thread ImageIO of originals |
| Measure | Instruments-style honesty | seed ≥1k items (or synthetic); report scroll frame p95 / memory; replace assumptions | vanity FPS without method |

**Exit:** disk thumb generation API + on-demand fill; grid either bridged NSCollectionView **or** documented interim LazyVGrid + disk thumbs with measured numbers; `swift test` green; bench note in `STATUS.md`; if NSCollectionView slips, land disk+ladder first and file follow-up — still must beat baseline decode-in-cell.

## Hard rules (unchanged)
Clean-room; no Atlas decompile/assets; Pi + grok on this Mac; ghost 工头 re-runs build/test; principle changes only from user.

## After P1
Stop and report P1 gate: checklist vs Atlas public grid-library parity. Canvas / Infinity / browser ext / semantic search → P2+ unless user expands scope.
