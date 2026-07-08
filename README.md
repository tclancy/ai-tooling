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

## Installing (Claude Code)

Symlink into your user scope so the repo stays the source of truth:

```bash
ln -s "$(pwd)/agents/doc-follower.md" ~/.claude/agents/doc-follower.md
ln -s "$(pwd)/skills/test-docs" ~/.claude/skills/test-docs
```

Skills are directly invocable as slash commands in Claude Code, so don't
also link `commands/test-docs.md` there — the name would collide. The
`commands/` folder is for harnesses that keep commands separate from skills.
