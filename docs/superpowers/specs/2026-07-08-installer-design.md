# Cross-platform installer — design

**Date:** 2026-07-08
**Status:** approved design, revised after adversarial review (same day)

## Problem

The README's install story is a pair of manual `ln -s` commands, Claude Code
only, macOS/Linux only. The repo is public; anyone cloning it on Linux,
macOS, or native Windows should be able to install everything with one
command, regardless of which agent harness(es) they run — and the installer
must keep working untouched as new skills/agents/commands are added.

## Decisions (with reasoning)

1. **Audience: anyone cloning the public repo.** Therefore: copy mode is
   the default (no symlink privileges assumed, especially on Windows), and
   update/uninstall are first-class.
2. **Harnesses at launch: Claude Code and OpenAI Codex CLI.** Others
   (Cursor, Gemini CLI, …) are added later as data rows, not code.
3. **Windows: a native `install.ps1`** (Windows PowerShell 5.1-compatible)
   alongside `install.sh`, rather than Git-Bash-only or WSL-only. The cost
   of two implementations is contained by moving all routing decisions into
   a shared data file.
4. **Architecture: universal-first hybrid, with a Claude Code
   compatibility row.** `~/.agents/skills/` is a real cross-harness
   convention (Codex CLI, Gemini CLI, Copilot CLI per July 2026 research),
   so skills install there once for spec-compliant harnesses. **But an
   empirical probe on 2026-07-08 showed current Claude Code does NOT scan
   it** (controlled test: headless session sees a skill in
   `~/.claude/skills`, not an identical one in `~/.agents/skills`). So the
   routing table also installs skills to `~/.claude/skills` when Claude
   Code is present. The Codex-side claims remain web-sourced and are gated
   on a smoke test (see Verification).
   - Rejected: per-harness mirroring only (loses free support for
     compliant harnesses we have no row for) and Claude Code plugin
     marketplace + script (two distribution stories; marketplace is
     CC-only).

## Repo additions

```
install.sh          # Linux, macOS, Git Bash
install.ps1         # native Windows (Windows PowerShell 5.1+)
harnesses.tsv       # shared routing table both scripts read
```

Content folders (`agents/`, `skills/`, `commands/`) are unchanged.

### harnesses.tsv

One row per (content type → destination) mapping. **Format rules:** fields
separated by real tab characters; comments are full lines starting with
`#` (no inline comments); destinations may contain spaces. `-` in
`detect_dir` means unconditional.

```
# content <TAB> detect_dir <TAB> dest_dir
# The '-' row is the universal agentskills location (Codex & friends).
# Claude Code verified NOT to scan it (2026-07-08), hence its own row.
# No commands row for Claude Code: skills already register the slash
# command there and the names would collide.
skills      -           ~/.agents/skills
skills      ~/.claude   ~/.claude/skills
agents      ~/.claude   ~/.claude/agents
commands    ~/.codex    ~/.codex/prompts
```

- **What goes** is never listed anywhere: both scripts glob `skills/*/`,
  `agents/*.md`, `commands/*.md` at runtime.
- Future-proofing axes are therefore independent: **new content = zero
  changes** (glob), **new harness = one TSV line** (both scripts read it).
