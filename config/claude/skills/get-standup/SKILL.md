---
name: get-standup
description: Generate a cross-department standup report (ACP format) from the last N days of work across ~/dev and ~/lab. Deterministically collects git commits, working-tree changes, and modified files, then summarizes interactively. Use when the user runs /get-standup or asks to prepare a standup / status update for the last N days.
---

# get-standup

Build a standup report for the last **N days** (default **7**). Collection is deterministic (a fixed script); summarization and selection are interactive.

`N` comes from the invocation argument (e.g. `/get-standup 14` → N=14). If no number is given, use 7.

## Step 0 — Sync the project boards (best effort, never blocks the report)

Run this once, verbatim, before collecting:

```
gh-board sync
```

It puts my open GitHub issues, including ones I created by hand in the GitHub UI, on my project boards so they are current. Do not pass `--dry-run`, do not retry, and do not run any other `gh-board` command.

- Exit status 0: continue to Step 1.
- Non-zero exit status, or `gh-board` is not installed (command not found): do **not** stop. Keep a one-line warning that names what failed (the `gh-board:` lines on stderr name the failing board or repository; otherwise say it is not installed), then continue to Step 1 as normal.

The sync does not change what the collector reports. Do not put the warning in `summary.md` or `final.md`; it is not standup content.

## Step 1 — Collect (deterministic, do not improvise)

Run the bundled collector verbatim. Do **not** hand-write git commands.

```
uv run ~/.claude/skills/get-standup/collect.py --days N
```

