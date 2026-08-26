import { complete, getModel } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { getMarkdownTheme } from "@earendil-works/pi-coding-agent";
import { Container, Markdown } from "@earendil-works/pi-tui";
import { execFile } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const REPORT_MESSAGE_TYPE = "gen-standup-report";
const STATUS_KEY = "gen-standup";
const LOADING_SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const LOADING_MESSAGES = ["Cooking your standup...", "Collecting your work...", "You seem busy these days..."];
const MAX_MONTHS = 3;
const MAX_DAYS = 92;
const SPOKEN_INTRO = "Good morning everyone. Here is my update.";
const SPOKEN_OUTRO = "That is all from me. Thank you.";

type RangeSpec = {
	raw: string;
	amount: number;
	unit: "d" | "m";
};

type SearchCommit = {
	repoFullName: string;
	repoName: string;
	sha: string;
	date: string;
	headline: string;
};

type CommitFileStat = {
	path: string;
	additions: number;
	deletions: number;
};

type CommitDetail = {
	repoFullName: string;
	repoName: string;
	sha: string;
	date: string;
	headline: string;
	body: string;
	files: CommitFileStat[];
	paths: string[];
	codePaths: string[];
	testPaths: string[];
	metaPaths: string[];
	supportPaths: string[];
	totalAdditions: number;
	totalDeletions: number;
	totalChanges: number;
	impact: "high" | "medium" | "low";
};

type ActivityCommit = {
	date: string;
	title: string;
	body: string;
};

type RepoSummary = {
	repoName: string;
	repoFullName: string;
	activityCommits: ActivityCommit[];
	latestDate: string;
	commitCount: number;
};

type ReportBuild = {
	markdown: string;
	warnings: string[];
};

function parseRange(value: string): RangeSpec | null {
	const normalized = value.trim().toLowerCase();
	const match = normalized.match(/^(\d+)([dm])$/u);
	if (!match) return null;

	const amount = Number.parseInt(match[1] ?? "0", 10);
	const unit = match[2] as "d" | "m";
	if (!Number.isFinite(amount) || amount <= 0) return null;

	if (unit === "m") {
		if (amount > MAX_MONTHS) return null;
		return { raw: normalized, amount, unit };
	}

	if (amount > MAX_DAYS) return null;
	return { raw: normalized, amount, unit };
}

function pluralize(count: number, singular: string, plural = `${singular}s`): string {
	return `${count} ${count === 1 ? singular : plural}`;
}

function formatUtcDateTime(value: string): string {
	const parsed = new Date(value);
	if (Number.isNaN(parsed.getTime())) return value;

	const year = String(parsed.getUTCFullYear());
	const month = String(parsed.getUTCMonth() + 1).padStart(2, "0");
	const day = String(parsed.getUTCDate()).padStart(2, "0");
	const hours = String(parsed.getUTCHours()).padStart(2, "0");
	const minutes = String(parsed.getUTCMinutes()).padStart(2, "0");
	return `${year}-${month}-${day} ${hours}:${minutes} UTC`;
}

function repoStatsLabel(summary: RepoSummary): string {
	const lastCommit = summary.latestDate ? formatUtcDateTime(summary.latestDate) : "unknown";
	return `${pluralize(summary.commitCount, "commit")}; last commit ${lastCommit}`;
}

function formatRepoActivity(summary: RepoSummary): string {
	return `${summary.repoFullName} — ${repoStatsLabel(summary)}.`;
}

function cleanCommitText(value: string): string {
	return normalizeSpaces(value);
}

function normalizeSpaces(value: string): string {
	return value.replace(/\s+/gu, " ").trim();
}

function normalizeTypo(value: string): string {
	return value
		.replace(/\boveride\b/giu, "override")
		.replace(/\brefrence\b/giu, "reference")
		.replace(/\bprivage\b/giu, "private")
		.replace(/\bcfg\b/giu, "config");
}

