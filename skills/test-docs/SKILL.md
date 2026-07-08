---
name: test-docs
description: Use when asked to test, validate, or harden a repository's documentation — before a release, after doc changes, when onboarding feedback says the quickstart is broken, or to answer "can a new user actually follow the README?"
---

# Test Docs

Simulate a brand-new user following the documentation, fix the docs where
they get stuck, and repeat until the docs alone are sufficient. Ship the
fixes as a pull request whose description is the log of what was broken.

## Roles

- **You (the orchestrator)** — a full-capability agent. You read source
  freely, judge findings, author doc fixes, and manage git.
- **doc-follower** — a naive tester run on the cheapest available model with
  a fresh context every iteration. It follows the docs literally and reports
  stuck-points. **REQUIRED companion:** the `doc-follower` agent definition
  (agents/doc-follower.md in this toolkit).

## Setup (once)

1. **Target + goal.** Confirm the repo and the user goal(s) to test.
   Default: the README quickstart, end to end.
2. **Success criterion.** Make it observable before the first run: a command
   exits 0, a server answers on a port, a file appears. Write it down.
3. **Pocket contents.** List what the docs legitimately expect users to
   bring (API keys, data exports, accounts) plus environment facts a real
   user's machine would have (their installed tools on PATH). Gather real or
   stand-in values. These go to the tester as *possessions*, never as
   instructions or knowledge.
4. **Workspace.** Use a fresh clone or worktree per iteration — leftover
   state (installed dependencies, migrated databases, generated files) masks
   doc gaps. A local `git clone` of the target repo is cheap; re-stage the
   pocket contents after each clone. If a fresh workspace is genuinely
   impractical (huge repo, licensed data), reset what you can and record the
   known contamination in the log.
5. **Branch.** Create a docs-fix branch in the target repo. Start an
   iteration log; it becomes the PR body.
6. **Iteration cap.** Default 5.

## The loop

1. **Spawn a fresh doc-follower** with: repo path, entry doc, goal, pocket
   contents. Fresh context every time — never tell it what previous testers
   found or how they got past anything. A tester that inherits workarounds
   stops testing the docs.
2. **On STUCK, triage before editing.** Reproduce or verify the report,
   then classify:
   - **Doc gap** — missing step, wrong command, unstated prerequisite →
     fix the docs.
   - **Code bug** — the docs are right, the software is wrong → log it,
     don't fix code under this skill; stop or move to a different goal.
   - **Tester error** — the answer IS in the docs and discoverable from the
     entry point → log as a discoverability finding; consider moving or
     linking the information rather than duplicating it.
3. **Author the minimal doc fix.** Write for the user who just hit the wall.
   Verify every claim against the actual code and behavior — you can read
   the source; the tester can't, and neither can the next reader. Commit
   with a message naming the stuck-point.
4. **Log it:** iteration number, stuck-point, classification, fix commit.
   Then clean up the tester's side effects yourself — stray servers or
   background processes, generated state your workspace strategy doesn't
   already reset. Don't trust the tester to have done it.
5. **Repeat** from step 1 — fresh workspace, fresh tester — until SUCCESS
   or the cap.

**SUCCESS only counts from a fresh workspace.** A green run in a reused
workspace is provisional: it may have passed only because an earlier
iteration installed the dependencies or seeded the database. Before
declaring the docs sufficient, rerun the goal once in a clean clone or
worktree. If that rerun gets stuck, it's a finding like any other.

## Finish

- Open a PR containing the doc-fix commits. The body is the iteration log
  (a table: iteration → stuck point → classification → fix), plus the
  success criterion and the final result stated plainly. If the cap was hit,
  unresolved blockers get their own section — never silence.
- After a SUCCESS, consider one confirmation run: a fix can introduce new
  confusion of its own.

## Common mistakes

- Passing hints to the tester ("the last run failed at X, so...") —
  invalidates the whole test.
- Fixing docs by transplanting your own expertise instead of information
  verified from the repo.
- Reusing a dirty workspace, then reporting a green run that only passed
  because iteration 1 already installed everything.
- Letting the tester's severity judgment stand — it can't tell a typo from
  an architecture gap. Triage is your job.
- Forgetting the environment is part of the docs' contract: if the tester's
  shell lacks a tool the docs assume, decide whether that's a doc gap
  ("install X first") or a pocket-contents item before calling it a finding.
