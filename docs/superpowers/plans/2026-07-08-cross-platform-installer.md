# Cross-Platform Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-command install/update/uninstall of this repo's skills, agents, and commands into the right per-harness directories on Linux, macOS, and native Windows.

**Architecture:** Two sibling scripts (`install.sh` for POSIX/Git Bash, `install.ps1` for Windows PowerShell 5.1) that contain only mechanics. All routing lives in `harnesses.tsv`; all content is discovered by globbing `skills/*/`, `agents/*.md`, `commands/*.md` at runtime. A receipt file makes re-runs exact and uninstall safe.

**Tech Stack:** bash 3.2, POSIX utilities + awk, Windows PowerShell 5.1, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-07-08-installer-design.md` — read it before starting; it is the contract.

## Global Constraints

- Branch: all work on `claude/installer`. Commit at the end of every task.
- `install.sh` must run under macOS `/bin/bash` 3.2: no `mapfile`, no associative arrays, no `${var,,}`, no `&>`. Shebang `#!/bin/bash`.
- `install.ps1` must run under Windows PowerShell 5.1: no ternary, no `??`, symlinks via `New-Item ... -Value` (not `-Target`).
- `harnesses.tsv`: fields separated by real TAB characters; comments are full lines starting with `#`; no inline comments; `-` in detect_dir = unconditional.
- Exit codes (both scripts): `0` clean, `1` hard error, `2` completed with safety-rule skips.
- Receipt: `<home>/.agents/.ai-tooling-receipt`, first line `# ai-tooling-receipt v1`, then `mode<TAB>source<TAB>dest` lines. **Last line for a given dest wins.** `mode` ∈ `copy|link|dir` (`dir` = a directory the installer created, source field `-`).
- Home resolution: every `~` expands through `$AI_TOOLING_HOME` falling back to `$HOME` (sh) / `$env:USERPROFILE` (ps1).
- **Never recursive-delete through a symlink.** Deleting a link removes the link object only.
- Path comparisons are case-insensitive on macOS and Windows (fold to lowercase before comparing).
- No dependencies beyond stock tooling: POSIX sh utils + awk; no PowerShell modules.
- Tests never mutate the real checkout or real home: every scenario copies the repo into a scratch dir and points `AI_TOOLING_HOME` at a scratch home.

---

### Task 1: harnesses.tsv, test scaffolding, copy-mode install with receipt

**Files:**
- Create: `.gitattributes`
- Create: `harnesses.tsv`
- Create: `install.sh`
- Create: `tests/installer/lib.sh`
- Create: `tests/installer/run_sh_tests.sh`

**Interfaces:**
- Consumes: repo content folders (`skills/`, `agents/`, `commands/`) as they exist today.
- Produces (relied on by every later task):
  - `install.sh` functions: `die msg`, `note msg`, `fold str` (stdout), `expand_tilde path` (stdout), `active_rows` (stdout: `content\tdest`), `units content` (stdout: `name\tsrc`), `planned` (stdout: `src\tdest`), `ensure_dir path`, `receipt_append mode src dest`, `remove_path path`, `install_unit src dest`, `do_install`, `main`.
  - Globals: `REPO_DIR HOME_DIR TSV RECEIPT_DIR RECEIPT RECEIPT_HEADER MODE ACTION DRY FORCE STATUS CASE_FOLD`.
  - `tests/installer/lib.sh` helpers: `setup_scratch` (sets `$SCRATCH $REPO $H`, exports `AI_TOOLING_HOME=$H`), `run_installer [flags…]` (sets `$RC`, `$OUT`), `expected_dests` (stdout), `assert_exists p`, `assert_missing p`, `assert_symlink p`, `assert_not_symlink p`, `assert_rc want`, `assert_contains needle haystack` — all set global `FAIL=1` on failure and print `ASSERT FAILED: …`.

- [ ] **Step 1: Create `harnesses.tsv`** (fields below are separated by real tabs — verify with `cat -t harnesses.tsv`, tabs show as `^I`):

```
# content <TAB> detect_dir <TAB> dest_dir
# The '-' row is the universal agentskills location (Codex & friends).
# Claude Code verified NOT to scan it (2026-07-08), hence its own row.
# No commands row for Claude Code: skills already register the slash
# command there and the names would collide.
skills	-	~/.agents/skills
skills	~/.claude	~/.claude/skills
agents	~/.claude	~/.claude/agents
commands	~/.codex	~/.codex/prompts
```

Also create `.gitattributes` — without it, Git-for-Windows' default
`core.autocrlf=true` checks these files out with CRLF, and a CRLF TSV makes
`install.sh` **exit 0 while installing into garbage `skills\r/` dirs**
(empirically confirmed during plan review):

```
* text=auto
*.sh text eol=lf
*.tsv text eol=lf
*.ps1 text eol=lf
*.md text eol=lf
```

- [ ] **Step 2: Write `tests/installer/lib.sh`:**

```bash
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
```

- [ ] **Step 3: Write `tests/installer/run_sh_tests.sh` with the first two scenarios:**

```bash
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
```

