#!/bin/bash
#
# install.sh — install a built LocalNook.app without ever destroying the copy
# that is already working.
#
# Copyright (C) 2026 Krish Kowli
# Licensed under the GNU General Public License v3.0 or later. See LICENSE.
#
# The previous installation is moved aside, never deleted, and is put back if
# anything after that point fails. A run that cannot validate its candidate
# stops before touching the target at all.
#
#   ./scripts/install.sh                        # dist/LocalNook.app → /Applications
#   ./scripts/install.sh --source path/to.app   # install a specific bundle
#   ./scripts/install.sh --target /tmp/dir      # install somewhere disposable
#   ./scripts/install.sh --no-launch            # install but do not start it
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LocalNook"
SOURCE="$ROOT/dist/$APP_NAME.app"
TARGET_DIR="/Applications"
LAUNCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --target) TARGET_DIR="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help) sed -n '3,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

TARGET="$TARGET_DIR/$APP_NAME.app"
step() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }
fail() { printf "\033[1;31m==> FAILED:\033[0m %s\n" "$1" >&2; exit 1; }

# ── 1. Validate the candidate before touching anything ───────────────────────
# Everything that can be checked without disturbing the running installation is
# checked first. If the candidate is not installable, the existing app is left
# exactly as it was and this run has changed nothing.
step "Validating candidate…"
[ -d "$SOURCE" ] || fail "no bundle at $SOURCE"
EXEC="$SOURCE/Contents/MacOS/$APP_NAME"
[ -x "$EXEC" ] || fail "$SOURCE has no executable at Contents/MacOS/$APP_NAME"
[ -f "$SOURCE/Contents/Info.plist" ] || fail "$SOURCE has no Info.plist"
plutil -lint "$SOURCE/Contents/Info.plist" >/dev/null || fail "Info.plist is malformed"
codesign --verify --deep --strict "$SOURCE" 2>/dev/null \
  || fail "$SOURCE is not validly signed — refusing to install it"
"$EXEC" --version >/dev/null 2>&1 || fail "the candidate binary will not run"

CANDIDATE_SHA="$(shasum -a 256 "$EXEC" | cut -d ' ' -f1)"
echo "    candidate: $CANDIDATE_SHA"

step "Running the deterministic suite against the candidate…"
if "$EXEC" --self-test --deterministic >/dev/null 2>&1; then
  echo "    deterministic suite passed"
else
  fail "the candidate fails its own deterministic suite — not installing it"
fi

[ -d "$TARGET_DIR" ] || fail "no such install directory: $TARGET_DIR"
[ -w "$TARGET_DIR" ] || fail "cannot write to $TARGET_DIR"

# ── 2. Stop the process running from this target, and only that one ──────────
# Matching on the executable path rather than the process name: a build tree
# copy, a second checkout, or an unrelated binary of the same name must not be
# killed by an install into /Applications.
WAS_RUNNING=0
TARGET_EXEC="$TARGET/Contents/MacOS/$APP_NAME"

# Processes whose command line names the target's executable.
#
# Anchoring this to the start of the command line ("^$TARGET_EXEC") looked
# tighter and was wrong: it silently missed anything launched through a wrapper,
# so the script would replace a bundle out from under a live process while
# reporting that nothing was running. Matching the full path anywhere in the
# command line still cannot catch a different app — no other binary's argv
# contains this path — and it does catch the wrapped case.
#
# `pgrep` excludes itself, but not us: running with --source pointing at the
# target would put that path in our own argv, so this process and its parent are
# excluded explicitly.
running_from_target() {
  pgrep -f "$TARGET_EXEC" 2>/dev/null | grep -vx -e "$$" -e "$PPID" || true
}

if [ -d "$TARGET" ]; then
  RUNNING_PIDS="$(running_from_target)"
  if [ -n "$RUNNING_PIDS" ]; then
    WAS_RUNNING=1
    step "Stopping the running $APP_NAME (pids: $(echo "$RUNNING_PIDS" | tr '\n' ' '))…"
    # shellcheck disable=SC2086
    kill $RUNNING_PIDS 2>/dev/null || true
    for _ in $(seq 1 40); do
      [ -z "$(running_from_target)" ] && break
      sleep 0.25
    done
    STILL="$(running_from_target)"
    if [ -n "$STILL" ]; then
      # shellcheck disable=SC2086
      kill -9 $STILL 2>/dev/null || true
      sleep 0.5
    fi
    if [ -n "$(running_from_target)" ]; then
      fail "could not stop the running $APP_NAME — the installation is untouched"
    fi
    echo "    stopped"
  fi
