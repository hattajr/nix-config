import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AutocompleteItem } from "@earendil-works/pi-tui";
import { StringEnum } from "@earendil-works/pi-ai";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { Type } from "typebox";

type IssueStatus = "todo" | "progress" | "blocked" | "complete";

type IssueEntry = {
  number: string;
  path: string;
};

type IssueStatusRow = {
  issue: string;
  status: IssueStatus;
  note: string;
  path: string;
};

type IssueIndexState = {
  indexPath: string;
  content: string;
  issueEntries: IssueEntry[];
  statusRows: Map<string, IssueStatusRow>;
};

type QaExistingFindingRef = {
  issue: string;
  findingId: string;
  title: string;
};

type QaFindingInput = {
  issue: string;
  title: string;
  repro?: string;
  expected?: string;
  actual?: string;
  impact: string;
};

type QaFindingStatusInput = {
  findingId: string;
  note?: string;
};

type QaTargetPlan =
  | {
    kind: "initial" | "recheck";
    reportExists: boolean;
    openFindings: Map<string, QaExistingFindingRef[]>;
    targetIssues: IssueEntry[];
  }
  | {
    kind: "no-complete";
    reportExists: boolean;
    openFindings: Map<string, QaExistingFindingRef[]>;
  }
  | {
    kind: "waiting-for-build";
    reportExists: boolean;
    openFindings: Map<string, QaExistingFindingRef[]>;
    pendingIssues: Array<{ issue: IssueEntry; status: IssueStatus }>;
  }
  | {
    kind: "stale-report";
    reportExists: boolean;
    openFindings: Map<string, QaExistingFindingRef[]>;
    missingIssueNumbers: string[];
  };

type BuildState = {
  active: boolean;
  slug: string;
  lastStatusDigest: string;
  lastBatchKey: string | null;
  lastIssueNumbers: string[];
  stopReason?: string | null;
  updatedAt: number;
};

type SessionCustomEntry = {
  type?: string;
  customType?: string;
  data?: unknown;
};

type WorktreeSetupHookState =
  | { kind: "available" }
  | { kind: "absent"; reason: string };

type ParallelQaExecutionMode =
  | { kind: "worktree"; artifactSource: "tracked-head" | "hook-snapshot" }
  | { kind: "serial-fallback"; reason: string; unavailablePaths: string[] };

const EXECUTION_STATUS_HEADING = "Execution status";
const BUILD_STATE_ENTRY_TYPE = "issue-build-state";
const SUBAGENT_CONFIG_PATH = join(homedir(), ".pi", "agent", "extensions", "subagent", "config.json");
const ISSUE_STATUS_VALUES: IssueStatus[] = ["todo", "progress", "blocked", "complete"];
const ISSUE_REFERENCE_HINT = "Use a two-digit issue number like `01` or a path containing `/issues/01-...`.";
const QA_REPORT_HEADER = "# QA Report";

function listIssueSlugs(cwd: string): string[] {
  const plansDir = join(cwd, "PLANS");
  if (!existsSync(plansDir)) return [];
  return readdirSync(plansDir)
    .filter((name) => {
      const path = join(plansDir, name);
      if (!statSync(path, { throwIfNoEntry: false })?.isDirectory()) return false;
      return existsSync(join(path, "issues", "index.md"));
    })
    .sort();
}

