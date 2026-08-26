---
name: implement-issue-with-review
description: Implement one approved issue with issue-worker-tdd, then run a no-edit reviewer focused on correctness, scope drift, and behavior-focused tests.
---

## issue-worker-tdd
output: false
progress: false

Implement `{task}`.

Priorities:
- Treat `{task}` as the target issue path or issue description.
- Read `PLANS/<slug>/issues/index.md` and the target issue file first.
- Stay strictly within that issue's scope and shared contracts.
- Follow strict red-green-refactor behavior-focused TDD.

## reviewer
output: false
progress: false

Review the current diff produced while implementing `{task}`.

Priorities:
- Inspect the changed files and tests directly.
- Focus on correctness/regressions, issue-scope drift, and test quality.
- Flag tests that assert implementation details instead of behavior.
- Prefer concise evidence-backed findings with file references.
- Do not edit files; review only.
