#!/usr/bin/env bash
#
# verify-p0.sh — end-to-end P0 acceptance for AtlasOSS.
#
# Exercises the real CLI binary (not just the test target):
#   1. builds the package
#   2. creates a throwaway library package
#   3. imports a fixture folder in CONNECTED mode  -> asserts 0 originals on disk
#   4. asserts the library lists at least the fixture count
#   5. imports the same fixtures in COPY mode      -> asserts 1 original per file
#   6. re-imports in COPY mode                     -> asserts 0 new copies (hash dedupe)
#   7. prints library info and a cold-open TTFI measurement
#
# Exit codes: 0 = all assertions passed, 1 = a failure, 2 = setup problem.
# The temp workspace is intentionally left behind for inspection (nothing outside it is touched).
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FIXTURE_COUNT=4
PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  RESULTS+=("  ✅ PASS  $1")
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  RESULTS+=("  ❌ FAIL  $1")
}

assert_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then pass "$1 (=$3)"; else fail "$1 (expected '$2', got '$3')"; fi
}

assert_ge() { # desc minimum actual
  if [[ "$3" =~ ^[0-9]+$ ]] && (( $3 >= $2 )); then
    pass "$1 ($3 >= $2)"
  else
    fail "$1 (expected >= $2, got '$3')"
  fi
}

assert_contains() { # desc needle haystack
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing '$2')"; fi
}

