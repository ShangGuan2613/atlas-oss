#!/usr/bin/env bash
#
# bench-thumbs.sh — P1-F measurement harness.
#
# Seeds a throwaway library of synthetic photos, then times four passes over it:
#   baseline  decode the ORIGINAL per tile (pre-P1f behaviour)
#   cold      generate + encode + decode one disk thumbnail per item (first browse)
#   warm      a fresh process reading only the disk thumbnails (every later browse)
#   memory    LRU hits (scrolling back over realized tiles)
#
# Usage:
# Release build on purpose: the shipping app is optimised, so a debug measurement would
# overstate per-tile cost.
#
#   ./scripts/bench-thumbs.sh                  # 1000 items @ 1600x1200 (default)
#   COUNT=250 ./scripts/bench-thumbs.sh        # quick run
#   ./scripts/bench-thumbs.sh --keep           # keep the seeded library for inspection
#   SIZE=2400x1800 ./scripts/bench-thumbs.sh   # heavier sources
#
# The numbers printed here are the ones quoted in STATUS.md. Re-run, don't trust the doc.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COUNT="${COUNT:-1000}"
SIZE="${SIZE:-1600x1200}"
WIDTH="${SIZE%x*}"
HEIGHT="${SIZE#*x}"
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

echo "==> P1-F bench: ${COUNT} items @ ${WIDTH}x${HEIGHT}"
echo "    repo: $REPO_ROOT"
echo "    (the library lives in a temp dir and is deleted unless --keep)"

ATLAS_BENCH=1 \
ATLAS_BENCH_COUNT="$COUNT" \
ATLAS_BENCH_WIDTH="$WIDTH" \
ATLAS_BENCH_HEIGHT="$HEIGHT" \
ATLAS_BENCH_KEEP="$KEEP" \
    swift test -c release --filter ThumbnailBench 2>&1 \
    | grep -E "P1F-BENCH|Executed [0-9]+ test|error:" \
    | sed '/^$/d'

echo "==> done. Record the RESULT lines in STATUS.md (method + numbers), not just the speedup."