function isMergeCommit(headline: string): boolean {
	return /^merge\b/iu.test(headline);
}

function isVersionCommit(headline: string): boolean {
	return /^(version|release|bump)\b/iu.test(headline) || /\bversion bump\b/iu.test(headline);
}

function isDocsOnlyPath(path: string): boolean {
	const lower = path.toLowerCase();
	return (
		lower.endsWith(".md") ||
		lower.endsWith(".rst") ||
		lower.endsWith(".adoc") ||
		lower.startsWith("docs/") ||
		lower.startsWith("doc/") ||
		lower === "readme.md" ||
		lower.endsWith("/readme.md") ||
		lower === "changelog.md"
	);
}

function isPlanPath(path: string): boolean {
	const lower = path.toLowerCase();
	return lower.startsWith("plan/") || lower.startsWith("plans/");
}

function isTestPath(path: string): boolean {
	const lower = path.toLowerCase();
	return (
		lower.startsWith("tests/") ||
		lower.includes("/__tests__/") ||
		lower.includes("/test/") ||
		lower.includes("/tests/") ||
		/(^|\/)(test|spec)[._-]/u.test(lower) ||
		/(_test|_spec)\.[a-z0-9]+$/u.test(lower)
	);
}

function isSupportPath(path: string): boolean {
	const lower = path.toLowerCase();
	return (
		lower === "pyproject.toml" ||
		lower === "package.json" ||
		lower === "package-lock.json" ||
		lower === "pnpm-lock.yaml" ||
		lower === "yarn.lock" ||
		lower === "uv.lock" ||
		lower === "requirements.txt" ||
		lower === "poetry.lock" ||
		lower === "dockerfile" ||
		lower.endsWith("/dockerfile") ||
		lower === "deploy.sh" ||
		lower.startsWith(".github/")
	);
}

function isMetaPath(path: string): boolean {
	return isPlanPath(path) || isDocsOnlyPath(path);
}

function isCodePath(path: string): boolean {
	return !isMetaPath(path) && !isTestPath(path) && !isSupportPath(path);
}

type ExecFileError = NodeJS.ErrnoException & {
	stdout?: string;
	stderr?: string;
};

function extractCommandError(error: unknown): string {
	if (!error || typeof error !== "object") {
		return String(error);
	}

	const err = error as ExecFileError;
	const detail = [err.stderr, err.stdout, err.message]
		.map((value) => value?.trim())
		.find((value): value is string => Boolean(value));

	return detail ?? "Command failed.";
}

async function runCommand(command: string, args: string[], options?: { cwd?: string; env?: NodeJS.ProcessEnv }): Promise<string> {
	try {
		const { stdout } = await execFileAsync(command, args, {
			cwd: options?.cwd,
			env: {
				...process.env,
				GH_PAGER: "cat",
				GH_NO_UPDATE_NOTIFIER: "1",
				...options?.env,
			},
			encoding: "utf8",
			maxBuffer: 32 * 1024 * 1024,
		});
		return stdout.trim();
	} catch (error) {
		throw new Error(extractCommandError(error));
	}
}

async function ensureGhAuth(): Promise<void> {
	try {
		await runCommand("gh", ["auth", "status"]);
	} catch (error) {
		const detail = error instanceof Error ? error.message : String(error);
		throw new Error(`GitHub CLI is not authenticated. Run \`gh auth login\` first. ${detail}`);
	}
}

async function getViewerLogin(): Promise<string> {
	return runCommand("gh", ["api", "user", "--jq", ".login"]);
}

async function getRepoCloneUrl(repoFullName: string): Promise<string> {
	return runCommand("gh", ["repo", "view", repoFullName, "--json", "sshUrl", "--jq", ".sshUrl"]);
}

async function getAccessibleOrgs(): Promise<string[]> {
	const raw = await runCommand("gh", ["api", "user/orgs"]);
	const payload = JSON.parse(raw) as Array<{ login?: string }>;
	return payload.map((entry) => entry.login).filter((value): value is string => !!value);
}

