#!/usr/bin/env bash
#
# bench-canvas.sh — P2-A / P2-B measurement harness for the Canvas + Infinity boards.
#
# Release build on purpose: a debug measurement would overstate every per-tile cost, and
# the culling numbers here are the ones used to judge the board's feel.
#
# Seeds a throwaway library of synthetic items, then times the four costs the canvas
# pillar is judged on: reset (one transaction of N rows), read at open, spatial-index
# rebuild, and one culled viewport query per camera move — plus the pure zoom maths and
# the drag-commit writes.
#
# P2-B adds the Infinity pass: the same 500-item library with a satellite cluster a million
# points out (unbounded camera geometry), measuring cull queries at ±950 000 pt, the overview
# floor's fit query and a far-from-origin drag commit.
#
# Usage:
#   ./scripts/bench-canvas.sh              # 250 items (P2-A) + 500 items (P2-B)
#   COUNT=1000 ./scripts/bench-canvas.sh   # the size where culling starts to matter
#   ./scripts/bench-canvas.sh --keep       # keep the seeded libraries for inspection
#
# The numbers printed here are the ones quoted in STATUS.md. Re-run, don't trust the doc.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COUNT="${COUNT:-250}"
INFINITY_COUNT="${INFINITY_COUNT:-500}"
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --help|-h) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

echo "==> P2-A canvas bench: ${COUNT} items / P2-B infinity bench: ${INFINITY_COUNT} items"
echo "    repo: $REPO_ROOT"
echo "    (the library lives in a temp dir and is deleted unless --keep)"

ATLAS_BENCH=1 \
ATLAS_BENCH_COUNT="$COUNT" \
ATLAS_BENCH_INFINITY_COUNT="$INFINITY_COUNT" \
ATLAS_BENCH_KEEP="$KEEP" \
    swift test -c release --filter CanvasBench 2>&1 \
    | grep -E "P2A-BENCH|P2B-BENCH|Executed [0-9]+ test|error:" \
    | sed '/^$/d'

echo "==> done. Record the P2A-BENCH / P2B-BENCH lines in STATUS.md (method + numbers), not just the claim."
