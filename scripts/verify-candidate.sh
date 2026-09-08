#!/bin/bash
#
# verify-candidate.sh — run a predefined batch against one frozen binary.
#
# Copyright (C) 2026 Krish Kowli
# Licensed under the GNU General Public License v3.0 or later. See LICENSE.
#
# The batch size and the split between halves are fixed here, before any run
# happens, so a report cannot be assembled by picking the batches that came out
# clean. Every run is printed, including failures and unverified checks.
#
# A commit count is a version label. This records the SHA-256 of the exact
# binary every run used, and refuses to continue if it changes underneath.
#
#   ./scripts/verify-candidate.sh dist/LocalNook.app
#
set -uo pipefail

DETERMINISTIC_RUNS=10
INTEGRATION_RUNS=12

APP="${1:-dist/LocalNook.app}"
EXEC="$APP/Contents/MacOS/LocalNook"
[ -x "$EXEC" ] || { echo "no executable at $EXEC" >&2; exit 2; }

SHA="$(shasum -a 256 "$EXEC" | cut -d ' ' -f1)"
# Stated with every report: a window count means nothing without it.
DISPLAYS="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:')"

echo "candidate:  $APP"
echo "sha256:     $SHA"
echo "version:    $("$EXEC" --version 2>/dev/null | head -1)"
echo "displays:   $DISPLAYS connected"
echo "batch:      $DETERMINISTIC_RUNS deterministic + $INTEGRATION_RUNS integration (fixed before running)"
echo

# Exit codes, not output grepping: 0 clean, 1 a demonstrated defect, 2 nothing
# failed but something could not be exercised.
det_pass=0; det_fail=0; det_unver=0
echo "== DETERMINISTIC =="
for i in $(seq 1 "$DETERMINISTIC_RUNS"); do
  out="$("$EXEC" --self-test --deterministic 2>&1)"; rc=$?
  line="$(echo "$out" | grep '^deterministic:' || echo "no summary line")"
  case "$rc" in
    0) det_pass=$((det_pass + 1)); echo "  run $i: $line" ;;
    2) det_unver=$((det_unver + 1)); echo "  run $i: $line   UNVERIFIED"
       echo "$out" | grep 'unverified:' | sed 's/^/      /' ;;
    *) det_fail=$((det_fail + 1)); echo "  run $i: $line   DEFECT"
       echo "$out" | grep '✗' | sed 's/^/      /' ;;
  esac
done

int_pass=0; int_fail=0; int_unver=0
echo
echo "== LIVE INTEGRATION =="
for i in $(seq 1 "$INTEGRATION_RUNS"); do
  out="$("$EXEC" --self-test --integration 2>&1)"; rc=$?
  line="$(echo "$out" | grep '^integration:' || echo "no summary line")"
  probe="$(echo "$out" | grep 'probe:' | sed 's/.*probe: //' | tr '\n' '|')"
  case "$rc" in
    0) int_pass=$((int_pass + 1)); echo "  run $i: $line   [$probe]" ;;
    2) int_unver=$((int_unver + 1)); echo "  run $i: $line   UNVERIFIED   [$probe]"
       echo "$out" | grep 'unverified:' | sed 's/^/      /' ;;
    *) int_fail=$((int_fail + 1)); echo "  run $i: $line   DEFECT   [$probe]"
       echo "$out" | grep '✗' | sed 's/^/      /' ;;
  esac
done

NOW="$(shasum -a 256 "$EXEC" | cut -d ' ' -f1)"
echo
if [ "$NOW" != "$SHA" ]; then
  echo "THE BINARY CHANGED DURING THE BATCH — these results describe no single build." >&2
  echo "  started: $SHA" >&2
  echo "  ended:   $NOW" >&2
  exit 1
fi

echo "== SUMMARY for $SHA =="
echo "  displays connected: $DISPLAYS"
echo "  deterministic: $det_pass/$DETERMINISTIC_RUNS clean, $det_unver unverified, $det_fail with defects"
echo "  integration:   $int_pass/$INTEGRATION_RUNS clean, $int_unver unverified, $int_fail with defects"
if [ "$det_fail" -gt 0 ] || [ "$int_fail" -gt 0 ]; then
  echo "  VERDICT: a demonstrated defect. This candidate must not ship."
  exit 1
elif [ "$det_unver" -gt 0 ] || [ "$int_unver" -gt 0 ]; then
  echo "  VERDICT: no defects; some scenarios could not be exercised."
  echo "           Those remain explicit limitations — this is not fully verified."
  exit 2
else
  echo "  VERDICT: every run clean, nothing unverified."
  exit 0
fi
