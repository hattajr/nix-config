# GitHub planning operations

Shared transport guidance for `triage` and `to-tickets`. Use authenticated `gh`, an explicit verified repository, and the current agent's structured approval tool. These examples are command shapes: substitute validated values, safely quote arguments, and check every result.

## Resolve and read

```sh
git remote -v
gh auth status
gh api user --jq .login
gh repo view --json nameWithOwner,url,defaultBranchRef
```

Verify the repository and matching checkout before reading local code. Do not resolve a full URL against a different checkout or guess between ambiguous remotes. A bare `#42` is always resolved against the confirmed repository.

Paginate discovery, comments, labels, and relationships where needed:

```sh
gh api --method GET --paginate "repos/$repo/issues" \
  -f state=open -f sort=created -f direction=asc -f per_page=100 \
  --jq '.[] | select(.pull_request == null)'
gh api "repos/$repo/issues/$number"
gh api --paginate "repos/$repo/issues/$number/comments?per_page=100"
gh api --paginate "repos/$repo/issues/$number/timeline?per_page=100"
gh api --paginate "repos/$repo/labels?per_page=100"
gh api --paginate "repos/$repo/issues/$number/dependencies/blocked_by?per_page=100"
```

Issue responses include body, labels, assignees, author, timestamps, state, and closure reason; a `pull_request` field identifies a PR. Skip PRs for these planning skills. Read all relevant comments instead of relying on the CLI's first page. A failed read is unknown context, not an empty discussion/dependency list.

Read timeline cross-references and claim/result comments to detect existing implementation PRs. Do not alter live claims or PR-pending states implicitly. Search open and closed issues by the request's concepts for duplicate or prior-rejection evidence; search is an investigation aid, not proof no duplicates exist.

For attention discovery, “untriaged” means lacking a triage state, not literally having zero labels. For needs-info activity, compare relevant reporter/maintainer replies with the last triage-note timestamp; do not count the agent's own unrelated progress comments as an answer.

## Explicit approval and minimal label setup

Before remote writes, show the concrete title/body or proposed body revision, labels to add/remove, any relationship/parent changes, and any closing action. Request approval. Include missing-label creation in that summary when needed. Mere discovery or interview participation is not publication approval.

Use the shared [label policy](labels.md). Replace conflicting category/state labels only as approved; preserve unrelated labels, assignees, and discussion history. Listing is read-only. Do not create a local tracker configuration or instruct the user to install upstream setup/domain-modeling skills.

When a label is absent and its definition has been approved:

```sh
gh label create "$label" --repo "$repo" --description "$description"
```

Do not use `--force` to overwrite existing label metadata. If label creation fails, report the permissions/error and do not claim a working execution-ready queue exists.

## Create and update

In Pi, use `create_github_issue` when available, only after explicit creation approval, with the latest approved title and approved body. It may not support labels; add those with `gh` afterward. In Claude Code or when that tool is unavailable:

```sh
gh issue create --repo "$repo" --title "$title" --body-file "$body_file"
```

The body file is temporary and outside the checkout. Do not interpolate untrusted issue text into shell code. A response lost after a create attempt requires checking for the exact created issue before retrying.

For approved existing-issue changes:

```sh
gh issue edit "$number" --repo "$repo" --body-file "$body_file"
gh issue edit "$number" --repo "$repo" --add-label "$category,$state"
gh issue comment "$number" --repo "$repo" --body-file "$comment_file"
```

Remove only the approved superseded category/state labels with `--remove-label`. Re-read the issue before writes to avoid overwriting concurrent body/comment/claim changes. Save a complete approved brief and establish dependencies before applying `ready-for-agent`; labels are not a substitute for a durable contract.

Keep issue bodies and comments focused on the request; do not add AI-generation disclaimers. Do not add noise comments solely for a label change.

## Dependencies and parent links

Native blocking links are preferred; an explicit `Blocked by` body section remains the portable readable representation. Keep both consistent when native links are available. The numeric database id is required when adding a native blocker, not the issue number or GraphQL node id:

```sh
gh api "repos/$repo/issues/$blocker" --jq .id
gh api --method POST "repos/$repo/issues/$number/dependencies/blocked_by" \
  -F issue_id="$blocker_database_id"
```

Verify edges by reading them back. Native sub-issue links are hierarchy, not blocking edges. When approved and supported:

```sh
gh api "repos/$repo/issues/$child" --jq .id
gh api --method POST "repos/$repo/issues/$parent/sub_issues" \
  -F sub_issue_id="$child_database_id"
```

If native relationships are unsupported, retain full named parent/blocker references in issue bodies and any explicitly approved parent task list. Report fallback use. Permission or transient failures are not automatically “unsupported”; retry/check safely or report incomplete publication. Never erase unknown native blockers because the proposed brief omitted them. Propose reconciliation, including edge removals, for approval rather than silently changing existing dependencies.

Read the full dependency graph relevant to proposed changes and reject self-links/cycles. Include existing native and textual edges when checking cycles. A ready label means fully specified, not unblocked. Completion evidence must be present in the implementation base; a rejected/duplicate closed issue or an unmerged PR is not automatically a completed prerequisite.

## Closing and failure handling

Closing is a separate approved operation. Use `gh issue close --reason completed` only for work actually present/verified; use `--reason "not planned"` for an approved rejection/duplicate disposition as appropriate. Do not label all closed issues `wontfix`. Explain the exact reason and link evidence in an approved comment.

No skill here merges PRs, changes assignees to claim implementation, or closes a parent merely because child tickets were created. Check operation results and read back persisted bodies, labels, and relationships. If a batch partially publishes, report existing issue URLs and remaining operations; resume those instead of duplicating tickets.

GitHub failures do not authorize a local issue mirror. Keep unsaved drafts in chat; use existing GitHub issues/comments for durable partial-progress pointers when possible. Never report ready/successful publication until its required writes have actually succeeded.
