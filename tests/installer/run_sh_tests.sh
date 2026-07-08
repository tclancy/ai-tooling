#!/bin/bash
set -eu
. "$(dirname "$0")/lib.sh"

RECEIPT_REL=".agents/.ai-tooling-receipt"

scenario_dry_run_touches_nothing() {
  setup_scratch
  run_installer --dry-run
  assert_rc 0
  assert_missing "$H/$RECEIPT_REL"
  while IFS= read -r d; do assert_missing "$d"; done < <(expected_dests)
  assert_contains "install (copy)" "$OUT"
}

scenario_fresh_install() {
  setup_scratch
  run_installer
  assert_rc 0
  # guard against a vacuous pass if expected_dests ever emits nothing
  [ "$(expected_dests | wc -l | tr -d ' ')" -ge 4 ] || fail "expected_dests suspiciously small"
  assert_contains "found:" "$OUT"
  while IFS= read -r d; do assert_exists "$d"; done < <(expected_dests)
  assert_exists "$H/$RECEIPT_REL"
  [ "$(head -n1 "$H/$RECEIPT_REL")" = "# ai-tooling-receipt v1" ] \
    || fail "receipt header"
  # content fidelity: every skill copy matches its source exactly
  local s name
  for s in "$REPO"/skills/*/; do
    s="${s%/}"; name="$(basename "$s")"
    diff -r "$s" "$H/.agents/skills/$name" >/dev/null || fail "diff: $name"
  done
}

run_scenarios \
  scenario_dry_run_touches_nothing \
  scenario_fresh_install
