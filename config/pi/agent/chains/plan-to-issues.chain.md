---
name: plan-to-issues
description: After plan approval, package PLANS/<project>/plan.md into worker-ready issue files with no further human interaction. You can also trigger this from the top-level session with `/plan-to-issues <slug>`.
---

## issue-splitter
output: false
progress: false

Package the approved plan for `{task}` into worker-ready issue artifacts.

Priorities:
- Read `PLANS/<slug>/plan.md` and `PLANS/<slug>/plan_review.md` first.
- Only continue if the plan is currently approved. If `plan_review.md` has a `## Review Status` section, its current `State:` line must be `APPROVED`; otherwise you may fall back to a top-level `# APPROVED` marker.
- If approval is missing, stop and report that issue generation is blocked.
- Do not ask the user questions or reopen planning.
- Generate `PLANS/<slug>/issues/index.md` and one worker-ready issue file per approved vertical slice.
- Preserve the approved slice boundaries, dependencies, validation notes, and conflict hotspots.
- Keep `issues/index.md` parseable for `/build`: include parseable issue file references plus a `## Suggested execution order` section with lines like `- Group A: issue 01` or `- Group B (parallel): issue 02 + issue 03`.
- Preserve existing `## Execution status` rows for unchanged issue filenames when rerunning issue generation; only reset rows that correspond to new or materially changed slice identities.
- Optimize the issue files for parallel worker execution with minimal blocking.