- [ ] **Step 4: Run to verify failure** — `/bin/bash tests/installer/run_sh_tests.sh`
Expected: FAIL (install.sh doesn't exist yet, so every scenario fails).

- [ ] **Step 5: Write `install.sh` (complete file):**

```bash
#!/bin/bash
# ai-tooling installer — Linux, macOS, Git Bash.
# What-goes-where lives in harnesses.tsv; what-goes is discovered by
# globbing skills/ agents/ commands/. Spec:
# docs/superpowers/specs/2026-07-08-installer-design.md
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${AI_TOOLING_HOME:-$HOME}"
TSV="$REPO_DIR/harnesses.tsv"
RECEIPT_DIR="$HOME_DIR/.agents"
RECEIPT="$RECEIPT_DIR/.ai-tooling-receipt"
RECEIPT_HEADER="# ai-tooling-receipt v1"

MODE=copy ACTION=install DRY=0 FORCE=0 STATUS=0

usage() {
  cat <<'EOF'
Usage: install.sh [--link] [--uninstall] [--dry-run] [--force]
  --link       symlink from this clone instead of copying
  --uninstall  remove everything a previous run installed
  --dry-run    print actions without performing them
  --force      claim destinations that exist but aren't ours
Exit codes: 0 ok, 1 error, 2 completed with skips.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --link) MODE=link ;;
    --uninstall) ACTION=uninstall ;;
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

die()  { echo "error: $*" >&2; exit 1; }
note() { echo "$*"; }

case "$(uname -s)" in
  Darwin|MINGW*|MSYS*|CYGWIN*) CASE_FOLD=1 ;;
  *) CASE_FOLD=0 ;;
esac

fold() {
  if [ "$CASE_FOLD" = 1 ]; then
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
  else
    printf '%s\n' "$1"
  fi
}

expand_tilde() {
  case "$1" in
    "~")    printf '%s\n' "$HOME_DIR" ;;
    "~/"*)  printf '%s\n' "$HOME_DIR/${1#\~/}" ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

all_dests() {
  local content detect dest
  while IFS=$'\t' read -r content detect dest; do
    case "$content" in ''|'#'*) continue ;; esac
    dest="${dest%$'\r'}"   # belt-and-braces vs CRLF checkouts
    [ -n "$detect" ] && [ -n "$dest" ] \
      || die "harnesses.tsv: malformed row: '$content' (need 3 tab-separated fields)"
    printf '%s\n' "$(expand_tilde "$dest")"
  done < "$TSV"
}

check_disjoint() {
  local dup a b
  dup="$(all_dests | sort | uniq -d)"
  [ -z "$dup" ] || die "harnesses.tsv: duplicate dest: $dup"
  while IFS= read -r a; do
    while IFS= read -r b; do
      [ "$a" = "$b" ] && continue
      case "$(fold "$a/")" in "$(fold "$b")"/*) die "harnesses.tsv: dest '$a' lies inside dest '$b'" ;; esac
    done <<EOF_B
$(all_dests)
EOF_B
  done <<EOF_A
$(all_dests)
EOF_A
}

report_skips() {  # harness-detection report: names every found AND skipped detect dir
  local content detect dest
  while IFS=$'\t' read -r content detect dest; do
    case "$content" in ''|'#'*) continue ;; esac
    [ "$detect" = "-" ] && continue
    if [ -d "$(expand_tilde "$detect")" ]; then
      note "found: $(expand_tilde "$detect") ($content will be installed)"
    else
      note "skipped: $(expand_tilde "$detect") not found (no $content for that harness)"
    fi
  done < "$TSV"
}

active_rows() {  # stdout: content<TAB>expanded_dest — data only, no notes
  local content detect dest
  while IFS=$'\t' read -r content detect dest; do
    case "$content" in ''|'#'*) continue ;; esac
    dest="${dest%$'\r'}"   # belt-and-braces vs CRLF checkouts
    if [ "$detect" = "-" ] || [ -d "$(expand_tilde "$detect")" ]; then
      printf '%s\t%s\n' "$content" "$(expand_tilde "$dest")"
    fi
  done < "$TSV"
}

units() {  # $1 = content type; stdout: name<TAB>absolute_source
  local d f
  case "$1" in
    skills)
      for d in "$REPO_DIR"/skills/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        printf '%s\t%s\n' "$(basename "$d")" "$d"
      done ;;
    agents|commands)
      for f in "$REPO_DIR/$1"/*.md; do
        [ -f "$f" ] || continue
        printf '%s\t%s\n' "$(basename "$f")" "$f"
      done ;;
    *) die "harnesses.tsv: unknown content type '$1'" ;;
  esac
}

planned() {  # stdout: src<TAB>dest for every active row x unit
  active_rows | while IFS=$'\t' read -r content dest_dir; do
    units "$content" | while IFS=$'\t' read -r name src; do
      printf '%s\t%s\n' "$src" "$dest_dir/$name"
    done
  done
}

ensure_dir() {  # create $1, recording each newly created level in the receipt
  local d="$1"
  [ -d "$d" ] && return 0
  ensure_dir "$(dirname "$d")"
  note "mkdir: $d"
  if [ "$DRY" = 0 ]; then
    receipt_append dir - "$d"   # append-before-act: a crash never strands an unrecorded dir
    [ -d "$d" ] || mkdir "$d"   # receipt bootstrap may have just created this very dir
  fi
}

receipt_append() {  # mode src dest
  [ "$DRY" = 1 ] && return 0
  if [ ! -f "$RECEIPT" ]; then
    mkdir -p "$RECEIPT_DIR"   # unrecorded by design; uninstall prunes it explicitly
    printf '%s\n' "$RECEIPT_HEADER" > "$RECEIPT"
  fi
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RECEIPT"
}

remove_path() {  # link-aware delete: a link is removed as an object, never traversed
  local p="$1"
  if [ -L "$p" ]; then rm "$p"
  elif [ -d "$p" ]; then rm -rf "$p"
  elif [ -e "$p" ]; then rm -f "$p"
  fi
}

install_unit() {  # src dest
  local src="$1" dest="$2"
  ensure_dir "$(dirname "$dest")"
  note "install ($MODE): $src -> $dest"
  [ "$DRY" = 1 ] && return 0
  receipt_append "$MODE" "$src" "$dest"   # before install: crash never strands an owned dest
  remove_path "$dest"
  if [ "$MODE" = link ]; then
    ln -s "$src" "$dest"
    [ -L "$dest" ] || die "symlink not created at $dest — in Git Bash set MSYS=winsymlinks:nativestrict, or use install.ps1 -Link"
  else
    if [ -d "$src" ]; then cp -R "$src" "$dest"; else cp "$src" "$dest"; fi
  fi
}

do_install() {
  local src dest
  while IFS=$'\t' read -r src dest; do
    install_unit "$src" "$dest"
  done <<EOF_PLAN
$(planned)
EOF_PLAN
}

main() {
  [ -f "$TSV" ] || die "missing $TSV"
  check_disjoint
  if [ "$ACTION" = install ]; then
    report_skips
    do_install
  else
    die "uninstall not implemented yet"
  fi
  [ "$STATUS" = 2 ] && note "completed with skips (rerun with --force to claim them)"
  exit "$STATUS"
}

main
```

- [ ] **Step 6: Set the exec bits, then run tests to verify pass** — `chmod +x install.sh tests/installer/*.sh && /bin/bash tests/installer/run_sh_tests.sh`
Expected: `RESULT: ALL PASS`. If on Linux, also confirm no bash-4isms snuck in by review (CI's macOS job is the real gate). Confirm `git status`/`git diff --stat` shows the files with mode 100755 when staged.

- [ ] **Step 7: Commit**

```bash
git add .gitattributes harnesses.tsv install.sh tests/installer/
git commit -m "feat(installer): TSV routing, copy install, receipt, dry-run"
```

---

### Task 2: Idempotent re-run and orphan pruning

**Files:**
- Modify: `install.sh` (add `receipt_current`, `remove_owned`, `compact_receipt_and_prune`; call compaction from `do_install`)
- Modify: `tests/installer/run_sh_tests.sh` (two scenarios)

**Interfaces:**
- Produces: `receipt_current` (stdout: deduped `mode\tsrc\tdest`, last-line-wins per folded dest, header stripped, `dir` lines passed through), `remove_owned mode src dest` (ownership-checked delete; sets `STATUS=2` and leaves foreign-pointing links), `compact_receipt_and_prune` (deletes stale receipt dests, rewrites receipt via temp-then-rename). Tasks 3/5/6 rely on all three.

- [ ] **Step 1: Add scenarios to `run_sh_tests.sh`** (insert before `run_scenarios`, and append the two names to the `run_scenarios` call):

```bash
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
```

- [ ] **Step 2: Run to verify the new scenarios fail** — `/bin/bash tests/installer/run_sh_tests.sh`
Expected: both new scenarios FAIL — `scenario_rename_cleans_orphan` (old dest still present) and `scenario_rerun_idempotent` (3 unit lines per dest without compaction, wants exactly 2).

- [ ] **Step 3: Implement.** Add these functions to `install.sh` (after `remove_path`), and make `do_install`'s first line `compact_receipt_and_prune`:

```bash
receipt_current() {  # deduped receipt: last line per (folded) dest wins
  [ -f "$RECEIPT" ] || return 0
  awk -F'\t' -v fold="$CASE_FOLD" '
    /^#/ { next } NF < 3 { next }
    {
      key = $3; if (fold) key = tolower(key)
      line[key] = $0
      if (!(key in seen)) { order[++n] = key; seen[key] = 1 }
    }
    END { for (i = 1; i <= n; i++) print line[order[i]] }
  ' "$RECEIPT"
}

remove_owned() {  # mode src dest — dest is receipt-listed; verify link entries before deleting
  local mode="$1" src="$2" dest="$3" target
  if [ "$mode" = link ]; then
    # A link entry may only ever delete a symlink still pointing at our
    # source. If the user replaced our link with a real file/dir (or
    # repointed it), it is theirs now — leave it.
    if [ ! -L "$dest" ]; then
      if [ -e "$dest" ]; then
        note "warning: $dest is no longer our symlink — leaving it"
        STATUS=2
      fi
      return 0
    fi
    target="$(readlink "$dest")"
    if [ "$(fold "$target")" != "$(fold "$src")" ]; then
      note "warning: $dest points at '$target', not our '$src' — leaving it"
      STATUS=2
      return 0
    fi
  fi
  remove_path "$dest"
}

compact_receipt_and_prune() {
  [ -f "$RECEIPT" ] || return 0
  local planned_f tmp mode src dest
  planned_f="$(mktemp)"
  planned | cut -f2 | while IFS= read -r dest; do fold "$dest"; done > "$planned_f"
  tmp="$RECEIPT.tmp.$$"
  printf '%s\n' "$RECEIPT_HEADER" > "$tmp"
  while IFS=$'\t' read -r mode src dest; do
    [ -n "$mode" ] || continue
    if [ "$mode" = dir ] || grep -Fxq "$(fold "$dest")" "$planned_f"; then
      printf '%s\t%s\t%s\n' "$mode" "$src" "$dest" >> "$tmp"
    else
      note "remove stale: $dest"
      if [ "$DRY" = 1 ]; then
        printf '%s\t%s\t%s\n' "$mode" "$src" "$dest" >> "$tmp"
      else
        remove_owned "$mode" "$src" "$dest"
      fi
    fi
  done <<EOF_RCPT
$(receipt_current)
EOF_RCPT
  if [ "$DRY" = 1 ]; then rm -f "$tmp"; else mv "$tmp" "$RECEIPT"; fi
  rm -f "$planned_f"
}
```

- [ ] **Step 4: Run tests to verify pass** — `/bin/bash tests/installer/run_sh_tests.sh`
Expected: `RESULT: ALL PASS`.

- [ ] **Step 5: Commit** — `git add -u tests install.sh && git commit -m "feat(installer): exact re-runs — receipt compaction and orphan pruning"`

---

### Task 3: Safety rule, --force, exit code 2

**Files:**
- Modify: `install.sh` (add `is_ours`; gate `do_install`)
- Modify: `tests/installer/run_sh_tests.sh` (one scenario)

**Interfaces:**
- Produces: `is_ours dest` (returns 0 iff the receipt has a line for `dest`, folded comparison). Task 5 does not use it (uninstall trusts the receipt), but ps1 mirrors it.

- [ ] **Step 1: Add scenario** (and append its name to the `run_scenarios` call):

```bash
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
```

- [ ] **Step 2: Run to verify it fails** — expected: rc 0 instead of 2, `mine.txt` clobbered on first run.

- [ ] **Step 3: Implement.** Add after `remove_owned`:

```bash
is_ours() {  # 0 iff receipt lists $1 (folded compare); avoids grep -q under pipefail
  [ -f "$RECEIPT" ] || return 1
  local found=1 mode src dest
  while IFS=$'\t' read -r mode src dest; do
    [ -n "$dest" ] || continue
    [ "$(fold "$dest")" = "$(fold "$1")" ] && found=0
  done <<EOF_OURS
$(receipt_current)
EOF_OURS
  return "$found"
}
```

Replace `do_install` with:

```bash
do_install() {
  compact_receipt_and_prune
  local src dest
  while IFS=$'\t' read -r src dest; do
    if { [ -e "$dest" ] || [ -L "$dest" ]; } && [ "$FORCE" = 0 ] && ! is_ours "$dest"; then
      note "skip (exists, not ours — rerun with --force to claim): $dest"
      STATUS=2
      continue
    fi
    install_unit "$src" "$dest"
  done <<EOF_PLAN
$(planned)
EOF_PLAN
}
```

- [ ] **Step 4: Run all scenarios** — expected `RESULT: ALL PASS`.
- [ ] **Step 5: Commit** — `git commit -am "feat(installer): safety rule — never clobber unowned destinations; --force claims"`

---

### Task 4: --link mode — verification, link-aware replacement, mode switches

The implementation largely exists (Task 1's `install_unit`, Task 1's `remove_path`); this task proves the dangerous paths and fixes whatever the proofs flush out.

**Files:**
- Modify: `tests/installer/run_sh_tests.sh` (three scenarios)
- Modify: `install.sh` (only if a scenario fails)

**Interfaces:** none new.

- [ ] **Step 1: Add scenarios** (and append their names to the `run_scenarios` call):

```bash
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
```

- [ ] **Step 2: Run.** Expected: all three PASS if Task 1's `remove_path` is correct (`rm "$p"` on the link object, no trailing slash). If `scenario_link_then_copy_clone_intact` fails, the bug is a traversing delete — fix `remove_path`/`install_unit`, never the assertion.
- [ ] **Step 3: Commit** — `git commit -am "test(installer): link mode — verification, mode switches, clone-intact guard"`

---

### Task 5: --uninstall

**Files:**
- Modify: `install.sh` (add `do_uninstall`; wire into `main`)
- Modify: `tests/installer/run_sh_tests.sh` (four scenarios)

**Interfaces:**
- Produces: `do_uninstall` — consumes `receipt_current`, `remove_owned`, `remove_path`. Deletion order: unit entries, then the receipt file, then recorded `dir` entries deepest-first (`rmdir` only-if-empty), then `RECEIPT_DIR` itself (ours by definition — we put the receipt in it).

- [ ] **Step 1: Add scenarios** (and append their names to the `run_scenarios` call):

```bash
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
```

- [ ] **Step 2: Run to verify failure** — expected: `die "uninstall not implemented yet"` (rc 1).

- [ ] **Step 3: Implement.** Replace the `else die …` branch in `main` with `do_uninstall`, and add:

```bash
do_uninstall() {
  if [ ! -f "$RECEIPT" ]; then
    note "nothing to uninstall (no receipt at $RECEIPT)"
    return 0
  fi
  local entries mode src dest
  entries="$(receipt_current)"   # capture BEFORE deleting the receipt
  while IFS=$'\t' read -r mode src dest; do
    [ -n "$mode" ] && [ "$mode" != dir ] || continue
    note "remove: $dest"
    if [ "$DRY" = 0 ]; then
      if [ "$FORCE" = 1 ]; then remove_path "$dest"; else remove_owned "$mode" "$src" "$dest"; fi
    fi
  done <<EOF_UNITS
$entries
EOF_UNITS
  note "remove: $RECEIPT"
  [ "$DRY" = 1 ] || rm -f "$RECEIPT"
  while IFS=$'\t' read -r mode src dest; do
    [ "$mode" = dir ] || continue
    note "rmdir (if empty): $dest"
    [ "$DRY" = 1 ] || rmdir "$dest" 2>/dev/null || true
  done <<EOF_DIRS
$(printf '%s\n' "$entries" | awk -F'\t' '$1=="dir" { print length($3) "\t" $0 }' | sort -rn | cut -f2-)
EOF_DIRS
  [ "$DRY" = 1 ] || rmdir "$RECEIPT_DIR" 2>/dev/null || true
}
```

- [ ] **Step 4: Run all scenarios** — expected `RESULT: ALL PASS`.
- [ ] **Step 5: Commit** — `git commit -am "feat(installer): receipt-driven uninstall with empty-dir pruning"`

---

### Task 6: install.ps1 and its test harness

A function-for-function port. Behavior must match `install.sh` exactly (same flags, same receipt format, same exit codes, same output words the tests grep for).

**Files:**
- Create: `install.ps1`
- Create: `tests/installer/run_ps1_tests.ps1`

**Interfaces:**
- Consumes: `harnesses.tsv`, content globs — identical semantics to Task 1.
- Produces: `install.ps1` with `-Link -Uninstall -DryRun -Force` switches. Test harness mirrors every `run_sh_tests.sh` scenario, plus a symlink capability probe that skips link scenarios (with a printed notice) where the runner can't create symlinks.

- [ ] **Step 1: Write `tests/installer/run_ps1_tests.ps1`:**

```powershell
# Scenario tests for install.ps1 — mirrors run_sh_tests.sh.
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Fail = 0

function Setup-Scratch {
  $script:Scratch = Join-Path ([IO.Path]::GetTempPath()) ("aitool-" + [Guid]::NewGuid().ToString('N'))
  $script:Repo = Join-Path $Scratch 'repo'
  $script:H    = Join-Path $Scratch 'home'
  New-Item -ItemType Directory -Path $Scratch | Out-Null
  Copy-Item -LiteralPath $RepoRoot -Destination $Repo -Recurse
  New-Item -ItemType Directory -Path (Join-Path $H '.claude') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $H '.codex')  -Force | Out-Null
  $env:AI_TOOLING_HOME = $H
  $script:Receipt = Join-Path $H '.agents\.ai-tooling-receipt'
}

function Run-Installer {
  param([string[]]$Flags = @())
  # Localized EAP: under 'Stop', native stderr routed through 2>&1 can raise
  # NativeCommandError in WinPS 5.1 and abort the whole suite mid-run.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $script:Out = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'install.ps1') @Flags 2>&1 | Out-String)
  $script:Rc = $LASTEXITCODE
  $ErrorActionPreference = $prev
}

function Expected-Dests {  # independent re-derivation from TSV + globs
  $rows = Get-Content -LiteralPath (Join-Path $Repo 'harnesses.tsv') |
    Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^#' }
  foreach ($row in $rows) {
    $f = $row -split "`t"
    $detect = $f[1] -replace '^~', $env:AI_TOOLING_HOME -replace '/', '\'
    $dest   = $f[2] -replace '^~', $env:AI_TOOLING_HOME -replace '/', '\'
    if ($f[1] -ne '-' -and -not (Test-Path -LiteralPath $detect)) { continue }
    if ($f[0] -eq 'skills') {
      Get-ChildItem -LiteralPath (Join-Path $Repo 'skills') -Directory |
        ForEach-Object { Join-Path $dest $_.Name }
    } else {
      Get-ChildItem -LiteralPath (Join-Path $Repo $f[0]) -Filter *.md -File |
        ForEach-Object { Join-Path $dest $_.Name }
    }
  }
}