function parseSearchItems(raw: string): SearchCommit[] {
	const payload = JSON.parse(raw) as {
		items?: Array<{
			sha?: string;
			repository?: { full_name?: string; name?: string };
			commit?: { committer?: { date?: string }; message?: string };
		}>;
		message?: string;
	};

	if (payload.message?.toLowerCase().includes("secondary rate limit")) {
		throw new Error("GitHub search hit a secondary rate limit. Please wait a few minutes and try again.");
	}

	return (payload.items ?? [])
		.map((item) => {
			const repoFullName = item.repository?.full_name?.trim();
			const sha = item.sha?.trim();
			const date = item.commit?.committer?.date?.trim();
			const headline = normalizeSpaces(normalizeTypo((item.commit?.message ?? "").split("\n")[0] ?? ""));
			if (!repoFullName || !sha || !date || !headline) return null;
			return {
				repoFullName,
				repoName: repoFullName.split("/")[1] ?? repoFullName,
				sha,
				date,
				headline,
			};
		})
		.filter((value): value is SearchCommit => !!value);
}

async function sleep(ms: number): Promise<void> {
	await new Promise((resolve) => setTimeout(resolve, ms));
}

async function searchOrgCommits(user: string, org: string, sinceIsoDate: string): Promise<SearchCommit[]> {
	const results: SearchCommit[] = [];
	const seen = new Set<string>();

	for (let page = 1; page <= 10; page++) {
		const raw = await runCommand("gh", [
			"api",
			"search/commits",
			"-X",
			"GET",
			"-f",
			`q=author:${user} org:${org} committer-date:>=${sinceIsoDate}`,
			"-f",
			"per_page=100",
			"-f",
			`page=${page}`,
			"-H",
			"Accept: application/vnd.github.cloak-preview+json",
		]);

		const items = parseSearchItems(raw);
		for (const item of items) {
			const key = `${item.repoFullName}:${item.sha}`;
			if (!seen.has(key)) {
				seen.add(key);
				results.push(item);
			}
		}

		if (items.length < 100) break;
		await sleep(350);
	}

	return results.sort((a, b) => b.date.localeCompare(a.date));
}

