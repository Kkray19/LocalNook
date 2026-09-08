#!/bin/bash
# Quiet build helper: strips CLT linker search-path noise and the giant
# frontend command echo, leaving only real diagnostics.
cd "$(dirname "$0")/.." || exit 1
out=$(swift build "$@" 2>&1)
status=$?
echo "$out" | grep -E "error:|warning:" | grep -v "ld: warning: search path" \
  | grep -v "swift-frontend -frontend" | sed 's|/Users/localnook/Developer/LocalNook/||' | head -40
if [ $status -eq 0 ]; then echo "✅ BUILD OK"; else echo "❌ BUILD FAILED ($status)"; fi
exit $status
