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

scenario_link_install() {
  setup_scratch
  run_installer --link
  assert_rc 0
  assert_symlink "$H/.agents/skills/test-docs"
  assert_symlink "$H/.claude/agents/doc-follower.md"
  [ "$(readlink "$H/.agents/skills/test-docs")" = "$REPO/skills/test-docs" ] \
    || fail "link target"
  grep -q "^link" "$H/$RECEIPT_REL" || fail "receipt records link mode"
}

scenario_link_then_copy_clone_intact() {
  setup_scratch
  run_installer --link
  assert_rc 0
  run_installer            # mode switch: copy replaces links
  assert_rc 0
  assert_not_symlink "$H/.agents/skills/test-docs"
  assert_exists "$H/.agents/skills/test-docs/SKILL.md"
  # THE assertion this scenario exists for: replacing a dir link must not
  # have deleted through it into the clone.
  assert_exists "$REPO/skills/test-docs/SKILL.md"
  assert_exists "$REPO/agents/doc-follower.md"
}

scenario_copy_then_link() {
  setup_scratch
  run_installer
  assert_rc 0
  run_installer --link
  assert_rc 0
  assert_symlink "$H/.agents/skills/test-docs"
}

scenario_uninstall_leaves_nothing() {
  setup_scratch
  run_installer
  assert_rc 0
  run_installer --uninstall
  assert_rc 0
  while IFS= read -r d; do assert_missing "$d"; done < <(expected_dests)
  assert_missing "$H/$RECEIPT_REL"
  assert_missing "$H/.agents"            # created by us -> pruned
  assert_missing "$H/.claude/skills"     # created by us -> pruned
  assert_exists  "$H/.claude"            # pre-existing -> untouched
  assert_exists  "$H/.codex"             # pre-existing -> untouched
}

scenario_uninstall_skips_foreign_link() {
  setup_scratch
  run_installer --link
  assert_rc 0
  rm "$H/.agents/skills/test-docs"
  ln -s "$SCRATCH" "$H/.agents/skills/test-docs"   # user repointed it
  run_installer --uninstall
  assert_rc 2
  assert_symlink "$H/.agents/skills/test-docs"     # left alone
  assert_contains "leaving it" "$OUT"
  assert_missing "$H/.claude/agents/doc-follower.md"  # rest removed
}

scenario_uninstall_leaves_replaced_link_dest() {
  setup_scratch
  run_installer --link
  assert_rc 0
  # user deletes our link and puts a REAL directory in its place —
  # a link-mode receipt entry must never rm -rf a non-link dest
  rm "$H/.agents/skills/test-docs"
  mkdir -p "$H/.agents/skills/test-docs"
  echo "precious" > "$H/.agents/skills/test-docs/user-data.txt"
  run_installer --uninstall
  assert_rc 2
  assert_exists "$H/.agents/skills/test-docs/user-data.txt"
  assert_contains "no longer our symlink" "$OUT"
}

scenario_uninstall_dry_run() {
  setup_scratch
  run_installer
  assert_rc 0
  run_installer --uninstall --dry-run
  assert_rc 0
  assert_exists "$H/$RECEIPT_REL"
  while IFS= read -r d; do assert_exists "$d"; done < <(expected_dests)
  assert_contains "remove:" "$OUT"
}

run_scenarios \
  scenario_dry_run_touches_nothing \
  scenario_fresh_install \
  scenario_rerun_idempotent \
  scenario_rename_cleans_orphan \
  scenario_foreign_dest_skipped_then_forced \
  scenario_link_install \
  scenario_link_then_copy_clone_intact \
  scenario_copy_then_link \
  scenario_uninstall_leaves_nothing \
  scenario_uninstall_skips_foreign_link \
  scenario_uninstall_leaves_replaced_link_dest \
  scenario_uninstall_dry_run