fi

# ── 3. Stage beside the target, then swap ────────────────────────────────────
# Copied to a sibling first so a partial or interrupted copy is never what the
# target path points at. Both temporary paths are on the same filesystem as the
# target, so the swap is a rename rather than a second copy.
STAGED="$TARGET_DIR/.$APP_NAME.incoming.$$"
BACKUP="$TARGET_DIR/.$APP_NAME.previous.$$"
RESTORED=0

restore() {
  # Only ever called with the previous copy still on disk.
  if [ "$RESTORED" -eq 0 ] && [ -n "${BACKUP:-}" ] && [ -d "$BACKUP" ]; then
    RESTORED=1
    printf "\033[1;33m==>\033[0m Restoring the previous installation…\n" >&2
    [ -n "${TARGET:-}" ] && rm -rf "$TARGET"
    if mv "$BACKUP" "$TARGET"; then
      echo "    restored $TARGET" >&2
      if [ "$WAS_RUNNING" -eq 1 ]; then
        open -a "$TARGET" 2>/dev/null && echo "    relaunched the previous version" >&2
      fi

    else
      # The one case worth shouting about: say exactly where the copy is.
      echo "    COULD NOT RESTORE. Your previous app is intact at:" >&2
      echo "    $BACKUP" >&2
    fi
  fi
  rm -rf "$STAGED"
}
# A trap's last command would otherwise become the script's exit status, which
# is how a failed install can report success. Both of these preserve it.
trap 'restore; exit 1' ERR
trap 'status=$?; rm -rf "$STAGED"; exit $status' EXIT

step "Staging into ${TARGET_DIR}…"
rm -rf "$STAGED"
cp -R "$SOURCE" "$STAGED" || fail "could not stage the new bundle"

STAGED_SHA="$(shasum -a 256 "$STAGED/Contents/MacOS/$APP_NAME" | cut -d ' ' -f1)"
[ "$STAGED_SHA" = "$CANDIDATE_SHA" ] \
  || fail "the staged copy does not match the candidate ($STAGED_SHA)"
codesign --verify --deep --strict "$STAGED" 2>/dev/null \
  || fail "the staged copy is not validly signed — the existing app is untouched"

if [ -d "$TARGET" ]; then
  step "Setting the previous installation aside…"
  rm -rf "$BACKUP"
  mv "$TARGET" "$BACKUP" || fail "could not move the existing installation aside"
  echo "    kept at $BACKUP until the replacement is verified"
fi

step "Installing…"
if ! mv "$STAGED" "$TARGET"; then
  restore
  fail "could not move the new bundle into place"
fi

# ── 4. Verify what actually landed, and roll back if it is wrong ─────────────
step "Verifying the installed copy…"
VERIFY_ERROR=""
if [ ! -x "$TARGET_EXEC" ]; then
  VERIFY_ERROR="the installed bundle has no runnable executable"
elif [ "$(shasum -a 256 "$TARGET_EXEC" | cut -d ' ' -f1)" != "$CANDIDATE_SHA" ]; then
  VERIFY_ERROR="the installed binary does not match the candidate hash"
elif ! codesign --verify --deep --strict "$TARGET" 2>/dev/null; then
  VERIFY_ERROR="the installed bundle fails signature verification"
elif ! "$TARGET_EXEC" --version >/dev/null 2>&1; then
  VERIFY_ERROR="the installed binary will not run"
fi

if [ -n "$VERIFY_ERROR" ]; then
  echo "    $VERIFY_ERROR" >&2
  restore
  fail "$VERIFY_ERROR"
fi
echo "    installed: $CANDIDATE_SHA"

# ── 5. Only now is the previous copy expendable ──────────────────────────────
trap 'status=$?; rm -rf "$STAGED"; exit $status' ERR
rm -rf "$BACKUP"

if [ "$LAUNCH" -eq 1 ]; then
  step "Launching…"
  open -a "$TARGET"
  for _ in $(seq 1 20); do
    [ -n "$(running_from_target)" ] && break
    sleep 0.25
  done
  RUNNING="$(running_from_target | head -1)"
  if [ -n "$RUNNING" ]; then
    echo "    running as pid $RUNNING from $TARGET"
  else
    echo "    WARNING: launched but no process is running from $TARGET" >&2
  fi
fi

step "Done."
echo "    $TARGET"
echo "    sha256 $CANDIDATE_SHA"
