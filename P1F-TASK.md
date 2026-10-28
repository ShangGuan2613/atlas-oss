# P1-F Task — Perf floor (disk thumbs + viewport discipline)

Repo: `~/devApple/atlas-oss`. Clean-room. See `P1-REMAINING.md` dimension F.

## Goal
Stop decoding originals on the hot path. Exemplars: PhotoPrism size ladder + digiKam thread sense + Nuke-style async/LRU; prefer **NSCollectionView + Diffable** if it fits this slice, else land disk thumbs + measured LazyVGrid and document the NSCollectionView follow-up honestly.

## Exemplars (binding)
| Layer | Copy | Don't |
|---|---|---|
| Grid host | NSCollectionView + Diffable (macOS) | pure LazyVGrid for 10k as end state |
| Thumbs | disk under `thumbnails/`; size ladder; LRU; no main-thread original decode | IntersectionObserver port |
| Measure | seed ≥1k (or synthetic) and report method + numbers | vanity FPS |

## Allow
`Sources/AtlasCore/**` (thumb store API), `Sources/AtlasOSSApp/**`, tests, bench script under `scripts/`, `STATUS.md`.

## Forbid
Canvas, browser ext, decompile Atlas, new heavy deps unless justified (prefer ImageIO; Nuke only if SPM cost is accepted — **default: no Nuke**, reimplement minimal ladder+LRU).

## Implement (priority order — ship 1–3 even if 4 slips)

### 1. Disk thumbnail store (Core)
- Paths already have `thumbnails/` — write JPEG/HEIC thumbs named by content hash + maxPixel bucket (e.g. 180/360/540).
- API: `thumbnailURL(for:item:maxPixel:)` / `ensureThumbnail(for:maxPixel:) throws` — generate once, reuse.
- Generation off caller’s main actor; ImageIO thumbnail creation.
- Tests: ensure creates file; second call does not rewrite if fingerprint matches; connected items work from source path.

### 2. App loader
- `ThumbnailLoader` reads disk thumb first; on miss, request ensure then load; memory LRU kept.
- Density → bucket mapping already exists — wire to disk buckets.
- **Never** pass original URL into cell decode when a thumb exists.

### 3. Measurement
- Script or test harness: build/open library with ≥200 images if available, else generate N solid-color PNGs into a temp library and import connected/copy.
- Report in `STATUS.md`: method, item count, rough scroll observation or frame counter if available; replace “assume &lt;16ms” with measured notes (honest gaps OK).

### 4. Grid host (stretch)
- If time: bridge `NSCollectionView` with diffable data source for the main grid, keep SwiftUI chrome around it.
- If not: leave LazyVGrid but with disk thumbs; explicitly list NSCollectionView as P1.5/P2 follow-up in STATUS — **do not claim F fully closed without either NSCollectionView or measured proof LazyVGrid+disk is acceptable on 1k**.

## Acceptance
1. `swift build --product AtlasOSSApp` clean
2. `swift test` all green
3. After browsing a library, `thumbnails/` contains files for viewed items
4. `STATUS.md` with numbers/method + residual risks
5. Short report

## Out of scope
Info/Appearance/Capture regressions; semantic search; Canvas.
