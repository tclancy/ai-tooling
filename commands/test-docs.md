---
name: test-docs
description: Test a repository's documentation by simulating a brand-new user, fixing the docs where they get stuck, and opening a PR with the fixes and a log of what was broken.
---

Follow the instructions in the `test-docs` skill (skills/test-docs/SKILL.md
in this toolkit) against the target below.

Target: $ARGUMENTS

If no target was given, ask for:

1. the repository path,
2. the user goal to test (default: the README quickstart, end to end), and
3. pocket contents — keys, data files, or accounts a real user would bring.
