# GitHub operations

Use authenticated `gh` with an explicit repository for every remote operation. Read the available `github` skill too. These are command shapes, not a script to execute blindly; substitute verified values and check every exit status.

## Repository and issue discovery

```sh
git remote -v
gh auth status
gh api user --jq .login
gh repo view --json nameWithOwner,url,defaultBranchRef
```

Confirm the inferred repository is the intended implementation target and determine the matching fetch/push remote and PR base. Respect documented non-default bases. Resolve `#42` only against that repository. Verify full URLs/references against it; ask on mismatch.

For a ready backlog, paginate rather than trusting the CLI's default issue limit:

```sh
gh api --method GET --paginate "repos/$repo/issues" \
  -f state=open -f labels=ready-for-agent -f sort=created -f direction=asc \
  -f per_page=100 --jq '.[] | select(.pull_request == null)'
```

For each candidate or explicit target:

```sh
gh api "repos/$repo/issues/$number"
gh api --paginate "repos/$repo/issues/$number/comments?per_page=100"
gh api --paginate "repos/$repo/issues/$number/timeline?per_page=100"
```

The issue response includes labels, assignees, state, body, `state_reason`, and a `pull_request` field for PRs. Reject a PR target. Inspect timeline cross-references, claim/progress comments, and linked PRs to avoid duplicate implementation. An assignee equal to your own login can belong to another session; it is not permission to take over. An ambiguous old claim needs user confirmation, not a guessed expiry.

If comments/body conflict, or later discussion revokes an earlier brief, stop and request refinement. Never treat the existence of `grilled` as an approved implementation contract.

## Blocking relationships

Read native blockers using the API supported by the repository:

```sh
gh api --paginate "repos/$repo/issues/$number/dependencies/blocked_by?per_page=100"
```

Also read the issue's explicit `Blocked by` section; resolve each reference, including cross-repository blockers. Native and textual relationships form a union. A parent/sub-issue relationship is hierarchy, not automatically a blocker.

`issue_dependencies_summary.blocked_by` can help identify open native blockers, but does not replace reading dependency details or textual links. A failed API call is not an empty blocker list. When native dependencies are unavailable, use a clearly documented repository fallback such as `Blocked by: None` or a list of references; if it cannot establish eligibility, skip/report the issue.

For every blocker, inspect closure reason, linked PR state/base, and the actual target code. A `not_planned` closure, duplicate, or implementation only present on another branch does not establish a satisfied prerequisite. Already-existing behavior may satisfy it only with concrete evidence; otherwise request a corrected dependency/brief.

## Claims and states

List existing labels before editing states:

```sh
gh label list --repo "$repo" --limit 200 --json name
```

Use documented repository mappings when present; defaults are `ready-for-agent`, `in-progress`, and `needs-info`. Treat contradictory state labels as a triage problem. Do not create labels or redesign the repository's label scheme implicitly.

Re-check eligibility immediately before the first write. Claim with the authenticated user, then post a run marker and re-read before launching:

```sh
gh issue edit "$number" --repo "$repo" --add-assignee "$login"
# Only when in-progress already exists:
gh issue edit "$number" --repo "$repo" \
  --remove-label ready-for-agent --add-label in-progress
```

Use a unique run identifier, for example a timestamp plus a random suffix. The claim comment should contain:

```markdown
## Implementation claim
Run: <unique run id>
Owner: @<authenticated user>
Issue: <full issue URL and title>
Base: <branch and commit>
Scope: <approved behavior>
Delivery: reviewed PR; no merge or early issue closure.
```

GitHub label/assignment edits are not compare-and-swap locks. Re-reading detects many conflicts but cannot guarantee exclusive ownership across simultaneous sessions; stop on evidence of another owner/run. Retain run markers in later comments so cancellation and recovery can distinguish your work.

The parent alone writes comments and labels. Keep updates concise: claim, meaningful blocker, review/validation result, PR link. Avoid posting a comment for every worker tool call. Use a body file outside the checkout rather than interpolating untrusted issue text into shell commands:

```sh
gh issue comment "$number" --repo "$repo" --body-file "$body_file"
```

Never overwrite the approved brief, add `grilled`, or mark an unready issue ready during implementation. On a human-decision blocker, use the existing `needs-info` mapping. If that label does not exist, post the blocker, remove execution-readiness if needed, and ask about state conventions instead of silently inventing a label.

Only release assignments/state changes created by this run. Keep a PR-pending issue claimed, even though it remains open. Recovery comments must explain whether the run is active, blocked, awaiting merge, or released, and link any PR/branch/commit worth preserving.

## PR delivery

Check for a PR on the implementation branch before creating one, especially after a network failure or interrupted invocation:

```sh
gh pr list --repo "$repo" --state all --head "$branch" \
  --json number,url,state,isDraft,baseRefName,headRefName
gh pr create --repo "$repo" --base "$base" --head "$branch" \
  --title "$title" --body-file "$body_file"
```

Add `--draft` if required checks, independent review, or material fixes remain incomplete. Do not duplicate a PR when creation may have succeeded but its response was lost. Do not turn an existing unrelated PR into this batch's PR.

Include `Closes #N` only for fully implemented included issues, using full cross-repository references when necessary. For a non-default target base, explain that automatic issue closure may wait until the changes reach GitHub's default branch; do not manually close issues to compensate.

Post delivery evidence on each included issue:

```markdown
## Implementation result
Run: <run id>
Status: implemented, awaiting merge / draft, blocked by <reason>
PR: <URL>
Acceptance evidence: <criterion-to-test/behavior mapping>
Validation: <commands and actual results>
Independent review: <outcome and resolved findings>
Remaining risks: <limitations or None>
```

An opened PR, a worker commit, or a passing check does not authorize merge, release, or issue closure. Leave failed/excluded issues out of closing references and record their own outcomes separately.
