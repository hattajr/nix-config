---
name: plan-bootstrap
description: Bootstrap a project's planning artifacts by running drafter -> planner -> plan-reviewer for the first full pass, with planner producing parallelizable vertical slices.
---

## drafter
output: false
progress: false

Bootstrap the planning workflow for `{task}`.

Priorities:
- Determine the target project slug.
- Read or create `PLANS/<slug>/draft.md`.
- If the draft is weak, incomplete, or missing key product decisions, interview the user and strengthen it.
- For existing projects, inspect the repository and ground the draft in actual files, modules, configs, tests, docs, and implementation constraints.
- Leave the draft planner-ready.

## planner
output: false
progress: false

Create the first strong worker-ready plan for `{task}`.

Priorities:
- Read the updated `draft.md` plus any existing `plan.md` and `plan_review.md`.
- Write or refine `PLANS/<slug>/plan.md` with detailed, ordered, file-specific tasks for the worker.
- Break the plan into independently grabbable vertical slices (tracer bullets) so multiple workers can execute in parallel with minimal blocking.
- Make slice boundaries explicit: exact files, dependencies, shared contracts, merge-conflict hotspots, and per-slice validation.
- If reviewer history already exists, answer any `[OPEN][PLANNER]` items.
- Route unresolved requirement or product decisions to drafter via `[OPEN][DRAFTER]` items instead of guessing.

## plan-reviewer
output: false
progress: false

Perform the initial persistent review pass for `{task}`.

Priorities:
- Read `draft.md`, `plan.md`, and `plan_review.md` if present.
- Review whether the plan is concrete enough for a worker.
- Review whether the issue breakdown is made of real vertical slices that workers can grab independently in parallel.
- Open `[OPEN][PLANNER]` items for planner-fixable problems, including weak slice boundaries, hidden dependencies, or fake parallelism.
- Open `[OPEN][DRAFTER]` items for medium/high-impact ambiguities or user-facing decisions.
- Set `## Review Status` with `State` and `Next step`.
- Add `# APPROVED` only when no material open items remain.