function A-Fail($m)        { Write-Output "ASSERT FAILED: $m"; $script:Fail = 1 }
function Assert-Exists($p)  { if (-not (Test-Path -LiteralPath $p)) { A-Fail "exists: $p" } }
function Assert-Missing($p) { if (Test-Path -LiteralPath $p) { A-Fail "missing: $p" } }
function Assert-Rc($want)   { if ($Rc -ne $want) { A-Fail "rc: want $want got $Rc — output: $Out" } }
function Assert-Contains($needle) { if ($Out -notlike "*$needle*") { A-Fail "contains '$needle' in: $Out" } }
function Test-IsLinkPath($p) {
  try { $a = [IO.File]::GetAttributes($p) } catch { return $false }
  return [bool]($a -band [IO.FileAttributes]::ReparsePoint)
}
function Assert-Symlink($p)    { if (-not (Test-IsLinkPath $p)) { A-Fail "symlink: $p" } }
function Assert-NotSymlink($p) { if (Test-IsLinkPath $p) { A-Fail "not-symlink: $p" } }

function Can-Symlink {
  $probe = Join-Path ([IO.Path]::GetTempPath()) ("lnprobe-" + [Guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType SymbolicLink -Path $probe -Value ([IO.Path]::GetTempPath()) -ErrorAction Stop | Out-Null
    [IO.Directory]::Delete($probe, $false)
    return $true
  } catch { return $false }
}

function Scenario-DryRunTouchesNothing {
  Setup-Scratch
  Run-Installer @('-DryRun')
  Assert-Rc 0
  Assert-Missing $Receipt
  Expected-Dests | ForEach-Object { Assert-Missing $_ }
  Assert-Contains 'install (copy)'
}

function Scenario-FreshInstall {
  Setup-Scratch
  Run-Installer
  Assert-Rc 0
  Expected-Dests | ForEach-Object { Assert-Exists $_ }
  Assert-Exists $Receipt
  if ((Get-Content -LiteralPath $Receipt -TotalCount 1) -ne '# ai-tooling-receipt v1') { A-Fail 'receipt header' }
  Assert-Exists (Join-Path $H '.agents\skills\test-docs\SKILL.md')
}

function Scenario-RerunIdempotent {
  Setup-Scratch
  Run-Installer; Assert-Rc 0
  Run-Installer; Assert-Rc 0
  Expected-Dests | ForEach-Object { Assert-Exists $_ }
}

function Scenario-RenameCleansOrphan {
  Setup-Scratch
  Run-Installer; Assert-Rc 0
  Rename-Item -LiteralPath (Join-Path $Repo 'skills\test-docs') 'test-docs-renamed'
  Run-Installer; Assert-Rc 0
  Assert-Missing (Join-Path $H '.agents\skills\test-docs')
  Assert-Exists  (Join-Path $H '.agents\skills\test-docs-renamed')
}

function Scenario-ForeignDestSkippedThenForced {
  Setup-Scratch
  $foreign = Join-Path $H '.agents\skills\test-docs'
  New-Item -ItemType Directory -Path $foreign -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $foreign 'mine.txt') -Value 'precious'
  Run-Installer
  Assert-Rc 2
  Assert-Exists (Join-Path $foreign 'mine.txt')
  Assert-Exists (Join-Path $H '.claude\skills\test-docs\SKILL.md')
  Assert-Contains 'skip (exists, not ours'
  Run-Installer @('-Force')
  Assert-Rc 0
  Assert-Missing (Join-Path $foreign 'mine.txt')
  Assert-Exists  (Join-Path $foreign 'SKILL.md')
}

