#!/usr/bin/env bash
#
# bench-scroll.sh — P1-F grid-host measurement (frame times while scrolling a 1k library).
#
#   ./scripts/bench-scroll.sh              # seed/reuse a 1000-item library, scroll 8s
#   COUNT=400 DURATION=6 ./scripts/bench-scroll.sh
#   LIBRARY=/path/to.lib.atlaslibrary ./scripts/bench-scroll.sh   # reuse an existing library
#
# What it does:
#   1. seeds a throwaway library of synthetic photos with warm disk thumbnails
#      (delegates to bench-thumbs.sh --keep), unless LIBRARY is given;
#   2. builds the app in **release** (the shipping configuration);
#   3. launches it with ATLAS_LIBRARY_PATH + ATLAS_SCROLL_PROBE. The app itself drives the
#      scroll offset every display frame and reports the gap between drawn frames;
#   4. prints the P1F-SCROLL lines.
#
# The frame numbers are what decide whether the LazyVGrid host is good enough or whether
# the grid has to become an NSCollectionView. Method matters more than the digits: they are
# wall-clock intervals between CADisplayLink callbacks, so a missed frame shows up as a
# ~33ms interval, not as a smoothed average.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COUNT="${COUNT:-1000}"
DURATION="${DURATION:-8}"
STEP="${STEP:-18}"
LIBRARY="${LIBRARY:-}"

COLD="${COLD:-0}"

if [[ -z "$LIBRARY" ]]; then
    if [[ "$COLD" == "1" ]]; then
        echo "==> Seeding a ${COUNT}-item library with NO thumbnails (cold first browse)"
        SEED_LOG="$(mktemp)"
        COUNT="$COUNT" ATLAS_BENCH_IMPORT_ONLY=1 ./scripts/bench-thumbs.sh --keep | tee "$SEED_LOG"
    else
        echo "==> Seeding a ${COUNT}-item library with warm thumbnails (bench-thumbs.sh --keep)"
        SEED_LOG="$(mktemp)"
        COUNT="$COUNT" ./scripts/bench-thumbs.sh --keep | tee "$SEED_LOG"
    fi
    LIBRARY="$(grep -o 'kept workspace at .*' "$SEED_LOG" | sed 's/kept workspace at //')/bench.atlaslibrary"
    rm -f "$SEED_LOG"
    if [[ ! -d "$LIBRARY" ]]; then
        echo "error: could not find the seeded library (got '$LIBRARY')" >&2
        exit 1
    fi
fi

echo "==> Library: $LIBRARY"
echo "==> Building AtlasOSSApp (release)"
swift build -c release --product AtlasOSSApp
BIN="$(swift build -c release --product AtlasOSSApp --show-bin-path)/AtlasOSSApp"

LOG="$(mktemp)"
echo "==> Scrolling for ${DURATION}s at ${STEP}pt/frame (app logs: $LOG)"
set +e
ATLAS_LIBRARY_PATH="$LIBRARY" \
ATLAS_SCROLL_PROBE="$DURATION" \
ATLAS_SCROLL_STEP="$STEP" \
    "$BIN" >"$LOG" 2>&1
set -e

grep -E "P1F-SCROLL" "$LOG" || {
    echo "error: the probe produced no output. Last 20 lines:" >&2
    tail -20 "$LOG" >&2
    exit 1
}

echo
echo "==> Interpretation"
echo "    p95 <= 16.67ms  → the grid holds 60fps while scrolling this library"
echo "    p95  > 16.67ms  → frames are being dropped; that is the NSCollectionView case"
echo "    (this Mac's panel is 60Hz; on ProMotion the budget is 8.33ms)"