- `install.ps1` expands `~` itself and normalizes `/` to `\` — PS 5.1 does
  not expand `~` in string or .NET path contexts.
- Rows' destination trees must be disjoint; the installer errors on a TSV
  where one row's dest lies inside another's.

## Behavior (identical across both scripts)

| Invocation | Effect |
|---|---|
| `./install.sh` / `.\install.ps1` | Copy mode (default). Idempotent: each installed unit (a skill folder, or a single agent/command `.md`) is replaced wholesale — delete the destination, re-copy — so upstream-deleted files don't linger. |
| `--link` / `-Link` | Symlink mode for people keeping a live clone as source of truth. See link rules below. |
| `--uninstall` / `-Uninstall` | Remove what we installed, nothing else (receipt-driven, below). |
| `--dry-run` / `-DryRun` | Print every action, including "skipped: ~/.codex not found", touching nothing. Combines with `--uninstall` (prints would-be deletions). Doubles as the harness-detection report. |
| `--force` / `-Force` | Claim pre-existing destinations we don't own (see safety rule). With `--uninstall`, also skips the ownership check. |

**Exit codes:** `0` clean; `2` completed but some units were skipped by the
safety rule (the summary names them and suggests `--force`); `1` hard error.

**Harness detection** = "does the TSV row's `detect_dir` exist". Rows with
`-` always apply. The end-of-run summary names each harness found/skipped.

**Home resolution:** both scripts resolve `~` through a single overridable
variable (`AI_TOOLING_HOME`, defaulting to `$HOME` / `%USERPROFILE%`). This
exists for the test suite (PS 5.1's `~` follows `HOMEDRIVE`+`HOMEPATH`, not
`USERPROFILE`, so overriding env vars alone is unreliable on Windows CI).

### Symlink rules (`--link`)

- **Never silently fall back to copying.** After creating each link,
  verify the destination actually is a symlink (`test -L` / reparse-point
  check); if it isn't, fail loudly. This catches Git Bash, where `ln -s`
  silently *copies* unless `MSYS=winsymlinks:nativestrict` is set — the
  error message names that variable and `install.ps1 -Link` as the fixes.
- **PS 5.1 cannot create symlinks unelevated even with Developer Mode**
  (the unprivileged-create flag is honored from PowerShell 6.2, not 5.1).
  `install.ps1 -Link` therefore falls back to `cmd /c mklink` (which does
  honor Developer Mode); if that also fails, stop with a one-line
  explanation: enable Developer Mode, run elevated, or use copy mode.
- **Deleting a destination that is a symlink removes the link object
  itself, never its target's contents** — no recursive delete may traverse
  a link. This is load-bearing on PS 5.1, where `Remove-Item -Recurse` on
  a directory link can delete the *target* (the user's clone), and in bash,
  where `rm -rf "$dest/"` (trailing slash) follows the link. Applies to
  update replacement, orphan cleanup, and uninstall alike — including the
  link-install-then-copy-rerun mode switch.

### The receipt

`~/.agents/.ai-tooling-receipt`, written **incrementally** — each unit's
line is appended *before* that unit is installed, so a crash mid-run never
strands owned-but-unrecorded destinations. Format, one line per installed
unit:

```
# ai-tooling-receipt v1
<mode> <TAB> <source-clone-path> <TAB> <dest-path>
```

- **Update:** a re-run first reads the receipt; any receipt dest the
  current run would not recreate (skill renamed/removed upstream) is
  deleted (link-aware, per above). Re-runs are *exact*, not merely
  additive — no orphans. A mode or clone-path change is just a
  replacement like any other.
- **Uninstall:** delete exactly the receipt dests — link entries only if
  the link still points into the recorded source clone; copy entries as
  recorded (no content check — see accepted behavior below). Then delete
  the receipt itself and prune any parent directories the installer
  created that are now empty. "Uninstall leaves nothing" means: no receipt,
  no installed units, no empty dirs of ours.
- **Missing receipt** (first run, or user deleted it): degrade gracefully
  to a plain install.
- Receipt rewrites (pruning stale lines) go through write-temp-then-rename.
- Path comparisons against the receipt are case-insensitive on macOS and
  Windows.
- The header line is a format version; a future richer format bumps it
  rather than misparsing old receipts.

**Accepted behavior (documented in README):** installed copies are owned
by the installer — hand-edits to them are discarded on update and
uninstall. People who want to modify content should fork the repo or use
`--link` against their own clone.

### Safety rule — the only destructive edge

A destination that exists but is **not in the receipt** (e.g. the user
already had their own `~/.agents/skills/test-docs`) is never overwritten:
warn, skip it, continue with everything else, exit `2` with a summary of
skips. `--force` claims those paths, which then enter the receipt.
Receipt-listed paths are ours and are replaced without ceremony.

## Testing

Same derive-everything principle: a GitHub Actions matrix
(`ubuntu-latest`, `macos-latest`, `windows-latest`) runs the real scripts
against a scratch home (`AI_TOOLING_HOME` pointed at a temp dir) and
asserts these scenarios:

1. fresh install,
2. idempotent re-run,
3. rename-cleans-orphan (rename a skill dir in the checkout, re-run, old
   name is gone),
4. safety-skip: pre-existing foreign destination → warned, skipped,
   exit `2`; then `--force` claims it,
5. link install + uninstall (ubuntu/macos; windows if the runner permits
   symlinks),
6. link-install-then-copy-rerun mode switch — asserts the clone is intact
   afterward (guards the recursive-delete-through-link hazard),
7. uninstall-leaves-nothing (per the definition above).

The expected file set is **computed in the test from the TSV + glob**, not
hardcoded — tests also need zero edits when content is added. The Windows
job must run with `shell: powershell` (Windows PowerShell 5.1), not the
runner-default `pwsh`, or the stated 5.1 target goes untested. `install.sh`
must stay bash-3.2-clean (macOS default: no `mapfile`, no associative
arrays, no `${var,,}`); the macOS job runs it with `/bin/bash` explicitly.

## Verification status (live checks, not web research)

- **Claude Code does not scan `~/.agents/skills`** — verified 2026-07-08
  by controlled probe (headless session, planted skill invisible there,
  control skill in `~/.claude/skills` visible). Hence the second skills
  row.
- **`~/.claude/{skills,agents}`** — verified in daily use.
- **Codex CLI**: `~/.codex/prompts` as the command directory, and
  `~/.agents/skills` scanning, are web-sourced only (no Codex CLI on the
  dev machine). Smoke-test before the README asserts them; until then the
  README marks them reported-but-unverified. The smoke test also checks
  whether Codex surfaces `~/.agents/skills` skills as invocables — if so,
  the same name-collision reasoning that excluded a Claude Code commands
  row may require dropping the Codex commands row too.

## Docs

The README "Installing" section is replaced with: three one-liners
(Linux/macOS, Windows, "developers: add `--link`"), a flags table, the
accepted-behavior note about hand-edits, and a short note explaining the
universal `~/.agents/skills/` location, the Claude Code compatibility row,
and why commands are skipped for Claude Code. The manual-symlink section
goes away.

## Out of scope

- Cursor / Gemini CLI / Copilot CLI rows (add later as TSV lines once
  verified).
- Claude Code plugin marketplace packaging (possible future complement).
- curl-pipe-to-shell remote install (users clone the repo; the clone is
  the distribution).
- Content hashing for ownership checks (accepted behavior above covers it).
- Locking against concurrent runs (temp-then-rename receipt writes are
  sufficient for this audience).