function Scenario-LinkInstall {
  Setup-Scratch
  Run-Installer @('-Link')
  Assert-Rc 0
  Assert-Symlink (Join-Path $H '.agents\skills\test-docs')
  Assert-Symlink (Join-Path $H '.claude\agents\doc-follower.md')
}

function Scenario-LinkThenCopyCloneIntact {
  Setup-Scratch
  Run-Installer @('-Link'); Assert-Rc 0
  Run-Installer;            Assert-Rc 0
  Assert-NotSymlink (Join-Path $H '.agents\skills\test-docs')
  Assert-Exists (Join-Path $H '.agents\skills\test-docs\SKILL.md')
  Assert-Exists (Join-Path $Repo 'skills\test-docs\SKILL.md')   # clone intact
  Assert-Exists (Join-Path $Repo 'agents\doc-follower.md')
}

function Scenario-CopyThenLink {
  Setup-Scratch
  Run-Installer;            Assert-Rc 0
  Run-Installer @('-Link'); Assert-Rc 0
  Assert-Symlink (Join-Path $H '.agents\skills\test-docs')
}

function Scenario-LinkUninstallClean {
  Setup-Scratch
  Run-Installer @('-Link');      Assert-Rc 0
  Run-Installer @('-Uninstall'); Assert-Rc 0
  Expected-Dests | ForEach-Object { Assert-Missing $_ }
  Assert-Missing $Receipt
  Assert-Missing (Join-Path $H '.agents')
}

