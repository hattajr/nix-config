# Portable execution guidance

This is a skill, not a new executable command or scheduler. It depends on the current agent's real tools. Discover those tools instead of inventing tool calls, installing packages, or editing agent configuration implicitly.

## Worktrees and base

Create run-owned worktrees outside the checkout using git, even for a single issue. This preserves the user's active branch and avoids hooks that mirror old local planning artifacts. Resolve the repository's intended remote/base first; do not blindly assume `origin/main`.

Example shapes, with unique names and verified variables:

```sh
git status --short
git fetch "$remote" "$base"
# Resolve base_commit immediately after fetching the intended remote branch.
git rev-parse FETCH_HEAD
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/implement-issues.XXXXXX")
git worktree add -b "$integration_branch" "$run_dir/integration" "$base_commit"
git worktree add -b "$issue_branch" "$run_dir/issue-$number" "$base_commit"
```

Verify repository identity, branch, and commit inside each worktree before edits. Set up dependencies using the project's supported tooling. Do not copy user secrets or ignored application data; request safe provisioning if validation requires them. Isolate test ports, databases, and migration state as well as source files when concurrent tests could interfere.

Keep a single writer in each worktree. Parent inspection is read-only while that worktree's worker is active. Workers commit only scoped changes on their issue branches; the parent integrates commits serially into the integration worktree. Fresh reviewers inspect committed `base_commit...integration_branch` changes, never a diff that accidentally excludes uncommitted work.

If integration conflicts are mechanical and within the approved contracts, resolve and validate them. If they expose a new contract/design decision, stop rather than making that decision under the guise of a merge fix.

## Pi

If the `subagent` tool is available, read the installed `pi-subagents` skill and its relevant execution/safety references. Use the installed version's schema. Prefer its general `worker` and a fresh, no-edit `reviewer`; inspect discovery results because agents can be overridden locally.

The legacy `issue-worker-tdd` and `implement-issue-with-review` chain require `PLANS/` artifacts. Do not use them for this GitHub-native workflow.

For versions supporting `workflowScript`, launch a coordinated wave with `runs.all` and stable, issue-specific keys. Pass manually prepared worktree paths as explicit `cwd`, and disable automatic worktree creation so the correct base and isolation are not replaced. Example shape:

```javascript
subagent({
  workflowScript: `return runs.all([
    { key: "issue-42", agent: "worker", cwd: "/absolute/external/issue-42",
      worktree: false, context: "fresh", task: "<complete lane-specific contract>" },
    { key: "issue-43", agent: "worker", cwd: "/absolute/external/issue-43",
      worktree: false, context: "fresh", task: "<different lane-specific contract>" }
  ])`,
  async: true,
  mission: false
})
```

This is illustrative, not an executable placeholder payload. Include the actual brief in the contract when the worker lacks tools to read GitHub, and tell it which design docs to read. Do not rely on parent chat history to supply omitted requirements.

Use `mission: false` where supported: GitHub owns durable issue/run state, not a parallel local mission database. Runtime outputs may be temporary evidence. Ensure runtime files stay in the external execution worktrees or runtime storage, not a new project backlog. Do not invoke schedules or create local plan/status files. Do not enable native `worktree: true` for this workflow if its configured setup hook copies `PLANS/`.

The parent waits for actual handoffs and completes review/publication; an async launch is not the final result. Follow the installed notification/wait controls rather than sleep-polling or inventing commands. Never use obsolete parallel/chain payloads just because an old extension shows them.

## Claude Code

Use available agent/task delegation with explicit isolated worktree cwd and narrow prompts. Agent/task tool names and worktree options vary by version; inspect the actual schema. Use manually prepared git worktrees when tool-managed isolation cannot guarantee the intended base. Explicitly instruct each child to verify its repository/branch/cwd before edits.

Use fresh-context reviewers on the committed integrated diff. Do not assume Claude has Pi's `subagent` tool or a named `worker` profile. A suitable general-purpose agent with a complete contract is sufficient. Children do not publish to GitHub or run nested agents.

## Missing delegation or independent review

If no safe delegation/isolation capability exists, say so and implement the selected batch serially with one writer in external worktrees. Never simulate concurrency by starting multiple agents in one checkout.

If a separate reviewer/session is unavailable, self-check and run validation but disclose the limitation. Publish only a draft PR, not a supposedly independently reviewed ready PR. If neither delivery nor required validation can proceed, checkpoint on GitHub and preserve the work rather than pretending the workflow succeeded.

## Publication and cleanup

The parent is the only publisher. After final validation/review, push the new branch without force:

```sh
git -C "$run_dir/integration" push -u "$remote" "$integration_branch"
```

Confirm the remote belongs to the intended repository. If fork conventions or write permissions require a different publication target, follow documented conventions or ask; never silently push elsewhere.

Keep work recoverable through branch/commit pointers and PR links. Remove clean run-owned worktrees only after verifying their changes are preserved. Leave dirty, failed, or uncertain worktrees intact. Never use `git worktree remove --force`, delete arbitrary temporary directories, or prune another run's branches.