# Extracts an integer field from pretty-printed JSON: "key" : 42
json_int() { # json key
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+" | head -n1 | grep -oE '[0-9]+$'
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

echo "=============================================================="
echo " AtlasOSS P0 verification"
echo "=============================================================="
echo "repo:    $REPO_ROOT"
echo "swift:   $(swift --version 2>/dev/null | head -n1)"
echo "macOS:   $(sw_vers -productVersion 2>/dev/null || echo unknown)"
echo "cpu:     $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
echo "date:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------------------
section "1/8  swift build"
# ---------------------------------------------------------------------------
if swift build 2>&1 | tee /tmp/atlasoss-build.log | tail -n 5; then
  if [[ -x "$(swift build --show-bin-path 2>/dev/null)/atlasoss" ]]; then
    pass "package builds"
  else
    fail "atlasoss binary missing after build"
  fi
else
  fail "swift build failed"
  echo "--- see /tmp/atlasoss-build.log ---"
  printf '%s\n' "${RESULTS[@]}"
  exit 1
fi

BIN="$(swift build --show-bin-path)/atlasoss"
echo "binary:  $BIN"

# ---------------------------------------------------------------------------
section "2/8  scratch workspace + fixtures"
# ---------------------------------------------------------------------------
BASE_TMP="${TMPDIR:-/tmp}"
BASE_TMP="${BASE_TMP%/}"
WORKSPACE="$(mktemp -d "$BASE_TMP/atlasoss-verify.XXXXXX")" || { echo "mktemp failed"; exit 2; }
FIXTURES="$WORKSPACE/fixtures"
LIB_CONNECTED="$WORKSPACE/connected.atlaslibrary"
LIB_COPY="$WORKSPACE/copy.atlaslibrary"

echo "workspace: $WORKSPACE"
swift scripts/fixtures.swift write "$FIXTURES" || { echo "fixture generation failed"; exit 2; }

FIXTURE_FILES=$(find "$FIXTURES" -type f -name '*.png' | wc -l | tr -d ' ')
assert_eq "fixture folder contains $FIXTURE_COUNT PNGs" "$FIXTURE_COUNT" "$FIXTURE_FILES"

# ---------------------------------------------------------------------------
section "3/8  init library package"
# ---------------------------------------------------------------------------
INIT_OUT=$("$BIN" --library "$LIB_CONNECTED" init 2>&1)
echo "$INIT_OUT"
if [[ -f "$LIB_CONNECTED/library.sqlite" ]]; then
  pass "library.sqlite created"
else
  fail "library.sqlite missing"
fi
if [[ -d "$LIB_CONNECTED/originals" && -d "$LIB_CONNECTED/thumbnails" ]]; then
  pass "originals/ + thumbnails/ directories created"
else
  fail "originals/ or thumbnails/ directory missing"
fi

# ---------------------------------------------------------------------------
section "4/8  import in CONNECTED mode (must copy 0 originals)"
# ---------------------------------------------------------------------------
CONNECTED_JSON=$("$BIN" --library "$LIB_CONNECTED" --json import "$FIXTURES" --mode connected --collection fixtures)
echo "$CONNECTED_JSON"

assert_eq "connected: copiedOriginals" "0" "$(json_int "$CONNECTED_JSON" copiedOriginals)"
assert_eq "connected: imported"        "$FIXTURE_COUNT" "$(json_int "$CONNECTED_JSON" imported)"
assert_contains "connected: mode field" '"mode" : "connected"' "$CONNECTED_JSON"

ORIGINALS_FILES=$(find "$LIB_CONNECTED/originals" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "connected: files on disk under originals/" "0" "$ORIGINALS_FILES"

ORIGINALS_BYTES=$(du -sk "$LIB_CONNECTED/originals" 2>/dev/null | awk '{print $1}')
assert_eq "connected: originals/ holds no payload bytes (KiB)" "0" "${ORIGINALS_BYTES:-0}"

# source files must still be intact and in place
for f in "$FIXTURES"/*.png; do
  if [[ -f "$f" ]]; then :; else fail "fixture disappeared: $f"; fi
done
pass "connected: source fixtures untouched"

# ---------------------------------------------------------------------------
section "5/8  list + info show >= fixture count"
# ---------------------------------------------------------------------------
LIST_JSON=$("$BIN" --library "$LIB_CONNECTED" --json list)
LIST_COUNT=$(printf '%s' "$LIST_JSON" | grep -c '"id"' || true)
assert_ge "list: item rows" "$FIXTURE_COUNT" "$LIST_COUNT"

INFO_JSON=$("$BIN" --library "$LIB_CONNECTED" --json info)
echo "$INFO_JSON"
assert_ge "info: itemCount" "$FIXTURE_COUNT" "$(json_int "$INFO_JSON" itemCount)"
assert_eq "info: originalsFileCount" "0" "$(json_int "$INFO_JSON" originalsFileCount)"
assert_eq "info: connectedCount" "$FIXTURE_COUNT" "$(json_int "$INFO_JSON" connectedCount)"
assert_eq "info: schemaVersion" "1" "$(json_int "$INFO_JSON" schemaVersion)"

"$BIN" --library "$LIB_CONNECTED" list
"$BIN" --library "$LIB_CONNECTED" collections

# ---------------------------------------------------------------------------
section "6/8  import in COPY mode (1 original per unique content hash)"
# ---------------------------------------------------------------------------
COPY_JSON=$("$BIN" --library "$LIB_COPY" --json import "$FIXTURES" --mode copy --collection fixtures)
echo "$COPY_JSON"
assert_eq "copy: copiedOriginals" "$FIXTURE_COUNT" "$(json_int "$COPY_JSON" copiedOriginals)"
assert_eq "copy: imported"        "$FIXTURE_COUNT" "$(json_int "$COPY_JSON" imported)"

COPY_FILES=$(find "$LIB_COPY/originals" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "copy: files under originals/" "$FIXTURE_COUNT" "$COPY_FILES"

# ---------------------------------------------------------------------------
section "7/8  re-import in COPY mode dedupes by content hash"
# ---------------------------------------------------------------------------
REIMPORT_JSON=$("$BIN" --library "$LIB_COPY" --json import "$FIXTURES" --mode copy)
echo "$REIMPORT_JSON"
assert_eq "reimport: copiedOriginals" "0" "$(json_int "$REIMPORT_JSON" copiedOriginals)"
assert_eq "reimport: duplicates"      "$FIXTURE_COUNT" "$(json_int "$REIMPORT_JSON" duplicates)"

COPY_FILES_AFTER=$(find "$LIB_COPY/originals" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "reimport: files under originals/ unchanged" "$FIXTURE_COUNT" "$COPY_FILES_AFTER"

# ---------------------------------------------------------------------------
section "8/8  cold-open TTFI measurement"
# ---------------------------------------------------------------------------
"$BIN" --library "$LIB_CONNECTED" bench --iterations 7
echo
echo "process-level wall time (10 consecutive CLI runs, connected library):"
/usr/bin/time -p bash -c 'for _ in $(seq 10); do "$0" --library "$1" list >/dev/null; done' \
  "$BIN" "$LIB_CONNECTED" 2>"$WORKSPACE/time.txt" || true
TOTAL_REAL=$(awk '/^real/ {print $2}' "$WORKSPACE/time.txt")
if [[ -n "$TOTAL_REAL" ]]; then
  PER_RUN=$(awk -v total="$TOTAL_REAL" 'BEGIN { printf "%.2f", (total / 10) * 1000 }')
  echo "  total real: ${TOTAL_REAL}s over 10 runs -> ${PER_RUN} ms per CLI process"
fi
grep -E '^(real|user|sys)' "$WORKSPACE/time.txt" || true

# ---------------------------------------------------------------------------
section "SUMMARY"
# ---------------------------------------------------------------------------
printf '%s\n' "${RESULTS[@]}"
echo
echo "passed: $PASS_COUNT"
echo "failed: $FAIL_COUNT"
echo "workspace kept at: $WORKSPACE"

if (( FAIL_COUNT > 0 )); then
  echo
  echo "RESULT: FAIL"
  exit 1
fi

echo
echo "RESULT: PASS — P0 acceptance gates met"
exit 0
