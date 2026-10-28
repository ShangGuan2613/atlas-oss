# atlas-oss — clean-room open-source visual library (Mac native)

## Goal
Build a higher-performance, deeply customizable **open-source** local-first visual inspiration library for macOS (Swift/SwiftUI). Category peer: Atlas for Mac. **Clean-room**: do not decompile Atlas binaries; do not copy Atlas assets/branding/proprietary code.

## Stack
- Mac native: Swift 6 + SwiftUI + SQLite
- Tools: prefer local `pi` and `grok` (Grok Build) for implementation
- Repo root: `~/devApple/atlas-oss`

## Benchmarks (copy / don't copy)
| Dim | Exemplar | Copy | Don't copy |
|---|---|---|---|
| Data | Immich asset split (sans server) + Eagle `.library` import only | asset/file/library separation; external library zero-copy | Immich Docker/Postgres |
| Grid | TanStack Virtual + PhotoPrism thumb sizes + digiKam thread pipeline | viewport virtualization; disk thumb cache | decode inside cell render |
| Canvas | tldraw culling/LOD | spatial culling, stepped LOD | Excalidraw full-scene O(N) each frame |
| Ingress | Are.na capture semantics + MCP tools | Inbox + hash dedupe | — |
| Theme/plugins | Obsidian CSS tokens + VS Code contributes (lite) | design tokens; declarative contrib | fragile DOM hacks |
| Search (opt) | Immich small CLIP metrics; on-device | optional, off by default | multi-GB default model |

## P0 acceptance (must verify with commands, not self-report)
1. Package/layout: SPM (and Xcode app target when Xcode available) under this repo
2. On-disk library format: `library.sqlite` + `originals/` + `thumbnails/` (+ optional JSON export)
3. Import a folder of images; **connected folder mode copies 0 originals**
4. Index ≥ sample set; CLI or unit test lists collections/items
5. Document measured cold-open TTFI on this machine (replace assumptions)

## Forbidden
- Decompile `/Applications/Atlas.app`
- Copy SeasonMix/Atlas icons/marketing copy as product identity
- Force-push, delete user libraries outside this repo
- Scope creep into P1–P5 without passing P0 gates

## Next phases (do not start until P0 green)
P1 virtualized grid + thumb pipeline → P2 canvas → P3 capture/CLI/MCP → P4 plugins → P5 semantic search
