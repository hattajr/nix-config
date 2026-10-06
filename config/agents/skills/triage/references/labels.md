# Shared GitHub label policy

This policy is used by `triage`, `to-tickets`, and `implement-issues`. Read any documented repository mappings first; otherwise use these exact default names. Apply the mapped label strings consistently in queries and mutations. Do not create a local tracker/label configuration file or require an upstream setup skill.

## Categories

| Label | Meaning |
| --- | --- |
| `bug` | Existing supported behavior is broken |
| `enhancement` | New behavior or an improvement |

A triaged executable/candidate issue has one category. Preserve unrelated labels. If both categories exist, recommend the correct one and ask before reconciliation.

## Workflow states

| Label | Meaning |
| --- | --- |
| `needs-triage` | Idea captured or evaluation/refinement incomplete |
| `needs-info` | Specific evidence or decisions are awaited |
| `ready-for-agent` | Approved brief is complete enough for unattended implementation |
| `ready-for-human` | Clear brief, but execution needs human-only access or judgment |
| `wontfix` | Rejected request; use only with an approved rejection outcome |
| `in-progress` | Claimed implementation, including PR-pending work when no review state exists |

Exactly one workflow-state label should remain after an approved triage transition. Repository-defined review states belong to this group too. Do not remove state labels from an active run or PR-pending issue without the owner/user's approval. Closed is GitHub's lifecycle state, not a new completion label.

Normal transitions:

```text
untriaged → needs-triage → needs-info → needs-triage
                        ↘ ready-for-agent → in-progress → PR → merged/closed
                        ↘ ready-for-human
                        ↘ wontfix (close only after approval)
```

There is no need to persist an intermediate `needs-triage` transition when an initially unlabeled, already-clear issue has an approved brief and an approved direct move to ready. The approval gate still applies.

Readiness is specification quality, not scheduling eligibility. A `ready-for-agent` issue may still have open blockers. `implement-issues` also checks that it is unclaimed, blockers are actually satisfied in the base branch, and concurrent edits are safe. Assignees and claim comments still gate execution if `in-progress` is unavailable.

## Discussion marker

`grilled` is an independent, optional label, never a workflow state:
- Add it only after a relevant grilling discussion is complete and the user confirms the shared understanding.
- Do not infer it from a long issue, a design doc, a readiness label, or approval to publish.
- A clear bug or approved ticket derived from design docs can be ready without grilling.
- A grilled request can remain `needs-triage` or `needs-info` if packaging, evidence, or new questions remain.
- For split tickets, inherit this marker only when the completed, user-confirmed discussion actually settled the child's scope and the user approved the label. Do not automatically tag every child of a grilled parent.

Existing `grilled` can be retained as historical discussion provenance when an issue is reopened for refinement. It does not prove a newly added scope is settled, and never bypasses the readiness gate. Explain that distinction rather than silently promoting new scope.

## Missing labels and conflicts

List the repository's labels before writes. Do not bulk-add readiness or generate missing labels silently. Propose only the minimal missing definitions needed for the approved operation, with names/descriptions and no forced changes to existing colors or mappings.

Approval to publish an issue does not implicitly authorize unrelated repository configuration. Include any required label creation in the explicit approval summary. If declined/unavailable, report the limitation and keep the issue out of the automatic implementation queue until a working readiness convention exists.

Do not relabel active implementation merely because it is absent from a ready query. An open PR can be the current work product; keep its issue claimed until merge or an explicitly approved handoff.
