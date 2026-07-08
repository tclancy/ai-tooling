# Cross-platform installer — design

**Date:** 2026-07-08
**Status:** approved (brainstormed with Tom in session)

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
3. **Windows: a native `install.ps1`** (PowerShell 5.1-compatible)
   alongside `install.sh`, rather than Git-Bash-only or WSL-only. The cost
   of two implementations is contained by moving all routing decisions into
   a shared data file.
4. **Architecture: universal-first hybrid.** Research (July 2026) found
   `~/.agents/skills/` is a real cross-harness convention — Claude Code,
   Codex CLI, Gemini CLI, and Copilot CLI all scan it (Codex as a primary
   location). It covers *skills only*; subagent definitions and slash
   commands remain per-harness. So: skills install once to the universal
   location; only the non-universal content fans out per detected harness.
   - Rejected: per-harness mirroring (N harnesses × every skill = drift on
     update) and Claude Code plugin marketplace + script (two distribution
     stories; marketplace is CC-only).

## Repo additions

```
install.sh          # Linux, macOS, Git Bash
install.ps1         # native Windows (PowerShell 5.1+)
harnesses.tsv       # shared routing table both scripts read
```

Content folders (`agents/`, `skills/`, `commands/`) are unchanged.

### harnesses.tsv

One row per (content type → destination) mapping. `#` comments allowed.

```
# content   detect_dir      dest_dir
skills      -               ~/.agents/skills        # '-' = unconditional (universal location)
agents      ~/.claude       ~/.claude/agents
commands    ~/.codex        ~/.codex/prompts
# commands deliberately NOT mapped for Claude Code: skills already
# register the slash command there and the names would collide.
```

- **What goes** is never listed anywhere: both scripts glob `skills/*/`,
  `agents/*.md`, `commands/*.md` at runtime.
- Future-proofing axes are therefore independent: **new content = zero
  changes** (glob), **new harness = one TSV line** (both scripts read it).
- The scripts contain only mechanics — detect, copy/link, record, remove —
  and should almost never change.

## Behavior (identical across both scripts)

| Invocation | Effect |
|---|---|
| `./install.sh` / `.\install.ps1` | Copy mode (default). Idempotent: each installed unit (a skill folder, or a single agent/command `.md`) is replaced wholesale — delete the destination, re-copy — so upstream-deleted files don't linger. |
| `--link` / `-Link` | Symlink mode for people keeping a live clone as source of truth. On Windows, if the link fails (no Developer Mode / admin), **stop with a one-line explanation** — suggest enabling Developer Mode or using copy mode. Never silently fall back: the user asked for links. |
| `--uninstall` / `-Uninstall` | Remove what we installed, nothing else (receipt-driven, below). |
| `--dry-run` / `-DryRun` | Print every action, including "skipped: ~/.codex not found", touching nothing. Doubles as the harness-detection report. |
| `--force` / `-Force` | Claim pre-existing destinations we don't own (see safety rule). |

**Harness detection** = "does the TSV row's `detect_dir` exist". Rows with
`-` always apply. The end-of-run summary names each harness found/skipped.

### The receipt

After installing, write `~/.agents/.ai-tooling-receipt`: every path the
installer created, one per line.

- **Update:** a re-run first reads the receipt; any receipt path the
  current run would not recreate (skill renamed/removed upstream) is
  deleted. Re-runs are *exact*, not merely additive — no orphans.
- **Uninstall:** delete exactly the receipt paths — and only if they are
  still what we put there (a symlink pointing into this repo, or a path
  the receipt claims).
- **Missing receipt** (first run, or user deleted it): degrade gracefully
  to a plain install.

### Safety rule — the only destructive edge

A destination that exists but is **not in the receipt** (e.g. the user
already had their own `~/.agents/skills/test-docs`) is never overwritten:
warn, skip it, continue with everything else, exit with a summary of
skips. `--force` claims those paths, which then enter the receipt.
Receipt-listed paths are ours and are replaced without ceremony.

## Testing

Same derive-everything principle: a GitHub Actions matrix
(`ubuntu-latest`, `macos-latest`, `windows-latest`) runs the real scripts
against a scratch `HOME` and asserts four scenarios:

1. fresh install,
2. idempotent re-run,
3. rename-cleans-orphan (rename a skill dir in the checkout, re-run, old
   name is gone),
4. uninstall-leaves-nothing.

The expected file set is **computed in the test from the TSV + glob**, not
hardcoded — tests also need zero edits when content is added. Windows CI
is the only reproducible check `install.ps1` gets (dev machine is a Mac).

**Manual smoke test before publishing README claims:** run against a real
Claude Code install (and Codex if available). Two research findings are
web-sourced, not live-verified: `~/.codex/prompts` as the Codex command
directory, and the exact `.agents/skills` scan behavior per harness. If a
claim can't be verified, the README marks it as reported-but-unverified
rather than asserting it.

## Docs

The README "Installing" section is replaced with: three one-liners
(Linux/macOS, Windows, "developers: add `--link`"), a flags table, and a
short note explaining the universal `~/.agents/skills/` location and why
commands are skipped for Claude Code. The manual-symlink section goes away.

## Out of scope

- Cursor / Gemini CLI / Copilot CLI rows (add later as TSV lines once
  verified).
- Claude Code plugin marketplace packaging (possible future complement).
- curl-pipe-to-shell remote install (users clone the repo; the clone is
  the distribution).