async function cloneRepo(repoFullName: string, parentDir: string): Promise<string> {
	const targetDir = join(parentDir, repoFullName.replace(/\//gu, "__"));
	const repoUrl = await getRepoCloneUrl(repoFullName);
	await runCommand("git", [
		"clone",
		"--quiet",
		"--filter=blob:none",
		repoUrl,
		targetDir,
	], {
		env: {
			GIT_TERMINAL_PROMPT: "0",
			GCM_INTERACTIVE: "Never",
			GIT_SSH_COMMAND: "ssh -o BatchMode=yes",
		},
	});
	return targetDir;
}

async function listRepoAuthoredCommits(repoDir: string, repoFullName: string, author: string, sinceIso: string): Promise<SearchCommit[]> {
	const raw = await runCommand("git", [
		"log",
		`--since=${sinceIso}`,
		`--author=${author}`,
		"--format=%H%x09%cI%x09%s",
		"--all",
	], { cwd: repoDir });

	if (!raw) return [];

	return raw
		.split("\n")
		.map((line) => line.trim())
		.filter(Boolean)
		.map((line) => {
			const [sha, date, ...headlineParts] = line.split("\t");
			const headline = normalizeSpaces(normalizeTypo(headlineParts.join("\t")));
			if (!sha || !date || !headline) return null;
			return {
				repoFullName,
				repoName: repoFullName.split("/")[1] ?? repoFullName,
				sha,
				date,
				headline,
			};
		})
		.filter((value): value is SearchCommit => !!value)
		.sort((a, b) => b.date.localeCompare(a.date));
}

function mergeCommits(primary: SearchCommit[], secondary: SearchCommit[]): SearchCommit[] {
	const merged = new Map<string, SearchCommit>();
	for (const commit of [...primary, ...secondary]) {
		if (!merged.has(commit.sha)) {
			merged.set(commit.sha, commit);
		}
	}
	return [...merged.values()].sort((a, b) => b.date.localeCompare(a.date));
}

function parseCommitMetadata(raw: string): { sha: string; date: string; headline: string; body: string } {
	const lines = raw.split("\n");
	const sha = lines[0]?.trim() ?? "";
	const date = lines[1]?.trim() ?? "";
	const headline = normalizeSpaces(normalizeTypo(lines[2]?.trim() ?? ""));
	const body = normalizeSpaces(normalizeTypo(lines.slice(3).join(" ")));
	return { sha, date, headline, body };
}

function parseNumstat(raw: string): CommitFileStat[] {
	return raw
		.split("\n")
		.map((line) => line.trim())
		.filter(Boolean)
		.map((line) => {
			const [additionsRaw, deletionsRaw, ...pathParts] = line.split("\t");
			const path = pathParts.join("\t").trim();
			if (!path) return null;
			const additions = additionsRaw === "-" ? 0 : Number.parseInt(additionsRaw ?? "0", 10);
			const deletions = deletionsRaw === "-" ? 0 : Number.parseInt(deletionsRaw ?? "0", 10);
			return {
				path,
				additions: Number.isFinite(additions) ? additions : 0,
				deletions: Number.isFinite(deletions) ? deletions : 0,
			};
		})
		.filter((value): value is CommitFileStat => !!value);
}

async function inspectCommit(repoDir: string, commit: SearchCommit): Promise<CommitDetail> {
	const marker = "__END_META__";
	const metaRaw = await runCommand("git", [
		"show",
		"--format=%H%n%cI%n%s%n%b%n__END_META__",
		"--quiet",
		commit.sha,
	], { cwd: repoDir });
	const numstatRaw = await runCommand("git", ["show", "--format=", "--numstat", commit.sha], { cwd: repoDir });

	const meta = parseCommitMetadata(metaRaw.replace(`\n${marker}`, ""));
	const files = parseNumstat(numstatRaw);
	const paths = files.map((file) => file.path);
	const codePaths = paths.filter(isCodePath);
	const testPaths = paths.filter(isTestPath);
	const metaPaths = paths.filter(isMetaPath);
	const supportPaths = paths.filter(isSupportPath);
	const totalAdditions = files.reduce((sum, file) => sum + file.additions, 0);
	const totalDeletions = files.reduce((sum, file) => sum + file.deletions, 0);
	const totalChanges = totalAdditions + totalDeletions;

	return {
		repoFullName: commit.repoFullName,
		repoName: commit.repoName,
		sha: meta.sha || commit.sha,
		date: meta.date || commit.date,
		headline: meta.headline || commit.headline,
		body: meta.body,
		files,
		paths,
		codePaths,
		testPaths,
		metaPaths,
		supportPaths,
		totalAdditions,
		totalDeletions,
		totalChanges,
		impact: "low",
	};
}

function summarizeRepo(repoFullName: string, commits: CommitDetail[]): RepoSummary {
	const repoName = repoFullName.split("/")[1] ?? repoFullName;
	const sortedCommits = [...commits].sort((a, b) => b.date.localeCompare(a.date));
	const activityCommits = sortedCommits.map((commit) => ({
		date: commit.date,
		title: cleanCommitText(commit.headline),
		body: cleanCommitText(commit.body),
	}));

	return {
		repoName,
		repoFullName,
		activityCommits,
		latestDate: sortedCommits[0]?.date ?? "",
		commitCount: sortedCommits.length,
	};
}

function buildActivitySnapshot(org: string, range: string, summaries: RepoSummary[]): string {
	const lines: string[] = [];
	lines.push(`## Activity snapshot`);
	lines.push("");

	if (summaries.length === 0) {
		lines.push(`- No repos changed in ${org} over ${range}.`);
		return lines.join("\n");
	}

	lines.push(`- ${pluralize(summaries.length, "repo")} had changes in ${org} over ${range}.`);
	summaries.forEach((summary) => {
		lines.push(`- ${formatRepoActivity(summary)}`);
		summary.activityCommits.forEach((commit) => {
			lines.push(`  - ${formatUtcDateTime(commit.date)} — ${commit.title}`);
			if (commit.body) {
				lines.push(`    - ${commit.body}`);
			}
		});
		lines.push("");
	});

	return lines.join("\n").trim();
}

function stripFence(value: string): string {
	return value
		.replace(/^```[a-z0-9_-]*\s*/iu, "")
		.replace(/\s*```$/u, "")
		.trim();
}

function extractResponseText(response: Awaited<ReturnType<typeof complete>>): string {
	return stripFence(
		response.content
			.filter((part): part is { type: "text"; text: string } => part.type === "text")
			.map((part) => part.text)
			.join("\n")
	);
}

function buildNarrativePrompt(org: string, range: string, snapshot: string): string {
	return [
		"You are writing an engineering standup update for cross-functional teammates.",
		"The audience includes non-native English speakers.",
		"Use only the facts in the activity snapshot below.",
		"Do not invent work, impact, risks, or outcomes that are not supported by the snapshot.",
		"Written version and spoken-ready version must be derived from the activity snapshot only.",
		"Use simple, direct English. Keep sentences short.",
		"Keep technical meaning, but explain jargon in more common words when possible.",
		"Include every repo from the activity snapshot in the written version.",
		"If a repo mainly has maintenance, infra, monitoring, docs, or config work, still include one short bullet.",
		"Remove duplication. Merge related commits from the same repo into 1-3 bullets.",
		"Prefer describing user-visible, operational, or workflow impact when the commit text supports it.",
		"Avoid vague phrases like 'improved things' or 'various fixes'. Say what changed.",
		"For the spoken-ready version, keep it natural and easy to read aloud, but still simple.",
		"Use this exact structure:",
		"## Written version",
		"",
		"1. <repo> (<stats copied from snapshot>)",
		"- <bullet>",
		"",
		"## Spoken-ready version",
		"",
		`- ${SPOKEN_INTRO}`,
		"",
		"1. <repo>",
		"- <spoken bullet>",
		"",
		`- ${SPOKEN_OUTRO}`,
		"",
		"Do not repeat the activity snapshot in the answer.",
		"Do not use code fences.",
		"",
		`Activity snapshot for ${org} over ${range}:`,
		"",
		snapshot,
	].join("\n");
}

async function generateNarrativeSections(ctx: ExtensionCommandContext, org: string, range: string, snapshot: string): Promise<string> {
	const candidates = [
		ctx.model ?? null,
		getModel("openai", "gpt-5.2") ?? null,
		getModel("anthropic", "claude-sonnet-4-5") ?? null,
	].filter((model): model is NonNullable<typeof model> => Boolean(model));

	const seen = new Set<string>();
	for (const model of candidates) {
		const key = `${model.provider}/${model.id}`;
		if (seen.has(key)) continue;
		seen.add(key);

		const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
		if (!auth.ok || !auth.apiKey) {
			continue;
		}

		const response = await complete(
			model,
			{
				messages: [{
					role: "user",
					content: [{ type: "text", text: buildNarrativePrompt(org, range, snapshot) }],
					timestamp: Date.now(),
				}],
			},
			{
				apiKey: auth.apiKey,
				headers: auth.headers,
				signal: ctx.signal,
			}
		);

		const text = extractResponseText(response);
		if (text.includes("## Written version") && text.includes("## Spoken-ready version")) {
			return text;
		}
	}

	throw new Error("No configured model is available to generate the standup summary.");
}

async function buildReport(ctx: ExtensionCommandContext, org: string, range: string, summaries: RepoSummary[], warnings: string[]): Promise<ReportBuild> {
	const snapshot = buildActivitySnapshot(org, range, summaries);
	const sections = summaries.length === 0
		? [`## Written version`, "", `- No updates found for ${org} in ${range}.`, "", `## Spoken-ready version`, "", `- ${SPOKEN_INTRO}`, "", `- I did not have any updates in ${org} over ${range}.`, "", `- ${SPOKEN_OUTRO}`].join("\n")
		: await generateNarrativeSections(ctx, org, range, snapshot);

	const markdown = [snapshot, sections, warnings.length > 0 ? `> Note: ${warnings.join(" ")}` : ""]
		.filter(Boolean)
		.join("\n\n")
		.trim();

	return {
		markdown,
		warnings,
	};
}

async function resolveOrgName(input: string): Promise<string> {
	const orgs = await getAccessibleOrgs();
	const matched = orgs.find((org) => org.toLowerCase() === input.toLowerCase());
	return matched ?? input;
}

async function sinceIsoDate(range: RangeSpec): Promise<string> {
	const dateArg = range.unit === "m" ? `${range.amount} month${range.amount === 1 ? "" : "s"} ago` : `${range.amount} day${range.amount === 1 ? "" : "s"} ago`;
	return runCommand("date", ["-u", "-d", dateArg, "+%Y-%m-%d"]);
}

function emitReport(pi: ExtensionAPI, markdown: string, details?: Record<string, unknown>): void {
	pi.sendMessage({
		customType: REPORT_MESSAGE_TYPE,
		content: markdown,
		display: true,
		details: details,
	});
}

function pickRandomLoadingMessage(): string {
	return LOADING_MESSAGES[Math.floor(Math.random() * LOADING_MESSAGES.length)]!;
}

function renderLoadingWidgetLine(ctx: ExtensionCommandContext, frame: string, message: string): string {
	return [ctx.ui.theme.fg("dim", "gen-standup:"), ctx.ui.theme.fg("muted", frame), ctx.ui.theme.fg("dim", message)].join(" ");
}

function startLoadingWidget(ctx: ExtensionCommandContext): () => void {
	let frameIndex = 0;
	let tickCount = 0;
	let message = pickRandomLoadingMessage();

	const render = () => {
		ctx.ui.setStatus(STATUS_KEY, undefined);
		ctx.ui.setWidget(STATUS_KEY, [renderLoadingWidgetLine(ctx, LOADING_SPINNER_FRAMES[frameIndex]!, message)]);
	};

	render();

	const timer = setInterval(() => {
		frameIndex = (frameIndex + 1) % LOADING_SPINNER_FRAMES.length;
		tickCount += 1;

		if (tickCount % LOADING_SPINNER_FRAMES.length === 0) {
			message = pickRandomLoadingMessage();
		}

		render();
	}, 80);

	return () => {
		clearInterval(timer);
		ctx.ui.setStatus(STATUS_KEY, undefined);
		ctx.ui.setWidget(STATUS_KEY, undefined);
	};
}

function setStatus(ctx: ExtensionCommandContext, value?: string): void {
	if (!ctx.hasUI) return;
	if (!value) {
		ctx.ui.setStatus(STATUS_KEY, undefined);
		ctx.ui.setWidget(STATUS_KEY, undefined);
	}
}

function notify(ctx: ExtensionCommandContext, message: string, level: "info" | "warning" | "error"): void {
	if (!ctx.hasUI) return;
	ctx.ui.notify(message, level);
}

function parseArgs(input: string): { org: string; range: RangeSpec } | null {
	const parts = input.trim().split(/\s+/u).filter(Boolean);
	if (parts.length < 2) return null;
	const [org, rangeRaw] = parts;
	const range = parseRange(rangeRaw ?? "");
	if (!org || !range) return null;
	return { org, range };
}

export default function genStandupExtension(pi: ExtensionAPI) {
	let stopLoadingWidget: (() => void) | undefined;

	const clearLoadingWidget = () => {
		stopLoadingWidget?.();
		stopLoadingWidget = undefined;
	};

	pi.on("session_shutdown", () => {
		clearLoadingWidget();
	});

	pi.registerMessageRenderer(REPORT_MESSAGE_TYPE, (message) => {
		const container = new Container();
		container.addChild(new Markdown(String(message.content ?? ""), 0, 0, getMarkdownTheme()));
		return container;
	});

	pi.registerCommand("gen-standup", {
		description: "Generate a standup report from real commit snapshots, then use an LLM to write simple written and spoken versions: /gen-standup <org> <Nd|Nm> (max 3m)",
		handler: async (args, ctx) => {
			const parsed = parseArgs(args);
			if (!parsed) {
				notify(ctx, "Usage: /gen-standup <org> <Nd|Nm> (examples: 7d, 10d, 1m; max 3m / 92d)", "warning");
				return;
			}

			let workspaceDir: string | null = null;
			const warnings: string[] = [];

			try {
				clearLoadingWidget();
				if (ctx.hasUI) {
					stopLoadingWidget = startLoadingWidget(ctx);
				}
				notify(ctx, `Scanning ${parsed.org} commits for ${parsed.range.raw}…`, "info");

				await ensureGhAuth();
				const user = await getViewerLogin();
				const org = await resolveOrgName(parsed.org);
				const since = await sinceIsoDate(parsed.range);
				const searchItems = await searchOrgCommits(user, org, since);

				if (searchItems.length === 0) {
					emitReport(pi, `## Activity snapshot\n\n- No repos changed in ${org} over ${parsed.range.raw}.\n\n## Written version\n\n- No commits found for ${org} in ${parsed.range.raw}.\n\n## Spoken-ready version\n\n- ${SPOKEN_INTRO}\n\n- I did not have any updates in ${org} over ${parsed.range.raw}.\n\n- ${SPOKEN_OUTRO}`, {
						org,
						range: parsed.range.raw,
					});
					return;
				}

				workspaceDir = await mkdtemp(join(tmpdir(), "pi-gen-standup-"));
				const byRepo = new Map<string, SearchCommit[]>();
				for (const item of searchItems) {
					const existing = byRepo.get(item.repoFullName) ?? [];
					existing.push(item);
					byRepo.set(item.repoFullName, existing);
				}

				const summaries: RepoSummary[] = [];
				for (const [repoFullName, repoCommits] of byRepo.entries()) {
					setStatus(ctx, `Inspecting ${repoFullName}…`);
					try {
						const repoDir = await cloneRepo(repoFullName, workspaceDir);
						const repoGitCommits = await listRepoAuthoredCommits(repoDir, repoFullName, user, since);
						const mergedCommits = mergeCommits(repoGitCommits, repoCommits);
						const details: CommitDetail[] = [];
						for (const repoCommit of mergedCommits) {
							const detail = await inspectCommit(repoDir, repoCommit);
							details.push(detail);
						}
						summaries.push(summarizeRepo(repoFullName, details));
					} catch (error) {
						warnings.push(`Could not inspect ${repoFullName}; it was skipped.`);
					}
				}

				summaries.sort((a, b) => b.latestDate.localeCompare(a.latestDate));
				setStatus(ctx, "Writing standup from commit snapshot…");
				const report = await buildReport(ctx, org, parsed.range.raw, summaries, warnings);
				emitReport(pi, report.markdown, {
					org,
					range: parsed.range.raw,
					repos: summaries.map((summary) => summary.repoFullName),
					warnings,
				});
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				notify(ctx, message, "error");
			} finally {
				clearLoadingWidget();
				if (workspaceDir) {
					await rm(workspaceDir, { recursive: true, force: true });
				}
			}
		},
	});
}
