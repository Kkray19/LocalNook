#!/bin/bash
# Quiet build helper: strips CLT linker search-path noise and the giant
# frontend command echo, leaving only real diagnostics.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
out=$(swift build "$@" 2>&1)
status=$?
echo "$out" | grep -E "error:|warning:" | grep -v "ld: warning: search path" \
  | grep -v "swift-frontend -frontend" | sed "s|$ROOT/||" | head -40
if [ $status -eq 0 ]; then echo "✅ BUILD OK"; else echo "❌ BUILD FAILED ($status)"; fi
exit $status