function extractSlug(input: string): string {
  const trimmed = input.trim();
  if (!trimmed) return "";
  const match = trimmed.match(/PLANS\/([^/\s]+)\//);
  if (match) return match[1] ?? "";
  return trimmed.replace(/^@/, "").replace(/^PLANS\//, "").split(/[\/\s]/)[0] ?? "";
}

function normalizeIssueNumber(value: string): string {
  const digits = value.replace(/\D/g, "");
  if (!digits) return "";
  return digits.padStart(2, "0");
}

function extractIssueNumber(value: string): string {
  const pathMatch = value.match(/issues\/(\d{2})-/);
  if (pathMatch?.[1]) return pathMatch[1];
  return normalizeIssueNumber(value);
}

function issuesIndexPath(cwd: string, slug: string): string {
  return join(cwd, "PLANS", slug, "issues", "index.md");
}

function qaReportAbsolutePath(cwd: string, slug: string): string {
  return join(cwd, "PLANS", slug, "qa_report.md");
}

function qaReportRepoRelativePath(slug: string): string {
  return `PLANS/${slug}/qa_report.md`;
}

function readIssuesIndex(cwd: string, slug: string): string | null {
  const path = issuesIndexPath(cwd, slug);
  if (!existsSync(path)) return null;
  return readFileSync(path, "utf-8").replace(/\r\n/g, "\n");
}

function readQaReport(cwd: string, slug: string): string | null {
  const path = qaReportAbsolutePath(cwd, slug);
  if (!existsSync(path)) return null;
  return readFileSync(path, "utf-8").replace(/\r\n/g, "\n");
}

function gitCommandSucceeds(cwd: string, args: string[]): boolean {
  try {
    execFileSync("git", ["-C", cwd, ...args], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function isRepoPathCommittedAtHead(cwd: string, repoRelativePath: string): boolean {
  return gitCommandSucceeds(cwd, ["cat-file", "-e", `HEAD:${repoRelativePath}`]);
}

function repoPathMatchesHead(cwd: string, repoRelativePath: string): boolean {
  return gitCommandSucceeds(cwd, ["diff", "--quiet", "--", repoRelativePath])
    && gitCommandSucceeds(cwd, ["diff", "--quiet", "--cached", "--", repoRelativePath]);
}

function readGitCommandOutput(cwd: string, args: string[]): string | null {
  try {
    return execFileSync("git", ["-C", cwd, ...args], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return null;
  }
}

function resolveRepoRoot(cwd: string): string {
  return readGitCommandOutput(cwd, ["rev-parse", "--show-toplevel"]) || cwd;
}

function repoHasTrackedEntries(cwd: string, repoRelativePath: string): boolean {
  return Boolean(readGitCommandOutput(cwd, ["ls-files", "--", repoRelativePath]));
}

function resolveConfiguredWorktreeSetupHookPath(repoRoot: string, configuredPath: string): string | null {
  const trimmed = configuredPath.trim();
  if (!trimmed) return null;
  if (trimmed.startsWith("~/")) return join(homedir(), trimmed.slice(2));
  if (isAbsolute(trimmed)) return trimmed;
  if (trimmed.includes("/") || trimmed.includes("\\")) return resolve(repoRoot, trimmed);
  return null;
}

function getWorktreeSetupHookState(repoRoot: string): WorktreeSetupHookState {
  const configStat = statSync(SUBAGENT_CONFIG_PATH, { throwIfNoEntry: false });
  if (!configStat?.isFile()) {
    return {
      kind: "absent",
      reason: `missing config at \`${SUBAGENT_CONFIG_PATH}\``,
    };
  }

  let parsed: { worktreeSetupHook?: unknown };
  try {
    parsed = JSON.parse(readFileSync(SUBAGENT_CONFIG_PATH, "utf-8")) as { worktreeSetupHook?: unknown };
  } catch {
    return {
      kind: "absent",
      reason: `invalid JSON in \`${SUBAGENT_CONFIG_PATH}\``,
    };
  }

  const configuredPath = typeof parsed.worktreeSetupHook === "string"
    ? parsed.worktreeSetupHook.trim()
    : "";
  if (!configuredPath) {
    return {
      kind: "absent",
      reason: `\`${SUBAGENT_CONFIG_PATH}\` does not define \`worktreeSetupHook\``,
    };
  }

  const resolvedPath = resolveConfiguredWorktreeSetupHookPath(repoRoot, configuredPath);
  if (!resolvedPath) {
    return {
      kind: "absent",
      reason: `configured hook path \`${configuredPath}\` is not absolute, \`~/...\`, or repo-relative`,
    };
  }

  const hookStat = statSync(resolvedPath, { throwIfNoEntry: false });
  if (!hookStat?.isFile()) {
    return {
      kind: "absent",
      reason: `configured hook file not found at \`${resolvedPath}\``,
    };
  }

  return { kind: "available" };
}

function resolveParallelQaExecutionMode(cwd: string, slug: string, issuePaths: string[], includeQaReport: boolean): ParallelQaExecutionMode {
  const repoRoot = resolveRepoRoot(cwd);
  const requiredPaths = Array.from(new Set([
    `PLANS/${slug}/issues/index.md`,
    ...issuePaths,
    ...(includeQaReport ? [qaReportRepoRelativePath(slug)] : []),
  ]));
  const unavailablePaths = requiredPaths.filter((path) => !isRepoPathCommittedAtHead(repoRoot, path));
  const dirtyTrackedPaths = requiredPaths.filter((path) => isRepoPathCommittedAtHead(repoRoot, path) && !repoPathMatchesHead(repoRoot, path));
  if (unavailablePaths.length === 0 && dirtyTrackedPaths.length === 0) {
    return { kind: "worktree", artifactSource: "tracked-head" };
  }

  const missingLocalPaths = requiredPaths.filter((path) => !existsSync(join(repoRoot, path)));
  const worktreeSetupHook = getWorktreeSetupHookState(repoRoot);
  const plansTreeHasTrackedEntries = repoHasTrackedEntries(repoRoot, "PLANS");
  if (unavailablePaths.length > 0 && worktreeSetupHook.kind === "available" && !plansTreeHasTrackedEntries && missingLocalPaths.length === 0) {
    return { kind: "worktree", artifactSource: "hook-snapshot" };
  }

  const details: string[] = [];
  const reasonParts: string[] = [];
  if (unavailablePaths.length > 0) {
    const unavailableListed = unavailablePaths.map((path) => `\`${path}\``).join(", ");
    reasonParts.push(`Required planning artifacts are not committed at HEAD: ${unavailableListed}.`);
  }
  if (dirtyTrackedPaths.length > 0) {
    const dirtyListed = dirtyTrackedPaths.map((path) => `\`${path}\``).join(", ");
    reasonParts.push(`These tracked planning artifacts differ from HEAD in the current checkout: ${dirtyListed}.`);
    details.push("Isolated worktrees branch from HEAD, so they would read stale planning contracts instead of the current local files.");
  }
  if (worktreeSetupHook.kind !== "available") {
    details.push(`No usable \`pi-subagents\` worktree setup hook is available (${worktreeSetupHook.reason}).`);
  }
  if (plansTreeHasTrackedEntries) {
    details.push("The local `PLANS/` tree already contains tracked entries, so the snapshot hook will not synthetic-copy it into isolated worktrees.");
  }
  if (missingLocalPaths.length > 0) {
    const missingLocalListed = missingLocalPaths.map((path) => `\`${path}\``).join(", ");
    details.push(`The current checkout is also missing ${missingLocalListed}, so there is nothing local to snapshot into isolated worktrees.`);
  } else if (unavailablePaths.length > 0) {
    details.push("The current checkout has these planning artifacts locally, but worktree execution can only see them when a setup hook snapshots them into each worktree.");
  }
  return {
    kind: "serial-fallback",
    unavailablePaths,
    reason: `${reasonParts.join(" ")} ${details.join(" ")} Falling back to serial QA execution in the main checkout.`.trim(),
  };
}

function parseIssueEntries(indexContent: string): IssueEntry[] {
  const entries = new Map<string, string>();
  const patterns = [
    /`(PLANS\/[^`]+\/issues\/(\d{2})-[^`]+\.md)`/g,
    /\[[^\]]*\]\((PLANS\/[^)\s]+\/issues\/(\d{2})-[^)]+\.md)\)/g,
    /\b(PLANS\/[^\s`\)\]]+\/issues\/(\d{2})-[^\s`\)\]]+\.md)\b/g,
  ];

  for (const pattern of patterns) {
    for (const match of indexContent.matchAll(pattern)) {
      const fullPath = match[1]?.trim();
      const number = match[2]?.trim();
      if (fullPath && number && !entries.has(number)) entries.set(number, fullPath);
    }
  }

  return Array.from(entries.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([number, path]) => ({ number, path }));
}

function splitLines(markdown: string): string[] {
  return markdown.replace(/\r\n/g, "\n").split("\n");
}

function parseHeading(line: string): { level: number; text: string } | null {
  const match = line.match(/^(#{1,6})\s+(.*?)\s*$/);
  if (!match) return null;
  const rawText = (match[2] ?? "").trim().replace(/\s+#+\s*$/, "").trim();
  return { level: match[1]?.length ?? 0, text: rawText };
}

function findSectionRange(lines: string[], heading: string): { start: number; end: number; level: number } | null {
  const target = heading.trim().toLowerCase();
  for (let i = 0; i < lines.length; i += 1) {
    const parsed = parseHeading(lines[i] ?? "");
    if (!parsed || parsed.text.toLowerCase() !== target) continue;
    let end = lines.length;
    for (let j = i + 1; j < lines.length; j += 1) {
      const candidate = parseHeading(lines[j] ?? "");
      if (candidate && candidate.level <= parsed.level) {
        end = j;
        break;
      }
    }
    return { start: i, end, level: parsed.level };
  }
  return null;
}

function sectionBody(markdown: string, heading: string): string {
  const lines = splitLines(markdown);
  const range = findSectionRange(lines, heading);
  if (!range) return "";
  return lines.slice(range.start + 1, range.end).join("\n").trim();
}

function sanitizeNote(value: string | undefined): string {
  return (value ?? "")
    .replace(/\r\n/g, "\n")
    .replace(/\n+/g, " / ")
    .replace(/\|/g, "¦")
    .replace(/\s+/g, " ")
    .trim();
}

function parseExecutionStatus(indexContent: string, issueEntries: IssueEntry[]): Map<string, IssueStatusRow> {
  const rows = new Map(issueEntries.map((entry) => [entry.number, {
    issue: entry.number,
    status: "todo" as IssueStatus,
    note: "",
    path: entry.path,
  }]));
  const body = sectionBody(indexContent, EXECUTION_STATUS_HEADING);
  if (!body) return rows;

  for (const rawLine of body.split("\n")) {
    const line = rawLine.trim();
    if (!line.startsWith("|")) continue;

    const cells = line
      .replace(/^\|/, "")
      .replace(/\|$/, "")
      .split("|")
      .map((cell) => cell.trim());
    if (cells.length < 4) continue;
    if (/^[-: ]+$/.test(cells[0] ?? "")) continue;
    if ((cells[0] ?? "").toLowerCase() === "issue") continue;

    const issue = normalizeIssueNumber(cells[0] ?? "");
    const status = (cells[1] ?? "").toLowerCase() as IssueStatus;
    if (!issue || !ISSUE_STATUS_VALUES.includes(status) || !rows.has(issue)) continue;

    const noteCell = cells[3] ?? "";
    rows.set(issue, {
      issue,
      status,
      note: noteCell === "—" ? "" : sanitizeNote(noteCell),
      path: rows.get(issue)?.path ?? "",
    });
  }

  return rows;
}

function loadIssueIndexState(cwd: string, slug: string): IssueIndexState | null {
  const content = readIssuesIndex(cwd, slug);
  if (!content) return null;
  const issueEntries = parseIssueEntries(content);
  const statusRows = parseExecutionStatus(content, issueEntries);
  return {
    indexPath: issuesIndexPath(cwd, slug),
    content,
    issueEntries,
    statusRows,
  };
}

function issueEntriesMissingMessage(slug: string): string {
  return `No parseable issue file paths found in PLANS/${slug}/issues/index.md. Add backticked paths or markdown links to PLANS/${slug}/issues/NN-*.md.`;
}

function parseCurrentOpenQaFindings(reportContent: string): Map<string, QaExistingFindingRef[]> {
  const openById = new Map<string, QaExistingFindingRef>();

  for (const rawLine of reportContent.replace(/\r\n/g, "\n").split("\n")) {
    const openMatch = rawLine.match(/^\s*-\s+\[OPEN\]\[issue:(\d{1,2})\]\[(Q\d+-\d{2}-\d{2})\]\s+(.+?)\s*$/);
    if (openMatch) {
      const issue = normalizeIssueNumber(openMatch[1] ?? "");
      const findingId = (openMatch[2] ?? "").toUpperCase();
      const title = sanitizeReportText(openMatch[3] ?? "");
      if (issue && findingId && title && !openById.has(findingId)) {
        openById.set(findingId, { issue, findingId, title });
      }
      continue;
    }

    const closedMatch = rawLine.match(/^\s*-\s+\[CLOSED\]\[issue:(\d{1,2})\]\[(Q\d+-\d{2}-\d{2})\]\b/);
    if (closedMatch?.[2]) {
      openById.delete((closedMatch[2] ?? "").toUpperCase());
    }
  }

  const grouped = new Map<string, QaExistingFindingRef[]>();
  for (const finding of openById.values()) {
    const current = grouped.get(finding.issue) ?? [];
    current.push(finding);
    grouped.set(finding.issue, current);
  }

  for (const findings of grouped.values()) {
    findings.sort((a, b) => a.findingId.localeCompare(b.findingId));
  }

  return grouped;
}

function selectQaTargetPlan(cwd: string, slug: string, state: IssueIndexState): QaTargetPlan {
  const reportContent = readQaReport(cwd, slug);
  const reportExists = Boolean(reportContent);
  const openFindings = reportContent ? parseCurrentOpenQaFindings(reportContent) : new Map<string, QaExistingFindingRef[]>();

  if (openFindings.size === 0) {
    const targetIssues = state.issueEntries.filter((issue) => state.statusRows.get(issue.number)?.status === "complete");
    if (targetIssues.length === 0) {
      return {
        kind: "no-complete",
        reportExists,
        openFindings,
      };
    }
    return {
      kind: "initial",
      reportExists,
      openFindings,
      targetIssues,
    };
  }

  const issueByNumber = new Map(state.issueEntries.map((issue) => [issue.number, issue]));
  const missingIssueNumbers = Array.from(openFindings.keys())
    .filter((issueNumber) => !issueByNumber.has(issueNumber))
    .sort();
  if (missingIssueNumbers.length > 0) {
    return {
      kind: "stale-report",
      reportExists,
      openFindings,
      missingIssueNumbers,
    };
  }

  const targetIssues = state.issueEntries.filter((issue) => openFindings.has(issue.number));
  const pendingIssues = targetIssues
    .map((issue) => ({
      issue,
      status: state.statusRows.get(issue.number)?.status ?? "todo",
    }))
    .filter(({ status }) => status !== "complete");
  if (pendingIssues.length > 0) {
    return {
      kind: "waiting-for-build",
      reportExists,
      openFindings,
      pendingIssues,
    };
  }

  return {
    kind: "recheck",
    reportExists,
    openFindings,
    targetIssues,
  };
}

function getSlugCompletions(cwd: string, prefix: string): AutocompleteItem[] | null {
  const items = listIssueSlugs(cwd)
    .filter((slug) => slug.startsWith(prefix.trim()))
    .map((slug) => ({ value: slug, label: slug }));
  return items.length > 0 ? items : null;
}

async function pickSlug(args: string, ctx: { cwd: string; ui: { notify: (message: string, level?: string) => void; select: (title: string, options: string[]) => Promise<string | null>; }; }, commandName: string): Promise<string | null> {
  const slug = extractSlug(args);
  if (slug) return slug;
  const known = listIssueSlugs(ctx.cwd);
  if (known.length === 0) {
    ctx.ui.notify("No issue slugs found under PLANS/*/issues/index.md", "warning");
    return null;
  }
  if (known.length === 1) return known[0] ?? null;
  const picked = await ctx.ui.select("Pick an issue slug", known);
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

function getSessionEntries(ctx: { sessionManager: { getBranch?: () => SessionCustomEntry[]; getEntries?: () => SessionCustomEntry[]; }; }): SessionCustomEntry[] {
  if (typeof ctx.sessionManager.getBranch === "function") {
    return ctx.sessionManager.getBranch() ?? [];
  }
  if (typeof ctx.sessionManager.getEntries === "function") {
    return ctx.sessionManager.getEntries() ?? [];
  }
  return [];
}

function loadBuildState(ctx: { sessionManager: { getBranch?: () => SessionCustomEntry[]; getEntries?: () => SessionCustomEntry[]; }; }): BuildState | null {
  let latest: BuildState | null = null;
  for (const entry of getSessionEntries(ctx)) {
    if (entry.type !== "custom" || entry.customType !== BUILD_STATE_ENTRY_TYPE) continue;
    const data = entry.data as Partial<BuildState> | undefined;
    if (!data || typeof data.slug !== "string") continue;
    latest = {
      active: Boolean(data.active),
      slug: data.slug,
      lastStatusDigest: typeof data.lastStatusDigest === "string" ? data.lastStatusDigest : "",
      lastBatchKey: typeof data.lastBatchKey === "string" || data.lastBatchKey === null ? (data.lastBatchKey ?? null) : null,
      lastIssueNumbers: Array.isArray(data.lastIssueNumbers) ? data.lastIssueNumbers.filter((value): value is string => typeof value === "string") : [],
      stopReason: typeof data.stopReason === "string" || data.stopReason === null ? (data.stopReason ?? null) : null,
      updatedAt: typeof data.updatedAt === "number" ? data.updatedAt : 0,
    };
  }
  return latest;
}

function persistBuildState(pi: ExtensionAPI, state: Omit<BuildState, "updatedAt">) {
  pi.appendEntry(BUILD_STATE_ENTRY_TYPE, {
    ...state,
    updatedAt: Date.now(),
  });
}

function pauseActiveBuildForQaCheck(pi: ExtensionAPI, ctx: { sessionManager: { getBranch?: () => SessionCustomEntry[]; getEntries?: () => SessionCustomEntry[]; }; ui: { notify: (message: string, level?: string) => void; }; }) {
  const activeBuild = loadBuildState(ctx);
  if (!activeBuild?.active) return;
  persistBuildState(pi, {
    active: false,
    slug: activeBuild.slug,
    lastStatusDigest: activeBuild.lastStatusDigest,
    lastBatchKey: null,
    lastIssueNumbers: [],
    stopReason: "paused-by-qa-check",
  });
  ctx.ui.notify(`Paused /build ${activeBuild.slug} while starting /qa-check. Run /build ${activeBuild.slug} to resume.`, "info");
}

function uniqueStringsInOrder(values: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    if (!value || seen.has(value)) continue;
    seen.add(value);
    result.push(value);
  }
  return result;
}

function sanitizeReportText(value: string | undefined): string {
  return (value ?? "")
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" / ")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeFindingId(value: string): string {
  return value.trim().toUpperCase();
}

function extractIssueNumberFromFindingId(findingId: string): string {
  const match = normalizeFindingId(findingId).match(/^Q\d+-(\d{2})-(\d{2})$/);
  return match?.[1] ?? "";
}

function nextQaRoundNumber(existingContent: string | null): number {
  if (!existingContent) return 1;
  let max = 0;
  for (const match of existingContent.matchAll(/^##\s+Round\s+(\d+)\b/gm)) {
    const parsed = Number.parseInt(match[1] ?? "", 10);
    if (Number.isFinite(parsed)) max = Math.max(max, parsed);
  }
  return max + 1;
}

function formatIssueList(issueNumbers: string[]): string {
  return issueNumbers.join(", ");
}

function validateQaFindings(findings: QaFindingInput[]): QaFindingInput[] {
  return findings.map((finding) => {
    const issue = extractIssueNumber(finding.issue);
    if (!issue) {
      throw new Error(`Invalid QA finding issue reference '${finding.issue}'. ${ISSUE_REFERENCE_HINT}`);
    }
    const title = sanitizeReportText(finding.title);
    if (!title) {
      throw new Error(`QA finding for issue ${issue} requires a concise title.`);
    }
    const impact = sanitizeReportText(finding.impact);
    if (!impact) {
      throw new Error(`QA finding '${title}' for issue ${issue} requires an impact summary.`);
    }
    return {
      issue,
      title,
      repro: sanitizeReportText(finding.repro),
      expected: sanitizeReportText(finding.expected),
      actual: sanitizeReportText(finding.actual),
      impact,
    };
  });
}

function validateQaFindingStatusList(kind: "stillOpen" | "closed", items: QaFindingStatusInput[]): QaFindingStatusInput[] {
  const seen = new Set<string>();
  return items.map((item) => {
    const findingId = normalizeFindingId(item.findingId);
    const issue = extractIssueNumberFromFindingId(findingId);
    if (!issue) {
      throw new Error(`Invalid QA finding ID '${item.findingId}'. Expected IDs like Q2-03-01.`);
    }
    if (seen.has(findingId)) {
      throw new Error(`Duplicate QA finding ID '${findingId}' in '${kind}'.`);
    }
    seen.add(findingId);
    return {
      findingId,
      note: sanitizeReportText(item.note),
    };
  });
}

function validateQaReportInputs(params: {
  slug: string;
  result: "passed" | "failed";
  scope: string[];
  findings?: QaFindingInput[];
  stillOpen?: QaFindingStatusInput[];
  closed?: QaFindingStatusInput[];
}) {
  const scope = uniqueStringsInOrder(params.scope.map((issue) => extractIssueNumber(issue)).filter(Boolean));
  if (scope.length === 0) {
    throw new Error(`qa_report_update requires at least one valid issue in 'scope'. ${ISSUE_REFERENCE_HINT}`);
  }

  const findings = validateQaFindings(params.findings ?? []);
  const stillOpen = validateQaFindingStatusList("stillOpen", params.stillOpen ?? []);
  const closed = validateQaFindingStatusList("closed", params.closed ?? []);

  const stillOpenIds = new Set(stillOpen.map((item) => item.findingId));
  for (const entry of closed) {
    if (stillOpenIds.has(entry.findingId)) {
      throw new Error(`QA finding ID '${entry.findingId}' cannot be both 'stillOpen' and 'closed' in the same round.`);
    }
  }

  if (params.result === "passed" && (findings.length > 0 || stillOpen.length > 0)) {
    throw new Error("qa_report_update cannot record new or still-open findings when result is 'passed'. Use result 'failed'.");
  }
  if (params.result === "failed" && findings.length === 0 && stillOpen.length === 0) {
    throw new Error("qa_report_update with result 'failed' requires at least one new finding or one still-open finding ID.");
  }

  const derivedScope = uniqueStringsInOrder([
    ...scope,
    ...findings.map((finding) => finding.issue),
    ...stillOpen.map((item) => extractIssueNumberFromFindingId(item.findingId)),
    ...closed.map((item) => extractIssueNumberFromFindingId(item.findingId)),
  ].filter(Boolean));

  return {
    slug: params.slug,
    result: params.result,
    scope: derivedScope,
    findings,
    stillOpen,
    closed,
  };
}

function buildQaReportContent(existingContent: string | null, params: ReturnType<typeof validateQaReportInputs>) {
  const roundNumber = nextQaRoundNumber(existingContent);
  const timestamp = new Date().toISOString();
  const perIssueSequence = new Map<string, number>();
  const newFindingIds: string[] = [];
  const lines = [
    `## Round ${roundNumber}`,
    "",
    `- Timestamp: ${timestamp}`,
    `- Result: ${params.result.toUpperCase()}`,
    `- Scope: ${formatIssueList(params.scope)}`,
  ];

  if (params.findings.length > 0) {
    lines.push("", "### Findings");
    for (const finding of params.findings) {
      const nextSequence = (perIssueSequence.get(finding.issue) ?? 0) + 1;
      perIssueSequence.set(finding.issue, nextSequence);
      const findingId = `Q${roundNumber}-${finding.issue}-${String(nextSequence).padStart(2, "0")}`;
      newFindingIds.push(findingId);
      lines.push(`- [OPEN][issue:${finding.issue}][${findingId}] ${finding.title}`);
      if (finding.repro) lines.push(`  - Repro: ${finding.repro}`);
      if (finding.expected) lines.push(`  - Expected: ${finding.expected}`);
      if (finding.actual) lines.push(`  - Actual: ${finding.actual}`);
      lines.push(`  - Impact: ${finding.impact}`);
    }
  }

  if (params.stillOpen.length > 0) {
    lines.push("", "### Still open");
    for (const entry of params.stillOpen) {
      const issue = extractIssueNumberFromFindingId(entry.findingId);
      const note = entry.note || "Still reproduces.";
      lines.push(`- [OPEN][issue:${issue}][${entry.findingId}] ${note}`);
    }
  }

  const failedIssues = new Set<string>([
    ...params.findings.map((finding) => finding.issue),
    ...params.stillOpen.map((entry) => extractIssueNumberFromFindingId(entry.findingId)),
  ]);
  const passedIssues = params.scope.filter((issue) => !failedIssues.has(issue));
  if (passedIssues.length > 0) {
    lines.push("", "### Passed");
    for (const issue of passedIssues) {
      lines.push(`- issue ${issue}`);
    }
  }

  if (params.closed.length > 0) {
    lines.push("", "### Closed findings");
    for (const entry of params.closed) {
      const issue = extractIssueNumberFromFindingId(entry.findingId);
      const note = entry.note || `Revalidated in Round ${roundNumber}.`;
      lines.push(`- [CLOSED][issue:${issue}][${entry.findingId}] ${note}`);
    }
  }

  const existingBase = existingContent?.trim() ? existingContent.trim() : QA_REPORT_HEADER;
  return {
    content: `${existingBase}\n\n${lines.join("\n")}\n`,
    roundNumber,
    newFindingIds,
    stillOpenFindingIds: params.stillOpen.map((entry) => entry.findingId),
    closedFindingIds: params.closed.map((entry) => entry.findingId),
  };
}

function findingIdsByIssue(findingIds: string[]): Map<string, string[]> {
  const byIssue = new Map<string, string[]>();
  for (const findingId of findingIds) {
    const issue = extractIssueNumberFromFindingId(findingId);
    if (!issue) continue;
    const current = byIssue.get(issue) ?? [];
    current.push(findingId);
    byIssue.set(issue, current);
  }
  for (const values of byIssue.values()) {
    values.sort((a, b) => a.localeCompare(b));
  }
  return byIssue;
}

function formatQaOpenSummary(openFindings: Map<string, QaExistingFindingRef[]>, targetIssues: IssueEntry[]): string[] {
  const relevant = targetIssues.flatMap((issue) => (openFindings.get(issue.number) ?? []).map((finding) => ({ issue, finding })));
  if (relevant.length === 0) {
    return ["- none recorded for the targeted complete issues"];
  }
  return relevant.map(({ issue, finding }) => `- issue ${issue.number} — ${finding.findingId} — ${finding.title}`);
}

function renderReadsBlock(reads: string[], indent: string): string {
  return [
    `${indent}reads: [`,
    ...reads.map((path) => `${indent}  "${path}",`),
    `${indent}],`,
  ].join("\n");
}

function buildQaWorkerTask(slug: string, issue: IssueEntry, reportExists: boolean, openFindings: QaExistingFindingRef[]): { task: string; reads: string[] } {
  const reads = [
    `PLANS/${slug}/issues/index.md`,
    issue.path,
    ...(reportExists ? [qaReportRepoRelativePath(slug)] : []),
  ];

  const openFindingSummary = openFindings.length > 0
    ? `Rerun the currently open QA findings ${openFindings.map((finding) => `\`${finding.findingId}\``).join(", ")} from ${qaReportRepoRelativePath(slug)} first, then cover this issue's core happy-path and critical edge behaviors. Explicitly say which referenced IDs now pass, which still fail, and which could not be verified.`
    : "Cover this issue's core happy-path and the most important edge behaviors described by the issue file.";

  return {
    reads,
    task: `QA-check ${issue.path} for project ${slug}. Validate only the behavior and integration outcomes owned by this issue. ${openFindingSummary} Use no mocks or fake databases. If persistence or infrastructure is involved, use real throwaway services with Testcontainers or equivalent ephemeral containers. Clean up every process, container, temp file, and DB state before finishing. Do not edit repo files. Report only impactful findings.`,
  };
}

function renderQaReportUpdateExample(slug: string, scopeIssues: string[]): string {
  const firstIssue = scopeIssues[0] ?? "01";
  return [
    "qa_report_update({",
    `  slug: \"${slug}\",`,
    '  result: "failed",',
    `  scope: [\"${firstIssue}\"],`,
    "  findings: [",
    "    {",
    `      issue: \"${firstIssue}\",`,
    '      title: "Behavioral regression title.",',
    '      repro: "Concise reproduction steps.",',
    '      expected: "Expected behavior.",',
    '      actual: "Observed behavior.",',
    '      impact: "Why this matters.",',
    "    }",
    "  ],",
    "  stillOpen: [",
    `    { findingId: \"Q1-${firstIssue}-01\" }`,
    "  ],",
    "  closed: [",
    `    { findingId: \"Q1-${firstIssue}-02\" }`,
    "  ]",
    "})",
  ].join("\n");
}

function renderIssueStatusUpdateExample(slug: string, scopeIssues: string[]): string {
  const firstIssue = scopeIssues[0] ?? "01";
  return [
    "issue_status_update({",
    `  slug: \"${slug}\",`,
    "  updates: [",
    `    { issue: \"${firstIssue}\", status: \"progress\", note: \"QA: Q1-${firstIssue}-01, Q2-${firstIssue}-01\" }`,
    "  ]",
    "})",
  ].join("\n");
}

function buildQaRoundInstructions(slug: string, scopeIssues: string[]): string[] {
  return [
    "Persist the QA round in this order:",
    "1. Call `qa_report_update` first so any new bugs get deterministic QA finding IDs.",
    "2. If the round still has failing findings, call `issue_status_update` to reopen only the affected issues with `progress` notes like `QA: Q1-03-01, Q2-03-01`.",
    "3. If the round passes cleanly, leave `issues/index.md` unchanged.",
    "4. Do not implement fixes in this turn.",
    "",
    "Use these payload shapes:",
    "```ts",
    renderQaReportUpdateExample(slug, scopeIssues),
    "```",
    "",
    "```ts",
    renderIssueStatusUpdateExample(slug, scopeIssues),
    "```",
  ];
}

function buildSingleQaPrompt(slug: string, issue: IssueEntry, reportExists: boolean, openFindings: Map<string, QaExistingFindingRef[]>): string {
  const workerTask = buildQaWorkerTask(slug, issue, reportExists, openFindings.get(issue.number) ?? []);
  return [
    `Run /qa-check for project slug \`${slug}\` from the top-level session.`,
    "",
    `This turn owns one QA round for the currently complete issue \`${issue.number}\` only. Do not implement fixes in this turn.`,
    "Persist the QA result in `PLANS/<slug>/qa_report.md` with `qa_report_update`, then reopen only the affected issues with `issue_status_update` when needed.",
    "",
    "Target issue in this round:",
    `- issue ${issue.number} — \`${issue.path}\``,
    "",
    "Currently open QA findings already recorded for this issue:",
    ...(openFindings.get(issue.number)?.map((finding) => `- ${finding.findingId} — ${finding.title}`) ?? ["- none"]),
    "",
    "QA rules:",
    "- Use behavior and integration validation only.",
    "- No mocks for core QA validation.",
    "- Use real throwaway databases/infrastructure via Testcontainers or equivalent ephemeral containers when the behavior depends on them.",
    "- Cleanly tear down every process, container, temp file, and DB state before finishing.",
    "- If an existing open finding still reproduces, keep it in `stillOpen`; do not duplicate it as a new finding.",
    "- If an existing open finding now passes, record it in `closed` for this round.",
    "- Only create new findings for materially distinct new bugs.",
    "- Report only impactful findings.",
    "",
    "Execution rules:",
    `1. Read \`PLANS/${slug}/issues/index.md\`, \`${issue.path}\`, and \`${qaReportRepoRelativePath(slug)}\` when present before validating.`,
    "2. Run one `qa-worker-integration` pass in fresh context.",
    "3. Synthesize the worker output into one QA round.",
    ...buildQaRoundInstructions(slug, [issue.number]),
    "",
    "Use this exact subagent payload shape:",
    "```ts",
    "subagent({",
    '  agent: "qa-worker-integration",',
    `  task: ${JSON.stringify(workerTask.task)},`,
    renderReadsBlock(workerTask.reads, "  "),
    "  output: false,",
    "  progress: false,",
    '  context: "fresh",',
    "  clarify: false",
    "})",
    "```",
  ].join("\n");
}

function buildParallelQaPrompt(cwd: string, slug: string, targetIssues: IssueEntry[], reportExists: boolean, openFindings: Map<string, QaExistingFindingRef[]>, artifactSource: "tracked-head" | "hook-snapshot"): string {
  const taskObjects = targetIssues.map((issue) => {
    const workerTask = buildQaWorkerTask(slug, issue, reportExists, openFindings.get(issue.number) ?? []);
    return [
      "    {",
      '      agent: "qa-worker-integration",',
      renderReadsBlock(workerTask.reads, "      "),
      `      task: ${JSON.stringify(workerTask.task)},`,
      "      output: false,",
      "      progress: false",
      "    }",
    ].join("\n");
  }).join(",\n");

  const snapshotNotes = artifactSource === "hook-snapshot"
    ? [
        "Worktree planning snapshot:",
        "- The required `PLANS/` artifacts are local-only and not committed at HEAD.",
        "- The configured `pi-subagents` worktree setup hook will copy the current local `PLANS/` tree into each isolated worktree before the QA workers start.",
        "- Treat those copied planning files as read-only contracts. The parent session still owns `qa_report_update` and `issue_status_update`.",
      ]
    : [];

  return [
    `Run /qa-check for project slug \`${slug}\` from the top-level session.`,
    "",
    `This turn owns one QA round for the currently complete issues \`${targetIssues.map((issue) => issue.number).join(", ")}\` only. Do not implement fixes in this turn.`,
    "Persist the QA result in `PLANS/<slug>/qa_report.md` with `qa_report_update`, then reopen only the affected issues with `issue_status_update` when needed.",
    "",
    "Target complete issues in this round:",
    ...targetIssues.map((issue) => {
      const openIds = (openFindings.get(issue.number) ?? []).map((finding) => finding.findingId);
      return openIds.length > 0
        ? `- issue ${issue.number} — \`${issue.path}\` — existing open findings: ${openIds.join(", ")}`
        : `- issue ${issue.number} — \`${issue.path}\``;
    }),
    "",
    "Currently open QA findings already recorded for these complete issues:",
    ...formatQaOpenSummary(openFindings, targetIssues),
    "",
    "QA rules:",
    "- Use behavior and integration validation only.",
    "- No mocks for core QA validation.",
    "- Use real throwaway databases/infrastructure via Testcontainers or equivalent ephemeral containers when the behavior depends on them.",
    "- Cleanly tear down every process, container, temp file, and DB state before finishing.",
    "- If an existing open finding still reproduces, keep it in `stillOpen`; do not duplicate it as a new finding.",
    "- If an existing open finding now passes, record it in `closed` for this round.",
    "- Only create new findings for materially distinct new bugs.",
    "- Report only impactful findings.",
    "",
    ...snapshotNotes,
    ...(snapshotNotes.length > 0 ? [""] : []),
    "Execution rules:",
    `1. Read \`PLANS/${slug}/issues/index.md\`, the targeted issue files, and \`${qaReportRepoRelativePath(slug)}\` when present before validating.`,
    "2. Launch the targeted issues in parallel with `qa-worker-integration` using isolated git worktrees.",
    "3. After the workers finish, synthesize only impactful findings. Each issue should either pass cleanly or produce concise actionable QA evidence.",
    ...buildQaRoundInstructions(slug, targetIssues.map((issue) => issue.number)),
    "",
    "Use this exact subagent payload shape:",
    "```ts",
    "subagent({",
    "  tasks: [",
    taskObjects,
    "  ],",
    `  concurrency: ${targetIssues.length},`,
    "  worktree: true,",
    '  context: "fresh",',
    "  clarify: false",
    "})",
    "```",
  ].join("\n");
}

function buildParallelQaFallbackPrompt(slug: string, targetIssues: IssueEntry[], reportExists: boolean, openFindings: Map<string, QaExistingFindingRef[]>, reason: string): string {
  const issueCalls = targetIssues.map((issue) => {
    const workerTask = buildQaWorkerTask(slug, issue, reportExists, openFindings.get(issue.number) ?? []);
    return [
      `Issue ${issue.number}:`,
      "```ts",
      "subagent({",
      '  agent: "qa-worker-integration",',
      `  task: ${JSON.stringify(workerTask.task)},`,
      renderReadsBlock(workerTask.reads, "  "),
      "  output: false,",
      "  progress: false,",
      '  context: "fresh",',
      "  clarify: false",
      "})",
      "```",
    ].join("\n");
  }).join("\n\n");

  return [
    `Run /qa-check for project slug \`${slug}\` from the top-level session.`,
    "",
    `This turn owns one QA round for the currently complete issues \`${targetIssues.map((issue) => issue.number).join(", ")}\` only. Do not implement fixes in this turn.`,
    "Persist the QA result in `PLANS/<slug>/qa_report.md` with `qa_report_update`, then reopen only the affected issues with `issue_status_update` when needed.",
    "",
    "Target complete issues in this round:",
    ...targetIssues.map((issue) => {
      const openIds = (openFindings.get(issue.number) ?? []).map((finding) => finding.findingId);
      return openIds.length > 0
        ? `- issue ${issue.number} — \`${issue.path}\` — existing open findings: ${openIds.join(", ")}`
        : `- issue ${issue.number} — \`${issue.path}\``;
    }),
    "",
    "Worktree fallback:",
    `- ${reason}`,
    "- To avoid shared-checkout collisions while still using real integration resources, run one QA worker at a time in the main checkout for this turn.",
    "",
    "QA rules:",
    "- Use behavior and integration validation only.",
    "- No mocks for core QA validation.",
    "- Use real throwaway databases/infrastructure via Testcontainers or equivalent ephemeral containers when the behavior depends on them.",
    "- Cleanly tear down every process, container, temp file, and DB state before finishing.",
    "- If an existing open finding still reproduces, keep it in `stillOpen`; do not duplicate it as a new finding.",
    "- If an existing open finding now passes, record it in `closed` for this round.",
    "- Only create new findings for materially distinct new bugs.",
    "- Report only impactful findings.",
    "",
    "Execution rules:",
    `1. Read \`PLANS/${slug}/issues/index.md\`, the targeted issue files, and \`${qaReportRepoRelativePath(slug)}\` when present before validating.`,
    "2. Run one `qa-worker-integration` pass at a time, in issue order, without `worktree: true`.",
    "3. Synthesize only impactful findings into one QA round after all reachable issues are checked or an earlier failure makes it unsafe to continue.",
    ...buildQaRoundInstructions(slug, targetIssues.map((issue) => issue.number)),
    "",
    "Use these exact subagent payload shapes, one issue at a time:",
    issueCalls,
  ].join("\n");
}

function buildQaPrompt(cwd: string, slug: string, targetPlan: Extract<QaTargetPlan, { kind: "initial" | "recheck" }>): string {
  const { targetIssues, reportExists, openFindings } = targetPlan;
  if (targetIssues.length === 1) {
    return buildSingleQaPrompt(slug, targetIssues[0]!, reportExists, openFindings);
  }

  const executionMode = resolveParallelQaExecutionMode(cwd, slug, targetIssues.map((issue) => issue.path), reportExists);
  if (executionMode.kind === "serial-fallback") {
    return buildParallelQaFallbackPrompt(slug, targetIssues, reportExists, openFindings, executionMode.reason);
  }
  return buildParallelQaPrompt(cwd, slug, targetIssues, reportExists, openFindings, executionMode.artifactSource);
}

export default function qaExec(pi: ExtensionAPI) {
  const QaResultSchema = StringEnum(["passed", "failed"] as const);

  pi.registerTool({
    name: "qa_report_update",
    label: "QA Report Update",
    description: "Append one deterministic QA round to `PLANS/<slug>/qa_report.md` and return any new finding IDs.",
    promptSnippet: "Append a deterministic QA round to PLANS/<slug>/qa_report.md and return any newly assigned QA finding IDs.",
    promptGuidelines: [
      "Use qa_report_update from the top-level parent session after consolidating /qa-check worker results.",
      "Use qa_report_update before issue_status_update when reopening issues from QA so the returned finding IDs can be routed into the issue status note.",
      "Use qa_report_update to record only impactful findings; keep existing open findings in `stillOpen` instead of duplicating them.",
    ],
    parameters: Type.Object({
      slug: Type.String({ description: "Project slug under PLANS/<slug>" }),
      result: QaResultSchema,
      scope: Type.Array(Type.String({ description: "Issue number like 01 or a path containing the issue number" }), { minItems: 1 }),
      findings: Type.Optional(Type.Array(Type.Object({
        issue: Type.String({ description: "Issue number like 01 or a path containing the issue number" }),
        title: Type.String({ description: "Concise behavioral bug title" }),
        repro: Type.Optional(Type.String({ description: "Concise reproduction steps" })),
        expected: Type.Optional(Type.String({ description: "Expected behavior" })),
        actual: Type.Optional(Type.String({ description: "Observed behavior" })),
        impact: Type.String({ description: "Why the finding matters" }),
      }))),
      stillOpen: Type.Optional(Type.Array(Type.Object({
        findingId: Type.String({ description: "Existing QA finding ID like Q1-03-01 that still reproduces" }),
        note: Type.Optional(Type.String({ description: "Optional concise note for why it is still open" })),
      }))),
      closed: Type.Optional(Type.Array(Type.Object({
        findingId: Type.String({ description: "Existing QA finding ID like Q1-03-01 that passed this round" }),
        note: Type.Optional(Type.String({ description: "Optional concise closure note" })),
      }))),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const normalized = validateQaReportInputs({
        slug: params.slug,
        result: params.result as "passed" | "failed",
        scope: params.scope,
        findings: params.findings,
        stillOpen: params.stillOpen,
        closed: params.closed,
      });

      const state = loadIssueIndexState(ctx.cwd, normalized.slug);
      if (!state) {
        throw new Error(`Missing PLANS/${normalized.slug}/issues/index.md`);
      }
      const knownIssues = new Set(state.issueEntries.map((entry) => entry.number));
      const unknownIssues = normalized.scope.filter((issue) => !knownIssues.has(issue));
      if (unknownIssues.length > 0) {
        throw new Error(`Unknown issue references for ${normalized.slug}: ${unknownIssues.join(", ")}. ${ISSUE_REFERENCE_HINT}`);
      }

      const reportPath = qaReportAbsolutePath(ctx.cwd, normalized.slug);
      const existingContent = existsSync(reportPath)
        ? readFileSync(reportPath, "utf-8").replace(/\r\n/g, "\n")
        : null;
      const next = buildQaReportContent(existingContent, normalized);
      writeFileSync(reportPath, next.content, "utf-8");

      const reopenByIssue = findingIdsByIssue([...next.newFindingIds, ...next.stillOpenFindingIds]);
      const reopenSummary = Array.from(reopenByIssue.entries())
        .map(([issue, findingIds]) => `${issue} => ${findingIds.join(", ")}`)
        .join("; ") || "none";
      const newFindingSummary = next.newFindingIds.length > 0 ? next.newFindingIds.join(", ") : "none";
      const stillOpenSummary = next.stillOpenFindingIds.length > 0 ? next.stillOpenFindingIds.join(", ") : "none";
      const closedSummary = next.closedFindingIds.length > 0 ? next.closedFindingIds.join(", ") : "none";

      return {
        content: [{ type: "text", text: `Updated ${reportPath}: Round ${next.roundNumber} ${normalized.result.toUpperCase()}. New findings: ${newFindingSummary}. Still open: ${stillOpenSummary}. Closed: ${closedSummary}. Reopen: ${reopenSummary}.` }],
        details: {
          reportPath,
          roundNumber: next.roundNumber,
          result: normalized.result,
          scope: normalized.scope,
          newFindingIds: next.newFindingIds,
          stillOpenFindingIds: next.stillOpenFindingIds,
          closedFindingIds: next.closedFindingIds,
          reopenByIssue: Object.fromEntries(reopenByIssue.entries()),
        },
      };
    },
  });

  pi.registerCommand("qa-check", {
    description: "Run one behavior/integration QA round for a slug: first round checks complete issues, later rounds retest only still-open QA findings",
    getArgumentCompletions: (prefix) => getSlugCompletions(process.cwd(), prefix.trimStart()),
    handler: async (args, ctx) => {
      const slug = await pickSlug(args, ctx, "qa-check");
      if (!slug) return;

      const state = loadIssueIndexState(ctx.cwd, slug);
      if (!state) {
        ctx.ui.notify(`Missing PLANS/${slug}/issues/index.md`, "warning");
        return;
      }
      if (state.issueEntries.length === 0) {
        ctx.ui.notify(issueEntriesMissingMessage(slug), "warning");
        return;
      }

      const targetPlan = selectQaTargetPlan(ctx.cwd, slug, state);
      if (targetPlan.kind === "no-complete") {
        ctx.ui.notify(`No complete issues are ready for /qa-check in ${slug}. Finish /build first or settle the remaining progress/blocked issues.`, "warning");
        return;
      }
      if (targetPlan.kind === "stale-report") {
        ctx.ui.notify(`Cannot run /qa-check ${slug}: qa_report.md still has open findings for unknown issues ${targetPlan.missingIssueNumbers.join(", ")}. Clean up or regenerate the planning/QA artifacts first.`, "warning");
        return;
      }
      if (targetPlan.kind === "waiting-for-build") {
        const pendingSummary = targetPlan.pendingIssues
          .map(({ issue, status }) => `${issue.number}:${status}`)
          .join(", ");
        ctx.ui.notify(`Cannot run /qa-check ${slug}: still-open QA findings are waiting on /build. Finish these owner issues first: ${pendingSummary}.`, "warning");
        return;
      }

      pauseActiveBuildForQaCheck(pi, ctx);
      sendPrompt(pi, buildQaPrompt(ctx.cwd, slug, targetPlan), ctx, targetPlan.kind === "recheck" ? `Queued /qa-check recheck for ${slug}` : `Queued /qa-check for ${slug}`);
    },
  });
}
