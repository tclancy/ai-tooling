#!/usr/bin/env bash
# Run one of this repo's test suites as a pre-commit gate.
#
#     tests/run-suite.sh tests/installer/run_sh_tests.sh
#
# This wrapper exists because a gate's pass signal must not be silence. Both
# suites here report by printing a line and setting an exit code, and there are
# several ways to get a zero exit code having tested nothing: the suite file
# renamed or deleted, the interpreter missing, the suite dying before its first
# scenario. Each of those is a named failure below instead of a green gate.
#
# The success condition is the ALLOWED output -- an exact `RESULT: ALL PASS` --
# rather than the absence of a known failure string. The two suites spell their
# failures differently (`RESULT: FAIL` in tests/installer/lib.sh, `RESULT:
# FAILURES` in tests/skills/run_sh_tests.sh), so a gate grepping for one of
# those would pass every time the other one failed.
set -uo pipefail

PASS_LINE="RESULT: ALL PASS"

die() { echo "run-suite: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "expected exactly one argument (the suite to run), got $#"

SUITE="$1"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || die "cannot cd to repo root $REPO"

[ -f "$SUITE" ] || die "suite not found: $SUITE
    A renamed or deleted suite must fail the gate, not skip it."
[ -r "$SUITE" ] || die "suite not readable: $SUITE"

# /bin/bash, not \`bash\`: the macOS system bash is 3.2 and that is the stated
# compatibility target (the CI matrix runs the same interpreter). A newer bash
# from Homebrew earlier on PATH would test a shell no user is running.
[ -x /bin/bash ] || die "/bin/bash is missing -- cannot run the suite on the 3.2 target"

out="$(/bin/bash "$SUITE" 2>&1)"
rc=$?

echo "$out"

if [ "$rc" -ne 0 ]; then
  die "$SUITE exited $rc"
fi

# Zero exit but no pass line: the suite did not reach its own verdict.
if ! grep -qxF "$PASS_LINE" <<< "$out"; then
  die "$SUITE exited 0 but never printed '$PASS_LINE'.
    That is a suite that stopped early, not a suite that passed."
fi

# Reachability control: the pass line proves the suite finished, not that it
# tested anything. tests/installer/lib.sh prints `RESULT: ALL PASS` off a
# failure counter that nothing incremented, so a suite whose scenario list went
# missing -- `run_scenarios` with no arguments -- reports ALL PASS and exits 0.
# Both suites announce each scenario as `== <name>`, so the count is derivable
# here without either suite having to cooperate.
scenarios="$(grep -c '^== ' <<< "$out")"
if [ "$scenarios" -lt 1 ]; then
  die "$SUITE printed '$PASS_LINE' but announced 0 scenarios.
    A suite that ran nothing has not passed. If a scenario list was refactored
    away, that is the bug; if the '== <name>' announcement changed, fix this
    check to match."
fi
