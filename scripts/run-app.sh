#!/usr/bin/env bash
#
# run-app.sh — build and launch the minimal SwiftUI viewer (P0.5).
#
#   ./scripts/run-app.sh              # debug build, then run in the foreground
#   ./scripts/run-app.sh -c release   # release build (extra args go to swift build)
#
# The viewer opens the default library at
#   ~/Library/Application Support/AtlasOSS/default.atlaslibrary
# (creating an empty one if it does not exist yet).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PRODUCT="AtlasOSSApp"

echo "==> Building $PRODUCT"
swift build --product "$PRODUCT" "$@"

BIN_DIR="$(swift build --product "$PRODUCT" "$@" --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN not found after build" >&2
    exit 1
fi

echo "==> Launching $BIN"
echo "    library: \$HOME/Library/Application Support/AtlasOSS/default.atlaslibrary"
exec "$BIN"
