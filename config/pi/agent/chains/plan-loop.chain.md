---
name: plan-loop
description: One pass of the persistent drafter -> planner -> plan-reviewer loop for PLANS/<project>/ draft, plan, and review files, with planner producing parallelizable vertical slices. Re-run manually or use `/plan-autoloop <slug>` from the top-level session until plan_review.md is APPROVED.
---

## drafter
output: false
progress: false

Start or continue one pass of the persistent planning loop for `{task}`.

Priorities:
- Read `PLANS/<slug>/draft.md`.
- If `plan_review.md` contains any `[OPEN][DRAFTER]` items or says `NEEDS_DRAFTER`, resolve them by interviewing the user and updating `draft.md`, unless the parent task already says the top-level session collected those answers and passed them in.
- If there are no drafter-routed review items, still tighten the draft when it is weak or underspecified.
- Preserve review history.

## planner
output: false
progress: false

Continue one pass of the persistent planning loop for `{task}`.

Priorities:
- Read the updated `draft.md`, existing `plan.md`, and existing `plan_review.md`.
- Create or refine a worker-ready `plan.md`.
- Break the plan into independently grabbable vertical slices (tracer bullets) that can be distributed to workers in parallel with minimal blocking.
- Make slice boundaries explicit: exact files, dependencies, shared contracts, merge-conflict hotspots, and per-slice validation.
- Answer any `[OPEN][PLANNER]` items in `plan_review.md`.
- Do not guess on `[DRAFTER]` items; leave them for drafter/user resolution.

## plan-reviewer
output: false
progress: false

Finish this loop pass for `{task}`.

Priorities:
- Review `draft.md`, `plan.md`, and `plan_review.md`.
- Mark solved items.
- Review whether the issue breakdown is made of real vertical slices that workers can grab independently in parallel.
- Add new `[OPEN][PLANNER]` items for planner-fixable problems, including weak slice boundaries, hidden dependencies, missing per-slice validation, or fake parallelism.
- Add new `[OPEN][DRAFTER]` items for medium/high-impact decisions or ambiguities that need user clarification.
- Set review status and next step.
- Add `# APPROVED` only when no material open items remain.
