---
name: test-docs
description: Use when asked to test, validate, or harden a repository's documentation — before a release, after doc changes, when onboarding feedback says the quickstart is broken, or to answer "can a new user actually follow the README?"
argument-hint: "[docs to test — entry doc path, served URL, or prose goal; defaults to the README quickstart]"
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
- **doc-follower, browser variant** — for docs that live inside a running
  app (help pages, in-UI copy), which the Read+Bash agent can't reach.
  Spawn a general-purpose agent with browser tools and inline the
  doc-follower rules into its prompt; its "one rule" becomes *the help
  pages plus what the app's own screens show*. Pocket contents generalize:
  an email inbox can be a shell script, a phone can be the browser tools.
  Cheapest-model caveat: in a browser, comprehension is rarely the
  bottleneck — clicking is. Read the step log to separate motor failure
  from comprehension failure before accepting a STUCK.

## Setup (once)

1. **Environment runbook.** Read `.claude/test-docs-env.md` in the target
   repo; create it if absent. It records, for this repo: how to stand the
   test environment up (pocket sources — where the real data exports and
   keys live), how to clean up (PII locations to delete, processes to kill),
   and known limitations (e.g., a credential the permission layer won't let
   you stage). Update it whenever any of those change. It carries machine
   paths and credential pointers, so keep it untracked — never in the docs PR.
   Your rig is part of the docs' contract: an orchestrator-side misconfiguration
   (a missing env var, a wrong port) manufactures findings that look exactly
   like real doc bugs — record every setting the app needs in the runbook.
2. **Target + goal.** The invocation's arguments name what to test: an
   entry doc path, a served URL (e.g. a web app's `/help/` pages — the
   runbook or you must get that server running first, and the entry point
   handed to the tester is the URL), or a prose goal. Only when no
   arguments were given, default to the README quickstart, end to end.
3. **Success criterion.** Make it observable before the first run, and make
   it test **fitness, not existence**. "Exits 0" or "the file appears" is
   the weakest acceptable bar; if the journey produces something a human
   consumes (a page, a report, an image), the criterion is a consumption
   check — open it the way a user would. If the journey mutates state,
   verify completion in the datastore, never from the tester's claim
   (claims are wrong in both directions). Write it down.
4. **Pocket contents.** List what the docs legitimately expect users to
   bring (API keys, data exports, accounts) plus environment facts a real
   user's machine would have (their installed tools on PATH). Gather real or
   stand-in values. These go to the tester as *possessions*, never as
   instructions or knowledge.
5. **Workspace.** Use a fresh clone or worktree per iteration — leftover
   state (installed dependencies, migrated databases, generated files) masks
   doc gaps. A local `git clone` of the target repo is cheap; re-stage the
   pocket contents after each clone. For stateful apps, "fresh" also means
   a fresh identity and wiped state — a new user, empty rows — not just a
   fresh clone. If a fresh workspace is genuinely impractical (huge repo,
   licensed data), reset what you can and record the known contamination
   in the log.
6. **Branch.** Create a docs-fix branch in the target repo. Start an
   iteration log; it becomes the PR body.
7. **Iteration cap.** Default 5.

## The loop

1. **Spawn a fresh doc-follower** with: repo path, entry doc, goal, pocket
   contents. Fresh context every time — never tell it what previous testers
   found or how they got past anything. A tester that inherits workarounds
   stops testing the docs. Mid-run you may resume a stuck tester with
   **tooling/motor guidance** — how to drive its own tools ("use form_input
   for text fields") — but never content the docs are supposed to teach
   ("the flag is under the expander"), and no laundered versions either
   ("try looking under expanders" when you know that's where it is). If the
   tester can't find something from the docs and screens alone, that IS the
   finding — report it, don't rescue it.
2. **On SUCCESS, render the deliverables yourself.** The tester checks
   file-exists; you check the files work. Load every generated page in a
   headless browser and check three things: console/page errors, the page's
   own content invariants (the UI it promises actually appears — serious
   breakage can throw nothing, e.g. a truncated script tag rendering as
   body text), and a screenshot you actually look at. Render **the files in the iteration workspace, before
   you clean it up** — a sibling copy of the same artifact (the operator's
   own `output/`, a deployed instance) may predate the bug and pass while
   the freshly generated one is broken. A page that exists but doesn't
   render is a finding like any other — classify it (usually a code bug),
   and the screenshot is its evidence for the PR.
3. **On STUCK, triage before editing.** Reproduce or verify the report,
   then classify — and ask the first question first, because rig failures
   impersonate every other category:
   - **Harness error** — the test rig caused it, not the repo: a browser
     extension intercepting input, the tester's tool limits, your own
     misconfigured environment presenting as a "broken" doc step. Void the
     iteration (it's not a finding), fix the rig, note it in the runbook,
     rerun.
   - **Doc gap** — missing step, wrong command, unstated prerequisite →
     fix the docs.
   - **Code bug** — the docs are right, the software is wrong → log it,
     don't fix code under this skill; stop or move to a different goal.
   - **Tester error** — the answer IS in the docs and discoverable from the
     entry point → log as a discoverability finding; consider moving or
     linking the information rather than duplicating it.

   **Same wall twice despite a fix = stop rewording.** When successive
   testers die at the same step after progressively better text — above all
   when any tester ever got through it — the information isn't the problem,
   the affordance is. Reclassify as a code/UX finding — logged, not fixed,
   same as any code bug — and end the loop for that goal rather than
   burning the cap on a paragraph that was never the problem.
4. **Author the minimal doc fix.** Write for the user who just hit the wall.
   Verify every claim against the actual code and behavior — you can read
   the source; the tester can't, and neither can the next reader. Commit
   with a message naming the stuck-point.
5. **Log it:** iteration number, stuck-point, classification, fix commit.
   Then clean up the tester's side effects yourself — stray servers or
   background processes, generated state your workspace strategy doesn't
   already reset, browser tabs that `--open`-style flags spawned in the
   user's real browser, and staged pocket data (often PII) — deliberate
   deletion, not session GC. Don't trust the tester to have done it.
6. **Repeat** from step 1 — fresh workspace, fresh tester — until SUCCESS
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
- **Screenshots of rendering bugs go in the PR.** GitHub's API can't upload
  images into a PR body, so push them to a separate evidence branch (e.g.
  `claude/test-docs-evidence`) and embed their raw.githubusercontent URLs —
  the docs PR itself stays image-free.
- Update the environment runbook (`.claude/test-docs-env.md`) with anything
  this run taught you: new pocket sources, cleanup steps, limitations hit.
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
- Accepting a green run because the output file exists. A generated page can
  be present and still broken by JavaScript errors — the first real user to
  open it hits a bug every tester "passed". Render it.
- Rendering the wrong copy: verifying stale artifacts elsewhere on the
  machine (and finding them healthy) proves nothing about what the docs
  just generated. Fresh workspace, fresh artifacts — same rule as SUCCESS.
- Re-deriving the environment from scratch (or re-hitting a known
  limitation) because the last run's knowledge lived only in that session —
  that's what the runbook is for.
