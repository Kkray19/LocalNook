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

det_pass=0; det_fail=0
echo "== DETERMINISTIC =="
for i in $(seq 1 "$DETERMINISTIC_RUNS"); do
  out="$("$EXEC" --self-test --deterministic 2>&1)"
  line="$(echo "$out" | grep '^deterministic:' || echo "no summary line")"
  if echo "$out" | grep -q '✗'; then
    det_fail=$((det_fail + 1))
    echo "  run $i: $line   FAILING"
    echo "$out" | grep '✗' | sed 's/^/      /'
  else
    det_pass=$((det_pass + 1))
    echo "  run $i: $line"
  fi
  echo "$out" | grep '?.*UNVERIFIED' | sed 's/^/      /'
done

int_pass=0; int_fail=0; int_unver=0
echo
echo "== LIVE INTEGRATION =="
for i in $(seq 1 "$INTEGRATION_RUNS"); do
  out="$("$EXEC" --self-test --integration 2>&1)"
  line="$(echo "$out" | grep '^integration:' || echo "no summary line")"
  probe="$(echo "$out" | grep 'probe:' | tr -d ' ' | tr '\n' ' ')"
  if echo "$out" | grep -q '✗'; then
    int_fail=$((int_fail + 1))
    echo "  run $i: $line   FAILING   [$probe]"
    echo "$out" | grep '✗' | sed 's/^/      /'
  elif echo "$out" | grep -q 'UNVERIFIED'; then
    int_unver=$((int_unver + 1))
    echo "  run $i: $line   [$probe]"
    echo "$out" | grep 'UNVERIFIED' | sed 's/^/      /'
  else
    int_pass=$((int_pass + 1))
    echo "  run $i: $line   [$probe]"
  fi
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
echo "  deterministic: $det_pass/$DETERMINISTIC_RUNS clean, $det_fail with failures"
echo "  integration:   $int_pass/$INTEGRATION_RUNS clean, $int_unver with unverified checks, $int_fail with failures"
if [ "$det_fail" -gt 0 ] || [ "$int_fail" -gt 0 ]; then
  echo "  VERDICT: not fully verified — a check failed."
  exit 1
elif [ "$int_unver" -gt 0 ]; then
  echo "  VERDICT: deterministic suite verified; $int_unver integration run(s) left a check unverified."
  exit 0
else
  echo "  VERDICT: every run clean."
  exit 0
fi
