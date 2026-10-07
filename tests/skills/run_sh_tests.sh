#!/usr/bin/env bash
# Tests for the executable parts of skills/ -- currently diagnosing-house-voltage.
#
# The load-bearing one is scenario_skill_md_matches_calibrate: SKILL.md quotes
# ~30 measured figures describing detect.py's failure boundaries, and a document
# like that is only worth reading if it still describes the tool. It has already
# drifted into describing a different tool twice. This makes the drift a red build
# instead of advice nobody re-runs.
#
#     /bin/bash tests/skills/run_sh_tests.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL_DIR="$REPO/skills/diagnosing-house-voltage"
FAILED=0

fail() { echo "  FAIL: $*"; FAILED=1; }

scenario() { echo "== $1"; }

# Reachability control. Every numeric assertion below compares values scraped out
# of detect.py/synth.py stdout with grep, and an empty capture makes two of them
# pass for the wrong reason: `[ "" = "" ]` is true, and awk reads a bare "" as a
# string so `"" < 10` is true as well. Both are exactly what a missing `uv`, a
# changed output format, or a script that died before printing produces -- so the
# scenarios that assert the behaviour would go green having measured nothing.
# Assert the capture is a number BEFORE comparing it.
assert_number() {
  case "$2" in
    '') fail "$1 captured nothing -- the scrape found no number, so the
    comparison below would pass vacuously. Check that uv is on PATH and that
    detect.py/synth.py still print the line this scrape greps for."; return 1 ;;
  esac
  case "$2" in
    *[!0-9.]*|.|'') fail "$1 captured '$2', which is not a number"; return 1 ;;
  esac
  return 0
}

# --- synth.py's answer key agrees with detect.py on a fixture inside the good band
scenario scenario_ground_truth_round_trips
tmp="$(mktemp -d)"
truth=$(uv run --script "$SKILL_DIR/synth.py" 0.6 4 25 "$tmp/v.csv" --windows 720 \
        | grep -o '[0-9.]*% duty' | cut -d% -f1)
got=$(uv run --script "$SKILL_DIR/detect.py" "$tmp/v.csv" --hi-col '' --lo-col '' \
      | grep -o 'duty cycle: [0-9.]*%' | grep -o '[0-9.]*')
if assert_number "synth ground truth" "$truth" \
   && assert_number "detect duty cycle" "$got"; then
  [ "$truth" = "$got" ] || fail "synth said ${truth}% duty, detect reported ${got}%"
fi
rm -rf "$tmp"

# --- the documented ceiling is real: past ~70% duty, detect.py collapses downward
scenario scenario_duty_ceiling_still_collapses
tmp="$(mktemp -d)"
uv run --script "$SKILL_DIR/synth.py" 0.6 16 20 "$tmp/v.csv" --windows 720 >/dev/null
got=$(uv run --script "$SKILL_DIR/detect.py" "$tmp/v.csv" --hi-col '' --lo-col '' \
      | grep -o 'duty cycle: [0-9.]*%' | grep -o '[0-9.]*')
# True duty is 80%. If detect.py is ever fixed so this reports near 80, SKILL.md's
# whole ceiling section is stale and must be rewritten -- so failing here is correct.
if assert_number "detect duty cycle" "$got"; then
  # Two-sided on purpose. An upper bound alone passes on 0.0%, which is what
  # detect.py reports when it finds no depression at all -- a tool that detected
  # nothing is not a tool exhibiting the documented collapse. Measured at this
  # commit this fixture reports 0.8%, so the lower bound has real headroom.
  awk -v g="$got" 'BEGIN { exit !(g + 0 > 0 && g + 0 < 10) }' \
    || fail "80%-duty fixture reported ${got}% -- expected the documented collapse
    (above 0%, below 10%). A reported 0% means detect.py found nothing rather
    than collapsing; if detect.py was improved, regenerate SKILL.md's Tooling
    section from calibrate.sh"
fi
rm -rf "$tmp"

# --- SKILL.md's numbers ARE calibrate.sh's output, not a transcription of it
scenario scenario_skill_md_matches_calibrate
# /bin/bash, not `bash`: calibrate.sh generates the figures SKILL.md quotes, and
# a Homebrew bash earlier on PATH would generate them under a shell no user runs.
generated="$(/bin/bash "$SKILL_DIR/calibrate.sh")" || fail "calibrate.sh exited non-zero"

# Reachability control. The comparison below is a loop over calibrate.sh's table
# rows, and a loop over nothing passes: with no rows, FAILED is never set and
# this scenario -- the load-bearing one -- reports ALL PASS having compared
# nothing. A non-zero exit is NOT enough to catch that, because every figure
# reaches `generated` through a command substitution whose failure does not
# propagate. Assert the count before trusting the comparison.
rows="$(grep -cE '^\| ' <<<"$generated")"
[ "$rows" -ge 20 ] || fail "calibrate.sh emitted $rows markdown table rows; it
    emits well over 20. Nothing was compared, so this scenario would otherwise
    pass having measured nothing."
# SKILL.md bolds figures for emphasis; that is the only edit allowed on a pasted row.
documented="$(grep -E '^\| ' "$SKILL_DIR/SKILL.md" | sed 's/\*\*//g')"
while IFS= read -r row; do
  case "$row" in *[0-9]*) ;; *) continue ;; esac
  grep -qxF "$row" <<<"$documented" \
    || fail "calibrate.sh emits a row SKILL.md does not carry:
      $row
    Re-run ./skills/diagnosing-house-voltage/calibrate.sh and paste its output in."
done < <(grep -E '^\| ' <<<"$generated")

if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: ALL PASS"
else
  echo "RESULT: FAILURES"
fi
exit "$FAILED"
