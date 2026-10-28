# AtlasOSS

Clean-room, local-first visual inspiration library for macOS.

**Current (2026-10-28):** P0–P1 gate closed; P2-A Canvas (schema v4 + AppKit `CALayer` native board) landed. Infinity / further parity paused. See `STATUS.md` and `ATLAS-PARITY.md`.

No decompilation of any proprietary app, no Electron/Tauri, no third-party runtime dependencies —
Foundation, SQLite (via the SDK's `sqlite3`), CryptoKit and ImageIO only.

---

## What P0 delivers

| Deliverable | Status |
|---|---|
| Swift package with a library module (`AtlasCore`) | ✅ |
| Executable CLI (`atlasoss`) for import / list / info | ✅ |
| On-disk `*.atlaslibrary` package (`library.sqlite`, `originals/`, `thumbnails/`) | ✅ |
| `importFolder(path, mode: .copy \| .connected)` | ✅ |
| Connected mode writes **zero** originals | ✅ verified on disk |
| Copy mode with SHA-256 content-hash dedupe | ✅ |
| Schema: `items`, `collections`, `collection_items`, `library_meta` | ✅ |
| Tests + end-to-end CLI verification script | ✅ 21 tests, 21 assertions |
| Measured cold-open TTFI | ✅ ~0.43 ms median |

Deliberately **out of scope** for P0 (see `AGENTS.md` next phases): SwiftUI app target, virtualized
grid, thumbnail generation, canvas, plugins, semantic search.

---

## Build & run

Requires macOS 14+ and Swift 6.x (verified with Swift 6.4 / Xcode 27.1 on macOS 27.0.1).

```bash
# build the library + CLI
swift build

# run the test suite (21 tests)
swift test

# full end-to-end acceptance run against the real CLI binary
./scripts/verify-p0.sh
```

The binary lands at `.build/out/Products/Debug/atlasoss` (use
`swift build --show-bin-path` to resolve it portably).

### CLI usage

```bash
BIN="$(swift build --show-bin-path)/atlasoss"

# create / open a library (defaults to ~/Library/Application Support/AtlasOSS/default.atlaslibrary)
"$BIN" init

# CONNECTED import: index files in place, copy 0 originals
"$BIN" import ~/Pictures/inspiration --mode connected --collection inspiration

# COPY import: copy into originals/, deduped by content hash
"$BIN" import ~/Pictures/inspiration --mode copy

# inspect
"$BIN" list
"$BIN" list --limit 10 --mode connected
"$BIN" collections
"$BIN" info
"$BIN" bench --iterations 7          # cold-open TTFI
```

Every command accepts `--json` for machine-readable output, and `--library <path>` to target a
specific library package:

```bash
"$BIN" --library /tmp/scratch.atlaslibrary --json import ./fixtures --mode connected
```

Exit codes: `0` success, `1` runtime error, `2` usage error.

---

## On-disk library format

A library is a single package-style folder, extension `.atlaslibrary`:

```
default.atlaslibrary/
├── library.sqlite     # items, collections, metadata (WAL: + -wal / -shm)
├── originals/         # ONLY populated by .copy imports; empty for connected-only libraries
└── thumbnails/        # reserved for the P1 thumbnail pipeline
```

- `originals/` and `thumbnails/` are created when the library is created so the layout is
  predictable, but connected imports never write a single byte into `originals/`.
  The acceptance test asserts `find originals/ -type f | wc -l == 0` **and** `du -sk originals/ == 0`.
- Copy-mode stored names are content-addressed: `originals/<sha256>.<ext>`.
- SQLite runs in WAL mode with `synchronous=NORMAL` and `foreign_keys=ON`.

### Schema (v1, `PRAGMA user_version = 1`)

```sql
items (
  id TEXT PRIMARY KEY,              -- UUID
  kind TEXT,                        -- image | video | other
  mode TEXT,                        -- copy | connected
  file_name TEXT,                   -- display name
  source_path TEXT,                 -- absolute path      (connected only)
  stored_name TEXT,                 -- originals/-relative (copy only)
  width INTEGER, height INTEGER,    -- from ImageIO headers, no full decode
  byte_size INTEGER,
  content_hash TEXT,                -- SHA-256 hex
  imported_at REAL, file_created_at REAL, file_modified_at REAL
)

collections (id TEXT PRIMARY KEY, name TEXT UNIQUE, created_at REAL, updated_at REAL)
collection_items (collection_id, item_id, added_at)   -- many-to-many
library_meta (key TEXT PRIMARY KEY, value TEXT)        -- library_id, created_at
```

Identity is mode-aware, enforced by two partial unique indexes:

- `ux_items_connected_path` on `source_path WHERE mode='connected'` — re-importing the same folder
  updates rows instead of duplicating them.
- `ux_items_copy_hash` on `(kind, content_hash) WHERE mode='copy'` — identical bytes are stored and
  indexed exactly once, whatever their file names.

---

## Measured performance (this machine)

Apple M2, macOS 27.0.1, Swift 6.4, debug build (`swift build`), 4-item library.
These replace the P0 assumption from `AGENTS.md` ("document measured cold-open TTFI").

| Metric | Value |
|---|---|
| Clean build (`swift build`, empty scratch path) | **7.85 s** |
| Incremental build | ~0.3 s |
| Open library + fetch first item (median, n=7, 3 runs) | **0.38 – 0.43 ms** |
| … min / p95 / max | 0.32 / 0.49 / 0.52 ms |
| Process entry → first item (in-process) | **3.8 – 3.9 ms** |
| Full CLI process (`atlasoss list`), avg of 10 | **~7 – 8 ms** |
| Import 4 PNGs, connected (hash + probe + insert) | 7.6 ms |
| Import 4 PNGs, copy (incl. 4 file copies) | 6.8 ms |
| Re-import 4 PNGs, copy (hash dedupe, 0 copies) | 7.3 ms |

Takeaways: the data layer is nowhere near the bottleneck at P0 scale — SQLite open + first query
is sub-millisecond, and whole-process CLI latency is dominated by process launch (~4–8 ms), not I/O.
That leaves the entire budget for the P1 grid/thumbnail pipeline.

> Note: hash-only (no pixel decode) imports are I/O bound, so `importFolder` stays linear in bytes
> read. A 10k-file folder is a good P1 benchmark target.

---

## Repository layout

```
Package.swift
Sources/
  AtlasCore/                 # data layer (library module)
    AtlasLibrary.swift       #   open/close, importFolder, queries, info
    AtlasSchema.swift        #   versioned migrations (v1)
    Models.swift             #   ImportMode, MediaKind, LibraryItem, ImportReport, LibraryInfo
    LibraryPaths.swift       #   package layout, default paths, dir stats, path canonicalisation
    SQLiteDatabase.swift     #   thin, dependency-free sqlite3 wrapper
    ContentHasher.swift      #   streaming SHA-256 + ImageIO dimension probe
    AtlasError.swift
    AtlasVersion.swift
  atlasoss/main.swift        # CLI: init / import / list / collections / info / bench
Tests/AtlasCoreTests/
  AtlasCoreTests.swift       # 21 Swift Testing cases across 5 suites
  Fixtures.swift             # fixture writer + throwaway temp workspaces
  PNGFixtureData.swift       # generated base64 PNG fixtures
scripts/
  verify-p0.sh               # end-to-end CLI acceptance (21 assertions)
  fixtures.swift             # deterministic PNG generator (write | emit-swift)
```

No binary fixtures are committed: PNGs are deterministic and regenerable, either embedded as
base64 (`PNGFixtureData.swift`) or written on the fly by `scripts/fixtures.swift`.

### Regenerating fixtures

```bash
swift scripts/fixtures.swift write /tmp/fixtures
swift scripts/fixtures.swift emit-swift Tests/AtlasCoreTests/PNGFixtureData.swift
```

---

## Verification details

`./scripts/verify-p0.sh` drives the real binary and asserts:

1. package builds and the `atlasoss` binary exists;
2. a fixture folder of 4 PNGs is generated (64×48, 80×60, 100×75, 120×90);
3. `init` creates `library.sqlite` + `originals/` + `thumbnails/`;
4. connected import reports `copiedOriginals == 0`, `imported == 4`, `mode == "connected"`;
5. **zero files** and **zero KiB** under `originals/`, and the source fixtures are untouched;
6. `list` and `info` report at least the fixture count;
7. copy import reports `copiedOriginals == 4` and writes exactly 4 originals;
8. re-importing in copy mode reports `copiedOriginals == 0` and `duplicates == 4`;
9. cold-open TTFI is measured.

It exits non-zero if any assertion fails, and leaves the scratch workspace behind for inspection
(it never deletes anything outside its own `mktemp` directory).

`swift test` covers the same gates at the API level plus edge cases: idempotent re-import,
path-spelling canonicalisation, duplicate content under different names, restoring a
deleted stored original, unsupported file types, empty folders, missing folders, and schema
object/column presence.

---

## Design notes / known P0 limits

- **Single connection, synchronous API.** No pooling or actor isolation yet; the CLI is
  single-threaded. P1's UI will need a read pool plus a serialized writer.
- **Swift language mode 5** on all targets (`swiftLanguageMode(.v5)`) to keep the P0 build
  frictionless; migrating to Swift 6 strict concurrency is a P1 task.
- **Video dimensions are not probed** (needs AVFoundation); videos are indexed with `NULL`
  width/height. Images use ImageIO header parsing — cheap, no pixel decode.
- **Thumbnails are not generated.** `thumbnails/` exists and is counted, but stays empty.
- **Copy-mode identity is content hash**, so two *different* files with identical bytes collapse
  into one item. Connected-mode identity is the canonical absolute path, so the same content at
  two locations stays two items — that mirrors the semantics of each mode.
- **No deletion/reconciliation pass** yet: if a connected file moves or is deleted, its row goes
  stale until re-import or a future scan.
- Importers hold the SQLite write transaction while copying files. Fine for P0 folder sizes;
  large imports should copy outside the transaction in P1.

## License / provenance

Clean-room implementation. No code, assets, icons or marketing copy from any proprietary
application. Peer products listed in `AGENTS.md` are referenced for architecture benchmarks only.
