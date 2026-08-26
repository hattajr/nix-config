import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import type { AutocompleteItem } from "@earendil-works/pi-tui";

type PlanFilesState = {
	dir: string;
	draftPath: string;
	planPath: string;
	reviewPath: string;
	hasDraft: boolean;
	hasPlan: boolean;
	hasReview: boolean;
	hasAny: boolean;
	reviewApproved: boolean;
};

function extractSlug(input: string): string {
	const trimmed = input.trim();
	if (!trimmed) return "";
	const match = trimmed.match(/PLANS\/([^/\s]+)\//);
	if (match) return match[1] ?? "";
	return trimmed.replace(/^@/, "").replace(/^PLANS\//, "").split(/[\/\s]/)[0] ?? "";
}

function currentReviewState(content: string): string | null {
	const normalized = content.replace(/\r\n/g, "\n");
	const reviewStatusSection = normalized.match(/(^|\n)##\s+Review Status\b([\s\S]*?)(?=\n##\s|\n#\s|$)/i);
	const reviewStatusBody = reviewStatusSection?.[2] ?? "";
	const sectionStateMatch = reviewStatusBody.match(/(^|\n)\s*[-*]?\s*State:\s*([A-Z_]+)/i);
	if (sectionStateMatch?.[2]) return sectionStateMatch[2].toUpperCase();

	const preamble = normalized.split(/\n##\s+Round\b/i)[0] ?? normalized;
	if (/(^|\n)#\s*APPROVED\b/i.test(preamble)) return "APPROVED";
	return null;
}

function isApprovedReviewText(content: string): boolean {
	return currentReviewState(content) === "APPROVED";
}

function getPlanFilesState(cwd: string, slug: string): PlanFilesState {
	const dir = join(cwd, "PLANS", slug);
	const draftPath = join(dir, "draft.md");
	const planPath = join(dir, "plan.md");
	const reviewPath = join(dir, "plan_review.md");
	const hasDraft = existsSync(draftPath);
	const hasPlan = existsSync(planPath);
	const hasReview = existsSync(reviewPath);
	const reviewApproved = hasReview
		? isApprovedReviewText(readFileSync(reviewPath, "utf-8"))
		: false;
	return {
		dir,
		draftPath,
		planPath,
		reviewPath,
		hasDraft,
		hasPlan,
		hasReview,
		hasAny: hasDraft || hasPlan || hasReview,
		reviewApproved,
	};
}

function listPlanSlugs(cwd: string): string[] {
	const plansDir = join(cwd, "PLANS");
	if (!existsSync(plansDir)) return [];
	return readdirSync(plansDir)
		.filter((name) => {
			const path = join(plansDir, name);
			if (!statSync(path, { throwIfNoEntry: false })?.isDirectory()) return false;
			return getPlanFilesState(cwd, name).hasAny;
		})
		.sort();
}

function getSlugCompletions(cwd: string, prefix: string): AutocompleteItem[] | null {
	const items = listPlanSlugs(cwd)
		.filter((slug) => slug.startsWith(prefix))
		.map((slug) => ({ value: slug, label: slug }));
	return items.length > 0 ? items : null;
}

function buildSupervisorPrompt(slug: string): string {
	return [
		`Supervise the planning loop for project slug \`${slug}\` from the top-level session.`,
		"",
		"Use top-level orchestration only. Do not use any nested orchestrator agent or nested autoloop chain.",
		"Run only the leaf planning agents when needed: `drafter`, `planner`, and `plan-reviewer`.",
		"",
		"Workflow:",
		`1. Read \`PLANS/${slug}/draft.md\` first, plus \`PLANS/${slug}/plan.md\` and \`PLANS/${slug}/plan_review.md\` when present.`,
		"2. If `draft.md` is missing, run `drafter` first so it can create a starter draft, then continue the loop.",
		"3. If `plan.md` or `plan_review.md` is missing, or the review file has not yet established the normal open-item/approval flow, run one full bootstrap pass of `drafter -> planner -> plan-reviewer`.",
		"4. If the current review state is approved, stop and summarize approval. Treat `## Review Status` -> `State:` as the source of truth when present, and only fall back to a top-level `# APPROVED` marker when no review-status state exists.",
		"5. If `[OPEN][DRAFTER]` items exist or the state says `NEEDS_DRAFTER`, ask the user the needed decisions yourself using `ask_user_question` in focused batches of up to 4 questions.",
		"6. After the user answers, run a subagent chain of `drafter -> planner -> plan-reviewer`, passing the resolved decisions in the task so the drafter updates `draft.md` without re-asking the same questions and the planner can address reviewer questions.",
		"7. If only `[OPEN][PLANNER]` items remain, run `planner -> plan-reviewer` without asking the user.",
		"8. Re-read the planning files after each pass and repeat until approval, a real user-decision stop, or a no-progress stop.",
		"9. If progress stalls, stop and explain exactly what remains blocked.",
		"",
		"Rules:",
		"- Keep user questioning at the parent/top-level session, not inside a child orchestrator.",
		"- Prefer structured questions for discrete product decisions.",
		"- When the parent already collected user answers, child `drafter` runs should apply those answers instead of asking again.",
		"- Preserve the persistent review conversation in `plan_review.md`.",
		"- Be explicit about which files changed and what the next action is.",
	].join("\n");
}

function buildIssuePrompt(slug: string): string {
	return [
		`Generate worker-ready issue files for project slug \`${slug}\` from the top-level session.`,
		"",
		"Use top-level orchestration only. Do not use any nested orchestrator agent.",
		"Run only the leaf issue-generation workflow when needed: prefer `issue-splitter` directly or the saved `plan-to-issues` chain.",
		"",
		"Workflow:",
		`1. Read \`PLANS/${slug}/draft.md\` when present, plus \`PLANS/${slug}/plan.md\` and \`PLANS/${slug}/plan_review.md\`.`,
		"2. If `plan.md` or `plan_review.md` is missing, stop and clearly report the missing path.",
		"3. If the plan is not currently approved, stop and clearly report that issue generation is blocked. When `plan_review.md` has a `## Review Status` section, treat its current `State:` line as the source of truth and only fall back to a top-level `# APPROVED` marker when no review-status state exists.",
		"4. Do not ask the user questions or reopen planning.",
		"5. If approved, run issue generation and create/update `PLANS/<slug>/issues/index.md` plus one issue file per approved vertical slice.",
		"6. Keep the generated index parseable for `/build`: include issue file references as backticked paths or markdown links to `PLANS/<slug>/issues/NN-*.md`, include a `## Suggested execution order` section with bullets like `- Group A: issue 01` or `- Group B (parallel): issue 02 + issue 03`, and preserve existing execution-status rows only when the slice identity is still unchanged. If a slice materially changed but kept the same filename, reset that row and explain the reset.",
		`7. After generation, read \`PLANS/${slug}/issues/index.md\` immediately so the user can see the issue list without another prompt.`,
		"8. Summarize the exact issue file paths, slice ordering, and dependency/parallelization notes, and mention that the index file was opened/read.",
		"",
		"Rules:",
		"- Be explicit about whether issue generation was blocked or completed.",
		"- Keep the output path-focused and execution-oriented.",
		"- Preserve the approved slice boundaries from the plan.",
	].join("\n");
}

async function pickSlug(args: string, ctx: { cwd: string; ui: { notify: (message: string, level?: string) => void; select: (title: string, options: string[]) => Promise<string | null>; }; }, commandName: string, options?: { allowMissingManualSlug?: boolean }): Promise<string | null> {
	const slug = extractSlug(args);
	if (slug) {
		if (!options?.allowMissingManualSlug && !getPlanFilesState(ctx.cwd, slug).hasAny) {
			ctx.ui.notify(`No planning artifacts found for '${slug}'. Expected at least one of PLANS/${slug}/draft.md, plan.md, or plan_review.md.`, "warning");
			return null;
		}
		return slug;
	}
	const known = listPlanSlugs(ctx.cwd);
	if (known.length === 0) {
		ctx.ui.notify("No planning slugs found under PLANS/", "warning");
		return null;
	}
	if (known.length === 1) return known[0] ?? null;
	const picked = await ctx.ui.select("Pick a planning slug", known);
	if (!picked) {
		ctx.ui.notify(`Cancelled /${commandName}`, "info");
		return null;
	}
	return picked;
}

function sendPrompt(pi: ExtensionAPI, prompt: string, ctx: { isIdle: () => boolean; ui: { notify: (message: string, level?: string) => void; }; }, queuedLabel: string) {
	if (ctx.isIdle()) {
		pi.sendUserMessage(prompt);
	} else {
		pi.sendUserMessage(prompt, { deliverAs: "followUp" });
		ctx.ui.notify(queuedLabel, "info");
	}
}

export default function planAutoloop(pi: ExtensionAPI) {
	pi.registerCommand("plan-autoloop", {
		description: "Top-level planning supervisor for PLANS/<slug> (omit slug to pick interactively)",
		getArgumentCompletions: (prefix) => getSlugCompletions(process.cwd(), prefix),
		handler: async (args, ctx) => {
			const slug = await pickSlug(args, ctx, "plan-autoloop", { allowMissingManualSlug: true });
			if (!slug) return;
			sendPrompt(pi, buildSupervisorPrompt(slug), ctx, `Queued /plan-autoloop for ${slug}`);
		},
	});

	pi.registerCommand("plan-to-issues", {
		description: "Generate issue files from an approved plan (omit slug to pick interactively)",
		getArgumentCompletions: (prefix) => getSlugCompletions(process.cwd(), prefix),
		handler: async (args, ctx) => {
			const slug = await pickSlug(args, ctx, "plan-to-issues");
			if (!slug) return;

			const files = getPlanFilesState(ctx.cwd, slug);
			if (!files.hasPlan) {
				ctx.ui.notify(`Cannot run /plan-to-issues ${slug}: missing PLANS/${slug}/plan.md. Run /plan-autoloop ${slug} first.`, "warning");
				return;
			}
			if (!files.hasReview) {
				ctx.ui.notify(`Cannot run /plan-to-issues ${slug}: missing PLANS/${slug}/plan_review.md. Run /plan-autoloop ${slug} first.`, "warning");
				return;
			}
			if (!files.reviewApproved) {
				ctx.ui.notify(`Cannot run /plan-to-issues ${slug}: PLANS/${slug}/plan_review.md is not approved yet. Expected '# APPROVED' or 'State: APPROVED'.`, "warning");
				return;
			}

			sendPrompt(pi, buildIssuePrompt(slug), ctx, `Queued /plan-to-issues for ${slug}`);
		},
	});
}
