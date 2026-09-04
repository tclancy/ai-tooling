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

# --- synth.py's answer key agrees with detect.py on a fixture inside the good band
scenario scenario_ground_truth_round_trips
tmp="$(mktemp -d)"
truth=$(uv run --script "$SKILL_DIR/synth.py" 0.6 4 25 "$tmp/v.csv" --windows 720 \
        | grep -o '[0-9.]*% duty' | cut -d% -f1)
got=$(uv run --script "$SKILL_DIR/detect.py" "$tmp/v.csv" --hi-col '' --lo-col '' \
      | grep -o 'duty cycle: [0-9.]*%' | grep -o '[0-9.]*')
[ "$truth" = "$got" ] || fail "synth said ${truth}% duty, detect reported ${got}%"
rm -rf "$tmp"

# --- the documented ceiling is real: past ~70% duty, detect.py collapses downward
scenario scenario_duty_ceiling_still_collapses
tmp="$(mktemp -d)"
uv run --script "$SKILL_DIR/synth.py" 0.6 16 20 "$tmp/v.csv" --windows 720 >/dev/null
got=$(uv run --script "$SKILL_DIR/detect.py" "$tmp/v.csv" --hi-col '' --lo-col '' \
      | grep -o 'duty cycle: [0-9.]*%' | grep -o '[0-9.]*')
# True duty is 80%. If detect.py is ever fixed so this reports near 80, SKILL.md's
# whole ceiling section is stale and must be rewritten -- so failing here is correct.
awk -v g="$got" 'BEGIN { exit !(g < 10) }' \
  || fail "80%-duty fixture reported ${got}% -- expected the documented collapse (<10%);
    if detect.py was improved, regenerate SKILL.md's Tooling section from calibrate.sh"
rm -rf "$tmp"

# --- SKILL.md's numbers ARE calibrate.sh's output, not a transcription of it
scenario scenario_skill_md_matches_calibrate
generated="$(bash "$SKILL_DIR/calibrate.sh")" || fail "calibrate.sh exited non-zero"
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
