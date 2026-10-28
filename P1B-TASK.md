# P1-B Task — Organization (Inbox + nested collections + tags)

Repo: `~/devApple/atlas-oss`. Clean-room. Do **not** decompile Atlas.app.

## Goal
Ship **P1 plan dimension B**: nested collections with drag reorder, Inbox as default landing, tags with batch assign. Align with Atlas public IA + Eagle folder/tag semantics (not smart folders).

## Current state
- Schema v1: flat `collections(name unique)`, `collection_items`, **no** parent, sort, tags, Inbox.
- UI: flat sidebar list; P1-A grid selection/lightbox already works — keep it.

## Allow
- `Sources/AtlasCore/**` — schema migrate to v2 + APIs
- `Sources/AtlasOSSApp/**` — sidebar + drop + tag chrome
- `Tests/**` — core + app tests
- `Package.swift` only if needed
- `STATUS.md`

## Forbid
- Canvas / Infinity / Info panel / Appearance tokens / menu bar pin / Nuke / NSCollectionView rewrite
- Decompile Atlas; touch files outside this repo; force-push
- Breaking connected-import P0 gates (`copiedOriginals == 0`)

---

## 1. Schema v2 (migrate from v1)

Bump `AtlasSchema.currentVersion` to **2**. In `version < 2` migration:

### collections
- `parent_id TEXT NULL REFERENCES collections(id) ON DELETE SET NULL`
- `sort_order REAL NOT NULL DEFAULT 0`
- Keep name uniqueness workable for v2 (document approach: per-parent unique via `UNIQUE(parent_id, name)` with empty-string sentinel for root, or keep global unique and note gap).
- Seed system collection **`Inbox`**. Store id in `library_meta.inbox_collection_id` (preferred) or reserved name.

### tags
```
tags(id TEXT PK, name TEXT NOT NULL UNIQUE, created_at REAL, color TEXT NULL)
item_tags(tag_id, item_id, added_at, PRIMARY KEY(tag_id,item_id))
```

Existing libraries migrate in place. Tests: open v1 fixture → user_version=2 + Inbox present.

---

## 2. AtlasCore API (public)

- `collectionTree()` / hierarchical collections with `children`, `parentID`, `sortOrder`, `itemCount`, `isInbox`
- `createCollection(name:parentID:)` / `renameCollection` / `moveCollection(id:newParentID:newSortOrder:)` / `deleteCollection` (cannot delete Inbox; children → root)
- `inboxCollection()`
- Keep `items(collectionName:)`; add `items(collectionID:)`, `items(tagID:)`
- Inbox rule (document): on import also link to Inbox; assigning to another collection unlinks from Inbox when appropriate. Badge = Inbox membership count.
- Tags: `tags()`, `createTag`, `renameTag`, `deleteTag`, `setTags(itemIDs:tagIDs:mode:)`, `tags(forItemID:)`
- Drag onto collection **adds** membership (many-to-many).

CLI optional; tests required.

---

## 3. App UI

- Tree sidebar: Inbox pinned; nested disclosure; Tags section
- Drag reorder within parent; drag collection onto collection to nest (≥1 level)
- Drop selected items onto collection/tag rows
- New Folder / New Tag / Rename minimal
- Order persists across relaunch

---

## 4. Acceptance

1. `swift build --product AtlasOSSApp` clean
2. `swift test` all green (migration + nest + tag + Inbox + P0 still pass)
3. Update `STATUS.md` + short report

## Out of scope
Smart folders, Info/色票, Appearance, menu bar, canvas, Nuke.
