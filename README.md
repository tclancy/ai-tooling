# ai-tooling

Reusable, platform-agnostic building blocks for AI coding agents: agent role
definitions, skills (multi-step workflows), and slash-command wrappers.

Everything here is plain Markdown with minimal YAML frontmatter (per the
[agent skills specification](https://agentskills.io/specification)), written
tool-neutrally so it works in — or adapts trivially to — any agent harness
that supports subagents and reusable instructions (Claude Code, Codex,
Cursor, etc.). Harnesses that don't understand a frontmatter key ignore it.

## Layout

| Folder | Contents |
|---|---|
| `agents/` | Role definitions for subagents — one file per role. The frontmatter pins name, description, and (where supported) model tier and tool access; the body is the role's system prompt. |
| `skills/` | One folder per skill, entry point `SKILL.md` — step-by-step workflows the orchestrating agent follows. |
| `commands/` | Thin slash-command wrappers that point at a skill, for harnesses with a separate commands directory. |

## What's here

### test-docs (+ doc-follower)

A loop for testing whether a repo's documentation actually works:

- **`agents/doc-follower.md`** — a deliberately naive tester, run on the
  cheapest model available. It attempts a user goal using *only* the
  documentation — never the source — and reports exactly where it got stuck.
- **`skills/test-docs/SKILL.md`** — the orchestration: spawn a fresh
  doc-follower, triage its stuck-report, fix the docs (minimally, verified
  against the source), respawn, repeat until the docs alone are sufficient,
  then open a PR whose description is the log of failures and fixes.

The two are a pair: the skill requires the agent.

## Installing

Clone the repo, then from its root:

| Platform | Command |
|---|---|
| Linux / macOS / Git Bash | `./install.sh` |
| Windows (PowerShell) | `powershell -ExecutionPolicy Bypass -File .\install.ps1` |

Windows needs the `-ExecutionPolicy Bypass` because PowerShell's default
`Restricted` policy blocks all scripts; if you downloaded the repo as a zip
rather than cloning, you may also need to `Unblock-File` the scripts first.

That copies every skill, agent, and command into the right place for each
agent harness found on your machine. Re-run after a `git pull` to update —
re-runs are exact: renamed or removed content is cleaned up, not orphaned.

| Flag (sh / ps1) | Effect |
|---|---|
| `--link` / `-Link` | Symlink from your clone instead of copying, so the clone stays the source of truth. On Windows this needs Developer Mode or an elevated shell. |
| `--uninstall` / `-Uninstall` | Remove everything the installer put down — and nothing else. |
| `--dry-run` / `-DryRun` | Show what would happen; on install it also reports which harnesses were detected. |
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