function Scenario-UninstallSkipsForeignLink {
  Setup-Scratch
  Run-Installer @('-Link'); Assert-Rc 0
  $d = Join-Path $H '.agents\skills\test-docs'
  [IO.Directory]::Delete($d, $false)              # remove our link object
  New-Item -ItemType SymbolicLink -Path $d -Value $Scratch | Out-Null
  Run-Installer @('-Uninstall')
  Assert-Rc 2
  Assert-Symlink $d
  Assert-Contains 'leaving it'
}

function Scenario-UninstallLeavesReplacedLinkDest {
  Setup-Scratch
  Run-Installer @('-Link'); Assert-Rc 0
  $d = Join-Path $H '.agents\skills\test-docs'
  [IO.Directory]::Delete($d, $false)              # remove our link object
  New-Item -ItemType Directory -Path $d | Out-Null
  Set-Content -LiteralPath (Join-Path $d 'user-data.txt') -Value 'precious'
  Run-Installer @('-Uninstall')
  Assert-Rc 2
  Assert-Exists (Join-Path $d 'user-data.txt')    # never rm -rf'd
  Assert-Contains 'no longer our symlink'
}

function Scenario-UninstallLeavesNothing {
  Setup-Scratch
  Run-Installer; Assert-Rc 0
  Run-Installer @('-Uninstall'); Assert-Rc 0
  Expected-Dests | ForEach-Object { Assert-Missing $_ }
  Assert-Missing $Receipt
  Assert-Missing (Join-Path $H '.agents')
  Assert-Exists  (Join-Path $H '.claude')
}

function Scenario-UninstallDryRun {
  Setup-Scratch
  Run-Installer; Assert-Rc 0
  Run-Installer @('-Uninstall', '-DryRun'); Assert-Rc 0
  Assert-Exists $Receipt
  Expected-Dests | ForEach-Object { Assert-Exists $_ }
}