The script prints `OUTDIR=<path>` to stderr and writes `raw.json` + `raw.md` there. The path is always `~/.claude/standups/<YYYYMMDD>-Nd/` (today's date + interval), e.g. `~/.claude/standups/20260624-7d/`. Use that as `OUTDIR` for all later steps.

Everything in `raw.json`/`raw.md` is already scoped to the window — commits since the cutoff, working-tree files modified within the window, branches active in the window. Trust it; do not re-filter by date.

## Step 2 — Summarize into ACP, write `OUTDIR/summary.md`

Read `OUTDIR/raw.md` and group the work into **ACP** for a cross-functional audience:

- **Accomplishments** — completed work. Source: commits under a `### Commits — pushed to ... (shipped)` heading only. Merge related shipped commits in the same repo into one outcome-focused bullet. Describe the *result*, not the diff.
- **Challenges** — issues, blockers, lessons. Infer cautiously from signals (reverts, hotfix/wip commits, large uncommitted changes lingering) but keep these light; most challenges come from the user in Step 3.
- **Priorities** — next focus. Source: not-yet-pushed commits, in-progress working-tree changes, and active feature branches.

### Guardrail: shipped vs in-progress (non-negotiable, prevents false claims)
"Shipped" means pushed to the remote default branch. The collector splits commits into `### Commits — pushed to <ref> (shipped)` and `### Commits — NOT yet pushed ... (work in progress)`. This distinction is mandatory:
- **Pushed (shipped) commits** may be stated as done: "shipped", "completed", "now does X", "delivered".
- **Not-yet-pushed commits AND uncommitted working-tree changes** are NOT done. Never write "now works", "shipped", "completed", "live", or any done/present-perfect claim for them. Describe them only as in-progress: "prototyping", "experimenting with", "started", "in review", "working on". Default these into **Priorities**, or into Accomplishments only with explicit in-progress phrasing.
- If unsure whether something is pushed, treat it as in-progress.

Write `summary.md` as an **editable checklist**. Every item is a `- [x]` line (included by default). One project's work may produce several bullets. Keep enough detail to be accurate but write in plain language — the audience is multi-department, not engineers. Group bullets under the three ACP headings, and within each, you may sub-group by project.

Append an empty section the user fills in:

```markdown
## Additional (not captured on this machine)
<!-- Add work that isn't in git: meetings, reviews, decisions, planning, cross-team support. One `- [x]` bullet each. -->
- [ ]
```

End the file with a clear instruction comment telling the user to: toggle `[x]`/`[ ]` to include/exclude, edit wording freely, and fill the Additional section — then return and say "done".

## Step 3 — Hand off for editing

Tell the user the summary is at `OUTDIR/summary.md`, briefly list the ACP bullet counts, and ask them to edit it (toggle inclusion, fix wording, add off-machine work) and reply when ready. If the Step 0 sync failed, start this message with its warning. Wait for their confirmation.

If anything in the summary is ambiguous or a likely Challenge/Priority is unclear, you may ask 1-2 targeted questions via AskUserQuestion — but the editable file is the primary mechanism.

## Step 4 — Generate `OUTDIR/final.md`

After the user confirms, re-read `summary.md`. Keep only `- [x]` items (drop every `- [ ]` line, including the placeholder prompts). Fold any Additional items into the matching project. Write `OUTDIR/final.md` with two versions, in this fixed order.

### Formatting rules (apply to the entire `final.md`, non-negotiable)
- No em dashes (`—`). Use a colon, comma, period, or parentheses instead.
- No emoticons or emoji.
- No bold or other inline emphasis. Plain text only; structure comes from headings and bullets.

### Plain-language rule (apply to the entire `final.md`, non-negotiable)
Write so a non-native English speaker understands on the first read.
- Short sentences, one idea each (aim under ~20 words). Break long sentences apart.
- Everyday words over fancy ones: "move" not "migrate/cutover", "set up" not "stand up", "finish" not "wrap up", "caused" not "surfaced", "improved" not "overhauled".
- No idioms, metaphors, or jargon phrasal verbs (avoid "did a big pass", "on top of that", "roll out", "land", "stood up").
- Prefer active voice and concrete subjects ("I fixed X", not "X was addressed").
- Keep necessary project names and unavoidable domain nouns, but simplify everything around them. (Version 2 also softens technical terms per the softening rule above.)

### Accuracy rule (non-negotiable, both versions)
- Carry the shipped/in-progress guardrail from Step 2 through to `final.md`. Unmerged commits and uncommitted changes must never be phrased as done/shipped/live in either version. When in doubt, hedge ("experimenting with", "in progress").

### Version 1 — Written (concise, per project)
- Heading `## Written version (concise, per project)`.
- ACP sub-headings: `### Accomplishments`, `### Challenges`, `### Priorities`.
- Under Accomplishments, one bullet per project/repo, project name first followed by a colon (e.g. `- spatchdb: ...`). Merge a project's commits into a single short outcome bullet.
- Cross-department tone: outcomes and impact, no commit hashes, no file paths, minimal jargon.

### Version 2 — Storyable (to speak)
- Heading `## Storyable version (to speak)`, separated from version 1 by a `---` rule.
- A first-person narrative the user can read aloud: a few short paragraphs, opening with the biggest thread, closing with a one-line "next up". Natural spoken cadence.
- **Soften all infra/technical terms here** for a non-technical, cross-department audience: drop product/tool names, repo names, and vendor names. Say "cloud storage provider" not "Cloudflare R2", "automatic testing and deploy" not "CI/CD self-hosted runner", "rebuild older studies" not "merged-EDF source". Keep the meaning and impact; cut the jargon. (Version 1 stays technical; only version 2 is softened.)

### Coverage rule: version 2 IS version 1, expanded (non-negotiable)
The Storyable version must be a faithful spoken expansion of the Written version, not a separate story. Concretely:
- **Every** Accomplishment, Challenge, and Priority bullet in version 1 must appear in version 2, expanded into prose. Nothing from version 1 may be dropped (version 1 had a parquet/benchmarking bullet? then version 2 says it too).
- Version 2 must NOT introduce work that is not in version 1.
- A reader should be able to trace each version-1 bullet to a sentence or clause in version 2. You may regroup or reorder for narrative flow, but coverage is one-to-one.
- After drafting, re-check: walk each version-1 bullet and confirm it is reflected in version 2. Fix any gaps before finishing.

Show `final.md` in the chat and give the user its path.
