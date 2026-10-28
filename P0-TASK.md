# P0 Task for Pi / Grok Build

Implement P0 for atlas-oss in this repo. Follow AGENTS.md.

## Deliverables
1. Swift Package (macOS) named `AtlasOSS` (or `AtlasCore`) with:
   - Library module for data layer
   - Executable CLI `atlasoss` for import/list/info
2. On-disk library under a chosen path (default `~/Library/Application Support/AtlasOSS/default.atlaslibrary/` package-style folder):
   - `library.sqlite`
   - `originals/` (only when copying mode)
   - `thumbnails/` (optional in P0; can defer generation stubs)
3. Import API:
   - `importFolder(path, mode: .copy | .connected)` 
   - connected mode: index files in place, **copy count of originals must be 0**
   - copy mode: copy into originals/ with content-hash dedupe
4. Schema: items (id UUID, kind, path or stored name, width/height if cheap, contentHash, dates), collections (id, name, dates)
5. Tests or CLI verification script that:
   - creates temp library
   - imports a small fixture folder of 3–5 PNGs in connected mode
   - asserts zero files under originals/
   - lists items count >= fixture count
6. README with build/run commands

## Acceptance commands (you must run and paste output)
```
swift build
swift test   # or ./scripts/verify-p0.sh
```

## Constraints
- No decompile of /Applications/Atlas.app
- No Electron/Tauri
- Keep P0 small; no SwiftUI app target required yet (add empty App stub only if trivial)
- Prefer Foundation + SQLite (SQLite.swift or raw SQLite3)
