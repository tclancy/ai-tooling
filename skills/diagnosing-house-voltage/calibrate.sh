#!/usr/bin/env bash
# Regenerate the calibration tables in SKILL.md's Tooling section.
#
# Every duty-cycle figure quoted in SKILL.md is output of this script. If you
# change detect.py, re-run it and paste the output back -- do not hand-edit the
# numbers. A document that describes a tool's failure boundaries has to be
# derived from the tool, or it drifts into describing a tool that no longer
# exists. (This one already did, twice.)
#
#     ./calibrate.sh            # markdown, to stdout
#
# Fixtures come from synth.py, which prints its own ground truth. Held constant
# across every table unless a column says otherwise: 720 windows, 0.6 V drift
# amplitude, --depression 0.20, --reference-window 30.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNTH="$HERE/synth.py"
DETECT="$HERE/detect.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DRIFT=0.6
WINDOWS=720

# truth <run_len> <period> [drift] -> the duty cycle synth.py says it wrote
truth() {
  uv run --script "$SYNTH" "${3:-$DRIFT}" "$1" "$2" "$TMP/v.csv" --windows "$WINDOWS" \
    | sed 's/GROUND TRUTH: //;s/ duty.*//'
}

# measured <run_len> <period> <drift> [extra detect args...] -> "duty|median|max"
measured() {
  local r=$1 p=$2 d=$3; shift 3
  uv run --script "$SYNTH" "$d" "$r" "$p" "$TMP/v.csv" --windows "$WINDOWS" >/dev/null
  uv run --script "$DETECT" "$TMP/v.csv" --hi-col '' --lo-col '' "$@" 2>&1 | awk '
    /duty cycle:/  { gsub(/%/, "", $3); duty = $3 }
    /run length:/  { med = $4; max = $NF }
    END { printf "%s|%s|%s", duty, (med == "" ? "—" : med), (max == "" ? "—" : max) }'
}

echo "### Duty cycle sweep -- run length and drift held, period varied"
echo
echo "\`synth.py $DRIFT \$RUN 20 v.csv --windows $WINDOWS\` then \`detect.py v.csv --hi-col '' --lo-col ''\`"
echo
echo "| true duty | reported | run length (median / max) |"
echo "|---|---|---|"
for run in 10 12 13 14 15 16 17 18; do
  IFS='|' read -r duty med max <<<"$(measured "$run" 20 "$DRIFT")"
  printf "| %s | %s%% | %s / %s |\n" "$(truth "$run" 20)" "$duty" "$med" "$max"
done

echo
echo "### The ceiling is the reference percentile itself"
echo
echo "\`synth.py $DRIFT \$RUN 20 v.csv --windows $WINDOWS\`, \`detect.py ... --reference-percentile \$P\`"
echo
echo "| true duty | \`0.75\` (default) | \`0.90\` | \`0.95\` |"
echo "|---|---|---|---|"
for run in 4 10 14 15 16 18 19; do
  row="| $(truth "$run" 20) |"
  for pc in 0.75 0.90 0.95; do
    IFS='|' read -r duty _ _ <<<"$(measured "$run" 20 "$DRIFT" --reference-percentile "$pc")"
    row="$row $duty% |"
  done
  printf '%s\n' "$row"
done

echo
echo "### Run-length sweep -- duty held at 50%, run length varied against \`--reference-window 30\`"
echo
echo "\`synth.py $DRIFT \$RUN \$((RUN*2)) v.csv --windows $WINDOWS\` then \`detect.py v.csv --hi-col '' --lo-col ''\`"
echo
echo "| runs of | reported (true 50%) | run length (median / max) |"
echo "|---|---|---|"
for run in 5 10 20 30 45 60; do
  IFS='|' read -r duty med max <<<"$(measured "$run" $((run * 2)) "$DRIFT")"
  printf "| %s windows | %s%% | %s / %s |\n" "$run" "$duty" "$med" "$max"
done

echo
echo "### \`--reference-window\` recovers the run-length limb, and only that limb"
echo
echo "Left: 60-window runs at a true 50% (the worst row above). Right: 8-window runs"
echo "every 10 at a true 80% -- past the duty ceiling."
echo
echo "| \`--reference-window\` | true 50%, runs of 60 | true 80%, runs of 8 |"
echo "|---|---|---|"
for w in 30 60 90 120 300; do
  IFS='|' read -r a _ _ <<<"$(measured 60 120 "$DRIFT" --reference-window "$w")"
  IFS='|' read -r b _ _ <<<"$(measured 8 10 "$DRIFT" --reference-window "$w")"
  printf "| %s | %s%% | %s%% |\n" "$w" "$a" "$b"
done
echo
echo "The right-hand column is the warning: widening the window does not converge on"
echo "80%, it converges on a plausible wrong answer. On the same fixture with no drift"
echo "at all it stays at 0.0% instead -- so the failure does not even have a stable"
echo "signature, and a sweep that 'settles' is not evidence you have escaped it."
echo
echo "| drift amplitude | \`--reference-window 30\` | \`120\` | \`300\` |"
echo "|---|---|---|---|"
for d in 0.0 0.2 0.4 0.6; do
  row="| $d V |"
  for w in 30 120 300; do
    IFS='|' read -r duty _ _ <<<"$(measured 8 10 "$d" --reference-window "$w")"
    row="$row $duty% |"
  done
  printf '%s\n' "$row"
done

echo
echo "### \`--depression\` sweep -- the same fixture at every threshold"
echo
echo "\`synth.py $DRIFT 4 25 v.csv --windows $WINDOWS\`, true 16.1%"
echo
echo "| \`--depression\` | reported | run length (median / max) |"
echo "|---|---|---|"
for dep in 0.05 0.10 0.20 0.40 0.60; do
  IFS='|' read -r duty med max <<<"$(measured 4 25 "$DRIFT" --depression "$dep")"
  printf "| %s V | %s%% | %s / %s |\n" "$dep" "$duty" "$med" "$max"
done
