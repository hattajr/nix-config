# Durable GitHub issue bodies

The approved issue body is the implementation contract. Comments preserve discussion, investigation, progress, and historical decisions; they should not become a second competing brief. Changes to behavior/constraints must be consolidated into an approved body revision before readiness.

Name behaviors, interfaces, and settled design constraints. Avoid instructions tied to filenames, line numbers, private functions, or exhaustive coding steps that can go stale. References to durable architecture/schema/ADR docs are encouraged. A compact schema/state-machine snippet is useful when it captures a settled decision more precisely than prose; identify its provenance and include only the decision-rich portion.

## Capture template

Use for an idea dump or unfinished discussion. Do not fabricate missing details to fill fields. Label `needs-triage`, not ready.

```markdown
## Idea
<The request in the user's terms, without invented scope.>

## Why
<Known motivation, or omit when not established.>

## Established so far
- <Known decision or constraint; omit if none.>

## Open questions
- <Specific unresolved question.>

## References
- <Relevant docs, existing issues, or prior discussion; omit if none.>
```

## Agent brief template

Use for a refined issue. Retain useful original reporting/context, such as steps to reproduce, in a clear section if it is not captured by current behavior.

```markdown
## Goal
<One observable outcome and who benefits.>

## Current behavior
<What exists now; for bugs, reproduction/evidence and environment.>

## Desired behavior
<What must change, including relevant edge cases and failure behavior.>

## Decisions and constraints
- <Settled interface, compatibility, migration, security, or product constraint.>

## Acceptance criteria
- [ ] <Specific, independently verifiable behavior.>
- [ ] <Relevant failure/edge-case behavior.>

## Validation
<Public interface, user flow, or test seam that demonstrates the criteria.
Known commands can be included, but are not a substitute for behavior checks.>

## Out of scope
- <Adjacent work that this issue must not absorb.>

## Blocked by
None (can start when otherwise eligible).
<!-- Or named issue links, one per genuine prerequisite. -->

## References
- <Durable design docs and relevant issues/decisions; omit if none.>
```

Do not leave unresolved acceptance-critical questions in a ready brief. If a decision is outstanding, retain it in triage notes and use `needs-info`/`needs-triage`. For `ready-for-human`, add a section explaining the non-delegatable access/judgment required.

## Triage notes for resuming

```markdown
## Triage notes

### Established
- <Resolved fact or decision, with evidence where useful.>

### Still needed
- <Precise question and who can answer it.>

### Evidence
- <Reproduction result or investigation pointers.>
```

Read previous notes and subsequent answers before interviewing again. Distinguish observations from guesses and user-approved decisions. If the user stops halfway, preserve the established facts and unanswered frontier without adding `grilled` merely because questions were asked.

## Readiness check

Before proposing `ready-for-agent`, check:
- The request is not already implemented, duplicate, rejected, or only an umbrella.
- Current and desired behavior are clear and grounded in relevant evidence/code.
- Scope fits one fresh worker context and has explicit non-goals.
- Criteria are observable, cover material failures, and can be validated honestly.
- Required behavior/design decisions are settled and constraints are documented.
- Blockers are named accurately, or explicitly `None`; no dependency cycle exists.
- The user has approved the final brief and label changes.

Clear bugs need evidence and regression criteria, not a mandatory interview. Clear features need a brief, not a mandatory implementation recipe. A blocked but fully specified issue can be labeled ready, but is not yet eligible for execution.
