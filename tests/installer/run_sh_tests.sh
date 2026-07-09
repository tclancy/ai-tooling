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

scenario_rerun_idempotent() {
  setup_scratch
  run_installer
  assert_rc 0
  run_installer
  assert_rc 0
  run_installer
  assert_rc 0
  while IFS= read -r d; do assert_exists "$d"; done < <(expected_dests)
  # Compaction bound: every run dedupes to 1 unit line per dest, then
  # appends 1 more — so after ANY number of re-runs there are exactly 2.
  # Without compaction, three runs would leave 3 per dest (this is what
  # makes the scenario fail before Task 2's implementation).
  local n_dests n_lines
  n_dests="$(expected_dests | wc -l | tr -d ' ')"
  n_lines="$(awk -F'\t' 'NF >= 3 && $1 != "dir"' "$H/$RECEIPT_REL" | wc -l | tr -d ' ')"
  [ "$n_lines" = "$((2 * n_dests))" ] || fail "receipt not compacted: $n_lines unit lines for $n_dests dests"
}

scenario_rename_cleans_orphan() {
  setup_scratch
  run_installer
  assert_rc 0
  mv "$REPO/skills/test-docs" "$REPO/skills/test-docs-renamed"
  run_installer
  assert_rc 0
  assert_missing "$H/.agents/skills/test-docs"
  assert_missing "$H/.claude/skills/test-docs"
  assert_exists  "$H/.agents/skills/test-docs-renamed"
  assert_exists  "$H/.claude/skills/test-docs-renamed"
}

scenario_foreign_dest_skipped_then_forced() {
  setup_scratch
  mkdir -p "$H/.agents/skills/test-docs"
  echo "precious user file" > "$H/.agents/skills/test-docs/mine.txt"
  run_installer
  assert_rc 2
  assert_exists "$H/.agents/skills/test-docs/mine.txt"      # untouched
  assert_exists "$H/.claude/skills/test-docs/SKILL.md"      # everything else proceeded
  assert_contains "skip (exists, not ours" "$OUT"
  run_installer --force
  assert_rc 0
  assert_missing "$H/.agents/skills/test-docs/mine.txt"     # claimed and replaced
  assert_exists  "$H/.agents/skills/test-docs/SKILL.md"
}

run_scenarios \
  scenario_dry_run_touches_nothing \
  scenario_fresh_install \
  scenario_rerun_idempotent \
  scenario_rename_cleans_orphan \
  scenario_foreign_dest_skipped_then_forced