$scenarios = @(
  'Scenario-DryRunTouchesNothing', 'Scenario-FreshInstall',
  'Scenario-RerunIdempotent', 'Scenario-RenameCleansOrphan',
  'Scenario-ForeignDestSkippedThenForced',
  'Scenario-UninstallLeavesNothing', 'Scenario-UninstallDryRun'
)
if (Can-Symlink) {
  $scenarios += @(
    'Scenario-LinkInstall', 'Scenario-LinkThenCopyCloneIntact',
    'Scenario-CopyThenLink', 'Scenario-LinkUninstallClean',
    'Scenario-UninstallSkipsForeignLink', 'Scenario-UninstallLeavesReplacedLinkDest'
  )
} else {
  Write-Output 'NOTICE: symlinks unavailable on this runner — link scenarios skipped'
}
foreach ($s in $scenarios) { Write-Output "== $s"; & $s }
if ($script:Fail -ne 0) { Write-Output 'RESULT: FAIL'; exit 1 }
Write-Output 'RESULT: ALL PASS'
```

- [ ] **Step 2: Write `install.ps1` (complete file):**

```powershell
# ai-tooling installer — native Windows (Windows PowerShell 5.1+).
# Function-for-function port of install.sh; harnesses.tsv is shared.
# Spec: docs/superpowers/specs/2026-07-08-installer-design.md
[CmdletBinding()]
param(
  [switch]$Link,
  [switch]$Uninstall,
  [switch]$DryRun,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HomeDir = if ($env:AI_TOOLING_HOME) { $env:AI_TOOLING_HOME } else { $env:USERPROFILE }
$Tsv = Join-Path $RepoDir 'harnesses.tsv'
$ReceiptDir = Join-Path $HomeDir '.agents'
$Receipt = Join-Path $ReceiptDir '.ai-tooling-receipt'
$ReceiptHeader = '# ai-tooling-receipt v1'
$Mode = if ($Link) { 'link' } else { 'copy' }
$script:Status = 0

function Note($m) { Write-Output $m }
function Fail-Hard($m) { Write-Output "error: $m"; exit 1 }
function Fold($s) { "$s".ToLowerInvariant() }   # Windows: always case-insensitive

function Expand-Dest($p) {
  $p = $p -replace '/', '\'
  if ($p -eq '~') { return $HomeDir }
  if ($p.StartsWith('~\')) { return (Join-Path $HomeDir $p.Substring(2)) }
  return $p
}

function Get-Rows {
  Get-Content -LiteralPath $Tsv | ForEach-Object {
    if ($_ -match '^\s*$' -or $_ -match '^#') { return }
    $f = $_ -split "`t"
    if ($f.Count -lt 3 -or -not $f[1] -or -not $f[2]) { Fail-Hard "harnesses.tsv: malformed row: $_" }
    [pscustomobject]@{ Content = $f[0]; Detect = $f[1]; Dest = (Expand-Dest $f[2]) }
  }
}

function Check-Disjoint {
  $dests = @(Get-Rows | ForEach-Object { $_.Dest })
  $dups = $dests | Group-Object { Fold $_ } | Where-Object { $_.Count -gt 1 }
  if ($dups) { Fail-Hard ("harnesses.tsv: duplicate dest: " + $dups[0].Name) }
  foreach ($a in $dests) { foreach ($b in $dests) {
    if ($a -ne $b -and (Fold "$a\").StartsWith((Fold "$b\"))) {
      Fail-Hard "harnesses.tsv: dest '$a' lies inside dest '$b'"
    }
  } }
}

function Report-Skips {  # harness-detection report: names every found AND skipped detect dir
  Get-Rows | ForEach-Object {
    if ($_.Detect -eq '-') { return }
    $d = Expand-Dest $_.Detect
    if (Test-Path -LiteralPath $d -PathType Container) {
      Note ("found: $d (" + $_.Content + " will be installed)")
    } else {
      Note ("skipped: $d not found (no " + $_.Content + " for that harness)")
    }
  }
}

function Get-ActiveRows {
  Get-Rows | Where-Object {
    $_.Detect -eq '-' -or (Test-Path -LiteralPath (Expand-Dest $_.Detect) -PathType Container)
  }
}

function Get-Units($content) {
  switch ($content) {
    'skills' {
      Get-ChildItem -LiteralPath (Join-Path $RepoDir 'skills') -Directory -ErrorAction SilentlyContinue
    }
    { $_ -in 'agents', 'commands' } {
      Get-ChildItem -LiteralPath (Join-Path $RepoDir $content) -Filter *.md -File -ErrorAction SilentlyContinue
    }
    default { Fail-Hard "harnesses.tsv: unknown content type '$content'" }
  }
}

function Get-Planned {
  foreach ($row in Get-ActiveRows) {
    foreach ($u in @(Get-Units $row.Content)) {
      [pscustomobject]@{ Src = $u.FullName; Dest = (Join-Path $row.Dest $u.Name) }
    }
  }
}

function Test-IsLinkPath($p) {
  try { $a = [IO.File]::GetAttributes($p) } catch { return $false }
  return [bool]($a -band [IO.FileAttributes]::ReparsePoint)
}

function Test-PathAny($p) {  # true for files, dirs, AND dangling links
  if (Test-Path -LiteralPath $p) { return $true }
  return (Test-IsLinkPath $p)
}

function Remove-PathSafe($p) {  # link-aware: a link is removed as an object, never traversed
  try { $a = [IO.File]::GetAttributes($p) } catch { return }
  $isLink = [bool]($a -band [IO.FileAttributes]::ReparsePoint)
  $isDir  = [bool]($a -band [IO.FileAttributes]::Directory)
  if ($isLink) {
    if ($isDir) { [IO.Directory]::Delete($p, $false) } else { [IO.File]::Delete($p) }
  } elseif ($isDir) {
    Remove-Item -LiteralPath $p -Recurse -Force
  } else {
    Remove-Item -LiteralPath $p -Force
  }
}

function Get-LinkTarget($p) {
  try { return (Get-Item -LiteralPath $p -Force).Target | Select-Object -First 1 } catch { return $null }
}

function Ensure-Dir($d) {
  if (Test-Path -LiteralPath $d -PathType Container) { return }
  Ensure-Dir (Split-Path -Parent $d)
  Note "mkdir: $d"
  if (-not $DryRun) {
    Receipt-Append 'dir' '-' $d   # append-before-act
    if (-not (Test-Path -LiteralPath $d -PathType Container)) {
      New-Item -ItemType Directory -Path $d | Out-Null
    }
  }
}

function Receipt-Append($mode, $src, $dest) {
  if ($DryRun) { return }
  if (-not (Test-Path -LiteralPath $Receipt)) {
    New-Item -ItemType Directory -Path $ReceiptDir -Force | Out-Null  # unrecorded by design
    Set-Content -LiteralPath $Receipt -Value $ReceiptHeader -Encoding UTF8
  }
  Add-Content -LiteralPath $Receipt -Value ("{0}`t{1}`t{2}" -f $mode, $src, $dest) -Encoding UTF8
}

function Receipt-Current {  # deduped: last line per folded dest wins; order preserved
  if (-not (Test-Path -LiteralPath $Receipt)) { return @() }
  $map = @{}; $order = New-Object System.Collections.ArrayList
  foreach ($line in Get-Content -LiteralPath $Receipt) {
    if ($line -match '^#') { continue }
    $f = $line -split "`t"
    if ($f.Count -lt 3) { continue }
    $key = Fold $f[2]
    if (-not $map.ContainsKey($key)) { [void]$order.Add($key) }
    $map[$key] = [pscustomobject]@{ Mode = $f[0]; Src = $f[1]; Dest = $f[2] }
  }
  foreach ($k in $order) { $map[$k] }
}

function Remove-Owned($mode, $src, $dest) {
  if ($mode -eq 'link') {
    # A link entry may only ever delete a symlink still pointing at our
    # source. A real file/dir at that path is the user's now.
    if (-not (Test-IsLinkPath $dest)) {
      if (Test-Path -LiteralPath $dest) {
        Note "warning: $dest is no longer our symlink — leaving it"
        $script:Status = 2
      }
      return
    }
    $target = Get-LinkTarget $dest
    if (-not $target -or (Fold $target) -ne (Fold $src)) {
      Note "warning: $dest points at '$target', not our '$src' — leaving it"
      $script:Status = 2
      return
    }
  }
  Remove-PathSafe $dest
}

function Is-Ours($dest) {
  foreach ($e in @(Receipt-Current)) {
    if ((Fold $e.Dest) -eq (Fold $dest)) { return $true }
  }
  return $false
}

function Compact-ReceiptAndPrune {
  if (-not (Test-Path -LiteralPath $Receipt)) { return }
  $plannedDests = @{}
  foreach ($p in @(Get-Planned)) { $plannedDests[(Fold $p.Dest)] = $true }
  $keep = New-Object System.Collections.ArrayList
  foreach ($e in @(Receipt-Current)) {
    if ($e.Mode -eq 'dir' -or $plannedDests.ContainsKey((Fold $e.Dest))) {
      [void]$keep.Add($e)
    } else {
      Note ("remove stale: " + $e.Dest)
      if ($DryRun) { [void]$keep.Add($e) } else { Remove-Owned $e.Mode $e.Src $e.Dest }
    }
  }
  if ($DryRun) { return }
  $tmp = "$Receipt.tmp.$PID"
  Set-Content -LiteralPath $tmp -Value $ReceiptHeader -Encoding UTF8
  foreach ($e in $keep) {
    Add-Content -LiteralPath $tmp -Value ("{0}`t{1}`t{2}" -f $e.Mode, $e.Src, $e.Dest) -Encoding UTF8
  }
  Move-Item -LiteralPath $tmp -Destination $Receipt -Force
}

function New-Link($src, $dest) {
  try {
    New-Item -ItemType SymbolicLink -Path $dest -Value $src -ErrorAction Stop | Out-Null
  } catch {
    # PS 5.1 ignores Developer Mode; cmd's mklink honors it.
    if (Test-Path -LiteralPath $src -PathType Container) {
      cmd /c mklink /D "`"$dest`"" "`"$src`"" 2>&1 | Out-Null
    } else {
      cmd /c mklink "`"$dest`"" "`"$src`"" 2>&1 | Out-Null
    }
  }
  if (-not (Test-IsLinkPath $dest)) {
    Fail-Hard "could not create symlink at $dest — enable Developer Mode, run elevated, or use copy mode"
  }
}

function Install-Unit($src, $dest) {
  Ensure-Dir (Split-Path -Parent $dest)
  Note "install ($Mode): $src -> $dest"
  if ($DryRun) { return }
  Receipt-Append $Mode $src $dest   # before install: crash never strands an owned dest
  Remove-PathSafe $dest
  if ($Mode -eq 'link') {
    New-Link $src $dest
  } else {
    Copy-Item -LiteralPath $src -Destination $dest -Recurse
  }
}

function Do-Install {
  Compact-ReceiptAndPrune
  foreach ($p in @(Get-Planned)) {
    if ((Test-PathAny $p.Dest) -and -not $Force -and -not (Is-Ours $p.Dest)) {
      Note ("skip (exists, not ours — rerun with -Force to claim): " + $p.Dest)
      $script:Status = 2
      continue
    }
    Install-Unit $p.Src $p.Dest
  }
}

function Do-Uninstall {
  if (-not (Test-Path -LiteralPath $Receipt)) {
    Note "nothing to uninstall (no receipt at $Receipt)"
    return
  }
  $entries = @(Receipt-Current)   # capture BEFORE deleting the receipt
  foreach ($e in $entries) {
    if ($e.Mode -eq 'dir') { continue }
    Note ("remove: " + $e.Dest)
    if (-not $DryRun) {
      if ($Force) { Remove-PathSafe $e.Dest } else { Remove-Owned $e.Mode $e.Src $e.Dest }
    }
  }
  Note "remove: $Receipt"
  if (-not $DryRun) { Remove-Item -LiteralPath $Receipt -Force }
  $dirs = $entries | Where-Object { $_.Mode -eq 'dir' } |
    Sort-Object { $_.Dest.Length } -Descending
  foreach ($e in $dirs) {
    Note ("rmdir (if empty): " + $e.Dest)
    if (-not $DryRun) {
      try { [IO.Directory]::Delete($e.Dest, $false) } catch { }
    }
  }
  if (-not $DryRun) {
    try { [IO.Directory]::Delete($ReceiptDir, $false) } catch { }
  }
}

if (-not (Test-Path -LiteralPath $Tsv)) { Fail-Hard "missing $Tsv" }
Check-Disjoint
if ($Uninstall) {
  Do-Uninstall
} else {
  Report-Skips
  Do-Install
}
if ($script:Status -eq 2) { Note 'completed with skips (rerun with -Force to claim them)' }
exit $script:Status
```

- [ ] **Step 3: Local verification (best-effort — Windows CI in Task 7 is the authoritative gate).** The test harness invokes `powershell`, which only exists on Windows, so the full ps1 suite cannot run on the dev Mac. If `pwsh` is installed (`command -v pwsh`), do a syntax + dry-run check of the installer itself in a scratch checkout: `cd "$(mktemp -d)" && cp -R <repo> repo && AI_TOOLING_HOME=$PWD/home pwsh -NoProfile -File repo/install.ps1 -DryRun`. Expected: prints the plan, touches nothing, exits 0. If `pwsh` is absent, state that in the task report and rely on CI. Either way, run `/bin/bash tests/installer/run_sh_tests.sh` to confirm the bash side didn't regress — expected `RESULT: ALL PASS`.

- [ ] **Step 4: Commit** — `git add install.ps1 tests/installer/run_ps1_tests.ps1 && git commit -m "feat(installer): install.ps1 port + PowerShell scenario suite"`

---

### Task 7: CI workflow

**Files:**
- Create: `.github/workflows/installer-tests.yml`

**Interfaces:** consumes the two test entry points from Tasks 1–6.

- [ ] **Step 1: Write the workflow:**

```yaml
name: installer-tests
on:
  push:
    branches: [main]   # PRs covered by pull_request; avoids double-runs
  pull_request:

jobs:
  bash:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      # /bin/bash on the macOS runner is 3.2 — the compatibility target.
      - run: /bin/bash tests/installer/run_sh_tests.sh

  windows:
    runs-on: windows-latest
    defaults:
      run:
        shell: powershell   # Windows PowerShell 5.1, NOT pwsh — the stated target
    steps:
      - uses: actions/checkout@v4
      - run: .\tests\installer\run_ps1_tests.ps1
```

- [ ] **Step 2: Verify locally what can be verified** — `uvx --from yamllint yamllint .github/workflows/installer-tests.yml` (or skip if offline) and `/bin/bash tests/installer/run_sh_tests.sh` once more.
- [ ] **Step 3: Commit and push the branch** (mint the dispatch-bot token first: `eval "$(dispatch mint-token 2>/dev/null)" || true`), then push and watch the run non-interactively: `git push -u origin claude/installer && sleep 10 && gh run watch $(gh run list -L1 --json databaseId -q '.[0].databaseId') --exit-status` — all three jobs green. (Note: with `on: push` limited to `main`, the branch run appears once the PR is opened; alternatively open the PR first, then watch.) If the Windows job fails, fix forward in this task; the ps1 suite has never truly run before this step.
Expected: three green jobs.
- [ ] **Step 4: Commit any CI-driven fixes** — `git commit -am "fix(installer): windows CI fixes"` (only if needed).

---

### Task 8: README rewrite + real-machine sanity check

**Files:**
- Modify: `README.md` (replace the entire `## Installing (Claude Code)` section)

**Interfaces:** none — documentation.

- [ ] **Step 1: Replace the `## Installing (Claude Code)` section of README.md with:**

```markdown
## Installing

Clone the repo, then from its root:

| Platform | Command |
|---|---|
| Linux / macOS / Git Bash | `./install.sh` |
| Windows (PowerShell) | `.\install.ps1` |

That copies every skill, agent, and command into the right place for each
agent harness found on your machine. Re-run after a `git pull` to update —
re-runs are exact: renamed or removed content is cleaned up, not orphaned.

| Flag (sh / ps1) | Effect |
|---|---|
| `--link` / `-Link` | Symlink from your clone instead of copying, so the clone stays the source of truth. On Windows this needs Developer Mode or an elevated shell. |
| `--uninstall` / `-Uninstall` | Remove everything the installer put down — and nothing else. |
| `--dry-run` / `-DryRun` | Show what would happen, including which harnesses were detected. |
| `--force` / `-Force` | Claim a destination that already existed before the installer ran. Without it, such paths are warned about and skipped (exit code 2). |

### Where things go

Routing lives in [`harnesses.tsv`](harnesses.tsv) — content types map to
destinations per detected harness:

- **Skills** go to `~/.agents/skills/` (the cross-harness location Codex CLI
  and friends scan) **and** to `~/.claude/skills/` when Claude Code is
  present — verified 2026-07-08: current Claude Code does *not* read the
  universal location.
- **Agents** go to `~/.claude/agents/` (Claude Code only).
- **Commands** go to `~/.codex/prompts/` when Codex CLI is present.
  *Reported but not yet verified against a live Codex install.* No commands
  are installed for Claude Code: skills already register the slash command
  there, and the names would collide.

Installed **copies are owned by the installer** — local edits to them are
discarded on update and uninstall. To customize content, fork the repo or
install with `--link` against your own clone.

On Windows, pick one script and stick with it: Git Bash's `install.sh` and
PowerShell's `install.ps1` record paths differently and cannot manage each
other's installs.

Adding a harness later is one line in `harnesses.tsv`; adding new content
is zero lines — the installer globs `skills/`, `agents/`, and `commands/`
at runtime.
```

- [ ] **Step 2: Sanity check on the real machine (read-only):** `./install.sh --dry-run` from the repo root **without** `AI_TOOLING_HOME` set. Expected: **exit code 2**, not 0 — Tom's pre-existing `~/.claude/skills/test-docs` and `~/.claude/agents/doc-follower.md` symlinks (the old manual install) are correctly reported as `skip (exists, not ours…)`; that is the safety rule working, not a bug. Also expected: `found:` lines for `~/.claude` and `~/.codex`, planned installs listed into the real `~/.agents/skills`, and nothing created (verify: `ls ~/.agents/.ai-tooling-receipt` → still absent). Do NOT run a real install; leave Tom's setup alone.
- [ ] **Step 3: Run both test suites one final time** — expected all green.
- [ ] **Step 4: Commit** — `git add README.md && git commit -m "docs: installer README — one-command install, flags, routing"`
- [ ] **Step 5: Open the PR** (dispatch-bot token, base `main`, head `claude/installer`). Body: summary, link to spec, note the two still-unverified Codex claims and the Windows CI evidence.

---

## Post-plan notes for the executor

- Known cosmetic issue, accepted: under `--dry-run` on a fresh home, `mkdir:` lines repeat per unit (nothing is actually created, so the "already exists" suppression never kicks in).
- If any scenario fails on macOS but passes on Linux, suspect bash 3.2 (`set -u` + empty arrays, `${var,,}`) or BSD vs GNU userland (`sed -i`, `readlink -f` — neither is used; keep it that way).
- The `commands → ~/.codex/prompts` row ships unverified (no Codex CLI available). Do not silently drop it; the README marks it.
- Accepted, not fixed: PS 5.1 `Remove-Item -Recurse` on a **non-link** directory can traverse symlinks the user planted *inside* an installed copy. Reachable only via user-modified installed copies, which the README declares discardable.
- Git Bash `install.sh` and `install.ps1` must not co-manage one machine (different path styles in the same receipt); the README says pick one.
- Test scratch dirs accumulate under the system temp dir; harmless locally, and CI runners are ephemeral.
