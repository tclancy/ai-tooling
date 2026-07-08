#!/bin/bash
# Shared helpers for installer scenario tests. Source me.
set -u

FAIL=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

setup_scratch() {
  SCRATCH="$(mktemp -d)"
  REPO="$SCRATCH/repo"
  H="$SCRATCH/home"
  cp -R "$REPO_ROOT" "$REPO"
  mkdir -p "$H/.claude" "$H/.codex"   # activate both harness rows
  export AI_TOOLING_HOME="$H"
}

run_installer() {
  set +e
  # /bin/bash explicitly: enforces the 3.2 target on macOS and works even
  # before the exec bit is set.
  OUT="$(/bin/bash "$REPO/install.sh" "$@" 2>&1)"
  RC=$?
  set -e
}

# Independent re-derivation of the planned dest set from TSV + globs.
# Deliberately NOT the installer's own code.
expected_dests() {
  local content detect dest p
  while IFS=$'\t' read -r content detect dest; do
    case "$content" in ''|'#'*) continue ;; esac
    detect="${detect/#\~/$AI_TOOLING_HOME}"
    dest="${dest/#\~/$AI_TOOLING_HOME}"
    [ "$detect" = "-" ] || [ -d "$detect" ] || continue
    case "$content" in
      skills) for p in "$REPO"/skills/*/; do
                [ -d "$p" ] || continue
                p="${p%/}"; printf '%s\n' "$dest/$(basename "$p")"
              done ;;
      *)      for p in "$REPO/$content"/*.md; do
                [ -f "$p" ] || continue
                printf '%s\n' "$dest/$(basename "$p")"
              done ;;
    esac
  done < "$REPO/harnesses.tsv"
}

fail() { echo "ASSERT FAILED: $*"; FAIL=1; }
assert_exists()      { [ -e "$1" ] || [ -L "$1" ] || fail "exists: $1"; }
assert_missing()     { if [ -e "$1" ] || [ -L "$1" ]; then fail "missing: $1"; fi; }
assert_symlink()     { [ -L "$1" ] || fail "symlink: $1"; }
assert_not_symlink() { [ ! -L "$1" ] || fail "not-symlink: $1"; }
assert_rc()          { [ "$RC" = "$1" ] || fail "rc: want $1 got $RC — output: $OUT"; }
assert_contains()    { case "$2" in *"$1"*) : ;; *) fail "contains '$1' in: $2" ;; esac; }

run_scenarios() {
  local s
  for s in "$@"; do
    echo "== $s"
    "$s"
  done
  if [ "$FAIL" != 0 ]; then echo "RESULT: FAIL"; exit 1; fi
  echo "RESULT: ALL PASS"
}
