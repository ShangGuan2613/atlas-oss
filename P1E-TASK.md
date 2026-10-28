# P1-E Task — Capture UX (window / sidebar / menu-bar drop)

Repo: `~/devApple/atlas-oss`. Clean-room. See `P1-REMAINING.md` dimension D.

## Goal
Every surface accepts files into the library: main window, collection rows (already partially there), **menu bar status item**. Default import mode: **connected**. Duplicates get a clear message. Exemplars: Atlas menu-bar pin + BCStatusItem/droplet patterns + macOS paste.

## Exemplars (binding)
| Layer | Copy | Don't |
|---|---|---|
| Drop targets | Atlas pin — window/sidebar/status all drop → Inbox or hovered collection | browser extension |
| Status item | BCStatusItem / droplet | full Share Extension store flow |
| Paste | Finder-like ⌘V of files/images | social-network special paste |

## Allow
`Sources/AtlasOSSApp/**`, small AtlasCore helpers for `importURLs` if missing, tests, `STATUS.md`, Info.plist / entitlements only if required for status item / pasteboard (document).

## Forbid
Browser ext, Share Extension App Store package, Canvas, Nuke rewrite, decompile Atlas, outside repo.

## Implement

### 1. Core/App import from URLs
- Public helper: import a list of file/directory URLs with `ImportMode.connected` by default (directories → `importFolder`; files → ensure file import path exists or wrap temp folder / new API `importFiles(_:mode:collectionID:)`).
- Reuse Inbox rule from P1b (capture to Inbox + optional collection).
- Return structured result: imported / updated / duplicates / skipped + human summary string for UI alerts.

### 2. Window + detail drop
- Main window / grid empty areas accept `NSItemProvider` file URLs → import to Inbox (or current collection if a user collection is selected — document rule: **selected user collection gets assign; Inbox/All → Inbox only**).
- Visual drop highlight.

### 3. Menu bar pin
- `NSStatusItem` with simple template image (SF Symbol via AppKit, not Atlas assets).
- Register as drop target; on drop → connected import → Inbox; show transient status (notification or menu title flash).
- Click opens/focuses main window.
- Lifecycle tied to app; quitting removes item.

### 4. Paste
- When grid/window key and no text field: ⌘V imports image/file URLs from pasteboard (and optionally TIFF/PNG pasteboard data written to temp then connected-or-copy — prefer write temp + connected if pathless).

### 5. Duplicate UX
- If report.duplicates > 0 or re-import, present a non-blocking banner or alert summary once per drop batch.

## Acceptance
1. `swift build --product AtlasOSSApp` clean
2. `swift test` green — unit tests for URL import helper + pasteboard parsing; keep prior suites
3. Runtime: status item visible; document how to verify drop (manual OK)
4. `STATUS.md` + short report; note any entitlement gaps

## Out of scope
Browser extension, iOS, semantic paste from X/IG, Appearance changes (already P1d).
