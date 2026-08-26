import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AutocompleteItem } from "@earendil-works/pi-tui";
import { StringEnum } from "@earendil-works/pi-ai";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, resolve } from "node:path";
import { Type } from "typebox";

type IssueStatus = "todo" | "progress" | "blocked" | "complete";

type IssueEntry = {
  number: string;
  path: string;
};

type BatchEntry = {
  key: string;
  label: string;
  parallel: boolean;
  issueNumbers: string[];
  issuePaths: string[];
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
  batches: BatchEntry[];
  statusRows: Map<string, IssueStatusRow>;
  digest: string;
};

type IssueStatusUpdate = {
  issue: string;
  status: IssueStatus;
  note?: string;
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

type ParallelBatchExecutionMode =
  | { kind: "worktree"; artifactSource: "tracked-head" | "hook-snapshot" }
  | { kind: "serial-fallback"; reason: string; unavailablePaths: string[] };

const EXECUTION_STATUS_HEADING = "Execution status";
const SHARED_CONTRACTS_HEADING = "Shared contracts / conflict hotspots";
const BUILD_STATE_ENTRY_TYPE = "issue-build-state";
const STATUS_UPDATE_ENTRY_TYPE = "issue-status-update";
const SUBAGENT_CONFIG_PATH = join(homedir(), ".pi", "agent", "extensions", "subagent", "config.json");
const ISSUE_STATUS_VALUES: IssueStatus[] = ["todo", "progress", "blocked", "complete"];
const ISSUE_REFERENCE_HINT = "Use a two-digit issue number like `01` or a path containing `/issues/01-...`.";

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

function readIssuesIndex(cwd: string, slug: string): string | null {
  const path = issuesIndexPath(cwd, slug);
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

function resolveParallelBatchExecutionMode(cwd: string, slug: string, batch: BatchEntry): ParallelBatchExecutionMode {
  const repoRoot = resolveRepoRoot(cwd);
  const requiredPaths = Array.from(new Set([`PLANS/${slug}/issues/index.md`, ...batch.issuePaths]));
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
    reason: `${reasonParts.join(" ")} ${details.join(" ")} Falling back to serial execution in the main checkout.`.trim(),
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

function joinDocumentSegments(...segments: string[][]): string {
  const parts = segments
    .map((segment) => segment.join("\n").trim())
    .filter(Boolean);
  return `${parts.join("\n\n")}\n`;
}

function replaceOrInsertSection(markdown: string, heading: string, sectionBodyContent: string, beforeHeading?: string): string {
  const lines = splitLines(markdown);
  const sectionLines = [`## ${heading}`, "", ...splitLines(sectionBodyContent.trim())];
  const existing = findSectionRange(lines, heading);
  if (existing) {
    return joinDocumentSegments(lines.slice(0, existing.start), sectionLines, lines.slice(existing.end));
  }

  if (beforeHeading) {
    const target = findSectionRange(lines, beforeHeading);
    if (target) {
      return joinDocumentSegments(lines.slice(0, target.start), sectionLines, lines.slice(target.start));
    }
  }

  return joinDocumentSegments(lines, sectionLines);
}

function normalizeMarkdownText(value: string): string {
  return value.replace(/[*_`]/g, "").replace(/\s+/g, " ").trim();
}

function extractPrimaryIssueSpan(text: string): string {
  const clause = text.split(/[.;]/)[0] ?? text;
  const issueIndex = clause.search(/\bissues?\b/i);
  const working = issueIndex >= 0 ? clause.slice(issueIndex) : clause;
  const withoutLead = working.replace(/^\bissues?\b[:\s-]*/i, "");
  return withoutLead.split(/\b(?:can|should|must|once|when|while|if|after|before|depends?|requires?|may|because)\b/i)[0] ?? withoutLead;
}

function uniqueIssueNumbersInOrder(text: string): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const match of text.matchAll(/\b(\d{1,2})\b/g)) {
    const number = normalizeIssueNumber(match[1] ?? "");
    if (!number || seen.has(number)) continue;
    seen.add(number);
    result.push(number);
  }
  return result;
}

function parseSuggestedExecutionBatches(indexContent: string, issueEntries: IssueEntry[]): BatchEntry[] {
  const issueMap = new Map(issueEntries.map((entry) => [entry.number, entry.path]));
  const body = sectionBody(indexContent, "Suggested execution order");
  if (!body) return [];

  const batches: BatchEntry[] = [];
  for (const rawLine of body.split("\n")) {
    const line = normalizeMarkdownText(rawLine);
    const match = line.match(/^\s*-\s*(.+?):\s*(.+)$/);
    if (!match) continue;

    const label = match[1]?.trim() ?? "";
    const rhs = match[2]?.trim() ?? "";
    const issueNumbers = uniqueIssueNumbersInOrder(extractPrimaryIssueSpan(rhs));
    const issuePaths = issueNumbers
      .map((number) => issueMap.get(number))
      .filter((path): path is string => Boolean(path));
    if (issuePaths.length === 0) continue;

    const keyMatch = label.match(/\b(?:group|batch|wave)\s+([A-Za-z0-9-]+)/i);
    const key = (keyMatch?.[1] ?? label).trim();
    batches.push({
      key,
      label,
      parallel: /parallel/i.test(`${label} ${rhs}`),
      issueNumbers,
      issuePaths,
    });
  }

  return batches;
}

function buildSyntheticBatches(issueEntries: IssueEntry[]): BatchEntry[] {
  return issueEntries.map((entry) => ({
    key: entry.number,
    label: `Issue ${entry.number}`,
    parallel: false,
    issueNumbers: [entry.number],
    issuePaths: [entry.path],
  }));
}

function parseBatches(indexContent: string): BatchEntry[] {
  const issueEntries = parseIssueEntries(indexContent);
  if (issueEntries.length === 0) return [];

  const parsed = parseSuggestedExecutionBatches(indexContent, issueEntries);
  if (parsed.length === 0) return buildSyntheticBatches(issueEntries);

  const issueMap = new Map(issueEntries.map((entry) => [entry.number, entry.path]));
  const seen = new Set<string>();
  const batches: BatchEntry[] = [];

  for (const batch of parsed) {
    const issueNumbers = batch.issueNumbers.filter((number) => {
      if (seen.has(number)) return false;
      seen.add(number);
      return true;
    });
    if (issueNumbers.length === 0) continue;
    batches.push({
      key: batch.key,
      label: batch.label,
      parallel: batch.parallel,
      issueNumbers,
      issuePaths: issueNumbers.map((number) => issueMap.get(number)).filter((path): path is string => Boolean(path)),
    });
  }

  for (const entry of issueEntries) {
    if (seen.has(entry.number)) continue;
    batches.push({
      key: entry.number,
      label: `Issue ${entry.number}`,
      parallel: false,
      issueNumbers: [entry.number],
      issuePaths: [entry.path],
    });
  }

  return batches;
}

function emptyStatusRows(issueEntries: IssueEntry[]): Map<string, IssueStatusRow> {
  return new Map(issueEntries.map((entry) => [entry.number, {
    issue: entry.number,
    status: "todo",
    note: "",
    path: entry.path,
  }]));
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
  const rows = emptyStatusRows(issueEntries);
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

function formatExecutionStatusBody(issueEntries: IssueEntry[], statusRows: Map<string, IssueStatusRow>): string {
  const lines = [
    "| Issue | Status | File | Notes |",
    "| --- | --- | --- | --- |",
  ];

  for (const entry of issueEntries) {
    const row = statusRows.get(entry.number) ?? {
      issue: entry.number,
      status: "todo" as IssueStatus,
      note: "",
      path: entry.path,
    };
    lines.push(`| ${entry.number} | ${row.status} | \`${entry.path}\` | ${row.note || "—"} |`);
  }

  return lines.join("\n");
}

function withCanonicalExecutionStatusSection(indexContent: string, issueEntries: IssueEntry[], statusRows: Map<string, IssueStatusRow>): string {
  return replaceOrInsertSection(
    indexContent,
    EXECUTION_STATUS_HEADING,
    formatExecutionStatusBody(issueEntries, statusRows),
    SHARED_CONTRACTS_HEADING,
  );
}

function buildStatusDigest(issueEntries: IssueEntry[], statusRows: Map<string, IssueStatusRow>): string {
  return issueEntries
    .map((entry) => {
      const row = statusRows.get(entry.number) ?? {
        issue: entry.number,
        status: "todo" as IssueStatus,
        note: "",
        path: entry.path,
      };
      return `${entry.number}:${row.status}:${sanitizeNote(row.note)}`;
    })
    .join("|");
}

function loadIssueIndexState(cwd: string, slug: string): IssueIndexState | null {
  const content = readIssuesIndex(cwd, slug);
  if (!content) return null;

  const issueEntries = parseIssueEntries(content);
  const batches = parseBatches(content);
  const statusRows = parseExecutionStatus(content, issueEntries);
  return {
    indexPath: issuesIndexPath(cwd, slug),
    content,
    issueEntries,
    batches,
    statusRows,
    digest: buildStatusDigest(issueEntries, statusRows),
  };
}

function ensureExecutionStatusTable(cwd: string, slug: string): IssueIndexState | null {
  const state = loadIssueIndexState(cwd, slug);
  if (!state) return null;
  const nextContent = withCanonicalExecutionStatusSection(state.content, state.issueEntries, state.statusRows);
  if (nextContent !== state.content) {
    writeFileSync(state.indexPath, nextContent, "utf-8");
  }
  return loadIssueIndexState(cwd, slug);
}

function updateIssueStatusesOnDisk(cwd: string, slug: string, updates: IssueStatusUpdate[]): IssueIndexState {
  const ensured = ensureExecutionStatusTable(cwd, slug);
  if (!ensured) {
    throw new Error(`Missing PLANS/${slug}/issues/index.md`);
  }

  const nextRows = new Map<string, IssueStatusRow>();
  for (const [issue, row] of ensured.statusRows.entries()) {
    nextRows.set(issue, { ...row });
  }

  for (const update of updates) {
    const issue = extractIssueNumber(update.issue);
    if (!issue) {
      throw new Error(`Invalid issue reference '${update.issue}'. ${ISSUE_REFERENCE_HINT}`);
    }
    if (!nextRows.has(issue)) {
      throw new Error(`Unknown issue '${update.issue}' for ${slug}`);
    }
    const note = update.status === "progress" || update.status === "blocked"
      ? sanitizeNote(update.note)
      : "";
    nextRows.set(issue, {
      issue,
      status: update.status,
      note,
      path: nextRows.get(issue)?.path ?? "",
    });
  }

  const nextContent = withCanonicalExecutionStatusSection(ensured.content, ensured.issueEntries, nextRows);
  if (nextContent !== ensured.content) {
    writeFileSync(ensured.indexPath, nextContent, "utf-8");
  }

  const reloaded = loadIssueIndexState(cwd, slug);
  if (!reloaded) {
    throw new Error(`Failed to reload PLANS/${slug}/issues/index.md after status update`);
  }
  return reloaded;
}

function validateIssueStatusUpdates(slug: string, updates: IssueStatusUpdate[]): IssueStatusUpdate[] {
  const seen = new Set<string>();
  return updates.map((update) => {
    const issue = extractIssueNumber(update.issue);
    if (!issue) {
      throw new Error(`Invalid issue reference '${update.issue}'. ${ISSUE_REFERENCE_HINT}`);
    }
    if (seen.has(issue)) {
      throw new Error(`Duplicate issue update for ${issue} in ${slug}. Each issue may appear only once per issue_status_update call.`);
    }
    seen.add(issue);

    const note = update.status === "progress" || update.status === "blocked"
      ? sanitizeNote(update.note)
      : "";
    if ((update.status === "progress" || update.status === "blocked") && !note) {
      throw new Error(`Issue ${issue} marked '${update.status}' requires a concise note explaining the remaining work or blocker.`);
    }

    return {
      issue,
      status: update.status,
      note,
    };
  });
}

function issueEntriesMissingMessage(slug: string): string {
  return `No parseable issue file paths found in PLANS/${slug}/issues/index.md. Add backticked paths or markdown links to PLANS/${slug}/issues/NN-*.md.`;
}

function resolveBatch(batches: BatchEntry[], raw: string): BatchEntry | null {
  const needle = raw.trim().toLowerCase().replace(/^(group|batch|wave)\s+/i, "");
  if (!needle) return null;
  return batches.find((batch) => {
    const key = batch.key.toLowerCase();
    const label = batch.label.toLowerCase();
    return key === needle || label.includes(needle);
  }) ?? null;
}

function resolveIssue(entries: IssueEntry[], raw: string): IssueEntry | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  if (/PLANS\/[^\s]+\/issues\/\d{2}-[^\s]+\.md/.test(trimmed)) {
    const number = trimmed.match(/issues\/(\d{2})-/)?.[1] ?? "";
    return entries.find((entry) => entry.number === number) ?? { number, path: trimmed };
  }
  const number = normalizeIssueNumber(trimmed);
  if (!number) return null;
  return entries.find((entry) => entry.number === number) ?? null;
}

function getSlugCompletions(cwd: string, prefix: string): AutocompleteItem[] | null {
  const items = listIssueSlugs(cwd)
    .filter((slug) => slug.startsWith(prefix.trim()))
    .map((slug) => ({ value: slug, label: slug }));
  return items.length > 0 ? items : null;
}

function getBatchCompletions(cwd: string, slug: string, prefix: string): AutocompleteItem[] | null {
  const content = readIssuesIndex(cwd, slug);
  if (!content) return null;
  const items = parseBatches(content)
    .filter((batch) => batch.key.toLowerCase().startsWith(prefix.trim().toLowerCase()))
    .map((batch) => ({
      value: `${slug} ${batch.key}`,
      label: `${batch.key}${batch.parallel ? " (parallel)" : ""} — ${batch.issueNumbers.join(" + ")}`,
    }));
  return items.length > 0 ? items : null;
}

function getIssueCompletions(cwd: string, slug: string, prefix: string): AutocompleteItem[] | null {
  const content = readIssuesIndex(cwd, slug);
  if (!content) return null;
  const items = parseIssueEntries(content)
    .filter((entry) => entry.number.startsWith(normalizeIssueNumber(prefix) || prefix.trim()))
    .map((entry) => ({
      value: `${slug} ${entry.number}`,
      label: `${entry.number} — ${basename(entry.path)}`,
    }));
  return items.length > 0 ? items : null;
}

function renderStatusSummary(issueNumbers: string[], statusRows: Map<string, IssueStatusRow>): string[] {
  return issueNumbers.map((issue) => {
    const row = statusRows.get(issue);
    if (!row) return `- issue ${issue} — todo`;
    return row.note
      ? `- issue ${issue} — ${row.status} — ${row.note}`
      : `- issue ${issue} — ${row.status}`;
  });
}

function renderStatusUpdateExample(slug: string, issueNumbers: string[]): string {
  const updateLines = issueNumbers.map((issue) => `    { issue: "${issue}", status: "complete" }`).join(",\n");
  return [
    "issue_status_update({",
    `  slug: "${slug}",`,
    "  updates: [",
    updateLines,
    "  ]",
    "})",
  ].join("\n");
}

function qaReportRepoRelativePath(slug: string): string {
  return `PLANS/${slug}/qa_report.md`;
}

function qaFindingIdsFromNote(note: string): string[] {
  const matches = note.match(/\bQ\d+-\d{2}-\d{2}\b/g) ?? [];
  return Array.from(new Set(matches.map((match) => match.toUpperCase()))).sort((a, b) => a.localeCompare(b));
}

function batchHasQaFindingRefs(batch: BatchEntry, statusRows: Map<string, IssueStatusRow>): boolean {
  return batch.issueNumbers.some((issue) => qaFindingIdsFromNote(statusRows.get(issue)?.note ?? "").length > 0);
}

function buildIssueWorkerTask(cwd: string, slug: string, issuePath: string, statusRows: Map<string, IssueStatusRow>): string {
  const issueNumber = extractIssueNumber(issuePath);
  const findingIds = qaFindingIdsFromNote(statusRows.get(issueNumber)?.note ?? "");
  const qaReportPath = qaReportRepoRelativePath(slug);
  const baseTask = `Implement ${issuePath} for project ${slug}. Keep scope limited to this issue and preserve shared contracts.`;
  if (findingIds.length === 0) return baseTask;
  return `${baseTask} This issue was reopened by QA. Read ${qaReportPath} and fix only findings ${findingIds.map((findingId) => `\`${findingId}\``).join(", ")}. Treat those findings as required acceptance criteria. Add regression coverage for each referenced QA finding before changing production code when practical. If ${qaReportPath} is missing or those finding IDs do not resolve, stop and report the mismatch as a blocker. Do not mark QA findings closed yourself; /qa-check will verify them later.`;
}

function buildIssueWorkerReads(cwd: string, slug: string, issuePath: string, statusRows: Map<string, IssueStatusRow>): string[] {
  const reads = [`PLANS/${slug}/issues/index.md`, issuePath];
  const issueNumber = extractIssueNumber(issuePath);
  const findingIds = qaFindingIdsFromNote(statusRows.get(issueNumber)?.note ?? "");
  const qaReportPath = qaReportRepoRelativePath(slug);
  if (findingIds.length > 0 && existsSync(join(cwd, qaReportPath))) {
    reads.push(qaReportPath);
  }
  return reads;
}

function renderReadsBlock(reads: string[], indent: string): string {
  return [
    `${indent}reads: [`,
    ...reads.map((path) => `${indent}  "${path}",`),
    `${indent}],`,
  ].join("\n");
}

function commonPromptPreamble(slug: string, batch: BatchEntry, statusRows: Map<string, IssueStatusRow>, autoAdvance: boolean): string[] {
  return [
    autoAdvance
      ? `Continue deterministic /build for project slug \`${slug}\` from the top-level session.`
      : `Run issue batch \`${batch.label}\` for project slug \`${slug}\` from the top-level session.`,
    "",
    autoAdvance
      ? `This turn owns only batch \`${batch.label}\`. Do not launch any later batch yourself.`
      : `This command owns only batch \`${batch.label}\`. Do not broaden into later batches in the same turn.`,
    autoAdvance
      ? "The extension will inspect `## Execution status` after this turn and decide whether to continue, rerun, or stop."
      : "Persist final settlement by calling `issue_status_update` before the turn ends.",
    "",
    "Current persisted execution status for the targeted issues:",
    ...renderStatusSummary(batch.issueNumbers, statusRows),
    "",
    "Status rules:",
    "- `progress` = more implementation or rework is still needed after this turn.",
    "- `blocked` = a real blocker prevents safe completion; include the blocker in the note.",
    "- `complete` = integrated into the main branch and the required validation passed.",
    "- The top-level parent session owns `issue_status_update`; do not ask child workers to edit `issues/index.md`.",
    "- Leave untouched later issues unchanged if you stop early inside a serial batch.",
    ...(batchHasQaFindingRefs(batch, statusRows)
      ? [
          "",
          "QA reopen rules:",
          `- If a targeted issue note includes QA finding IDs, treat \`${qaReportRepoRelativePath(slug)}\` as the authoritative bug report for this turn.`,
          "- Fix only the referenced QA findings for that issue unless the issue file itself explicitly requires adjacent scope.",
          "- Add regression coverage for each referenced QA finding before the production fix when practical.",
          "- Do not close QA findings in `qa_report.md`; only `/qa-check` closes findings after verification.",
        ]
      : []),
  ];
}

function buildSettlementInstructions(slug: string, batch: BatchEntry): string[] {
  return [
    "",
    "Final action before ending the turn:",
    "1. Call `issue_status_update` with the issues you settled this turn.",
    "2. Include a concise note whenever a status is `progress` or `blocked`.",
    "3. Clear resolved notes by sending `complete` without a note when an issue is done.",
    "",
    "Use this tool payload shape:",
    "```ts",
    renderStatusUpdateExample(slug, batch.issueNumbers),
    "```",
  ];
}

function renderIssueWorkerDirectCall(cwd: string, slug: string, issuePath: string, statusRows: Map<string, IssueStatusRow>): string {
  const reads = buildIssueWorkerReads(cwd, slug, issuePath, statusRows);
  const task = buildIssueWorkerTask(cwd, slug, issuePath, statusRows);
  return [
    "subagent({",
    "  chain: [",
    "    {",
    '      agent: "issue-worker-tdd",',
    `      task: ${JSON.stringify(task)},`,
    renderReadsBlock(reads, "      "),
    "      output: false,",
    "      progress: false",
    "    },",
    "    {",
    '      agent: "reviewer",',
    `      task: "Review the current diff for ${issuePath}. Focus on correctness/regressions, issue-scope drift, and whether tests verify behavior rather than implementation details. Do not edit files.",`,
    "      output: false,",
    "      progress: false",
    "    }",
    "  ],",
    '  context: "fresh",',
    "  clarify: false",
    "})",
  ].join("\n");
}

function renderReviewerDirectCall(issuePath: string): string {
  return [
    "subagent({",
    '  agent: "reviewer",',
    `  task: "Review the current diff for ${issuePath}. Focus on correctness/regressions, issue-scope drift, and whether tests verify behavior rather than implementation details. Do not edit files.",`,
    "  output: false,",
    "  progress: false,",
    '  context: "fresh",',
    "  clarify: false",
    "})",
  ].join("\n");
}

function buildParallelPrompt(cwd: string, slug: string, batch: BatchEntry, statusRows: Map<string, IssueStatusRow>, autoAdvance: boolean, artifactSource: "tracked-head" | "hook-snapshot"): string {
  const taskObjects = batch.issuePaths.map((issuePath) => {
    const reads = buildIssueWorkerReads(cwd, slug, issuePath, statusRows);
    const task = buildIssueWorkerTask(cwd, slug, issuePath, statusRows);
    return [
      "    {",
      '      agent: "issue-worker-tdd",',
      renderReadsBlock(reads, "      "),
      `      task: ${JSON.stringify(task)},`,
      "      output: false,",
      "      progress: false",
      "    }",
    ].join("\n");
  }).join(",\n");
  const reviewerCalls = batch.issuePaths.map((issuePath) => [
    `Issue ${extractIssueNumber(issuePath)}:`,
    "```ts",
    renderReviewerDirectCall(issuePath),
    "```",
  ].join("\n")).join("\n\n");
  const worktreeSnapshotNotes = artifactSource === "hook-snapshot"
    ? [
        "Worktree planning snapshot:",
        "- The required `PLANS/` artifacts are local-only and not committed at HEAD.",
        "- The configured `pi-subagents` worktree setup hook will copy the current local `PLANS/` tree into each isolated worktree before the workers start.",
        "- Treat those copied planning files as read-only issue contracts. The parent session still owns `issue_status_update`.",
      ]
    : [];

  return [
    ...commonPromptPreamble(slug, batch, statusRows, autoAdvance),
    "",
    ...worktreeSnapshotNotes,
    ...(worktreeSnapshotNotes.length > 0 ? [""] : []),
    "Execution rules:",
    `1. Read \`PLANS/${slug}/issues/index.md\` and the targeted issue files first.`,
    "2. Verify prerequisite batches are already integrated and the main repo is clean enough for worktree execution. If not, stop and report the blocker.",
    "3. Launch the targeted issues in parallel with `issue-worker-tdd` using isolated git worktrees.",
    "4. After the workers finish, inspect each diff, integrate the worktree results back into the main branch, resolve hotspots in the parent session, and run focused validation on the integrated branch.",
    "5. After each integration, run a no-edit `reviewer` pass focused on correctness/regressions, issue-scope drift, and whether tests verify behavior rather than implementation details before marking the issue `complete`.",
    "6. Only mark an issue `complete` after its integrated branch state is green for the issue's required validation.",
    "",
    "Use this exact subagent payload shape:",
    "```ts",
    "subagent({",
    "  tasks: [",
    taskObjects,
    "  ],",
    `  concurrency: ${batch.issuePaths.length},`,
    "  worktree: true,",
    '  context: "fresh",',
    "  clarify: false",
    "})",
    "```",
    "",
    "After integrating each issue, use this exact reviewer payload:",
    reviewerCalls,
    ...buildSettlementInstructions(slug, batch),
  ].join("\n");
}

function buildParallelFallbackPrompt(cwd: string, slug: string, batch: BatchEntry, statusRows: Map<string, IssueStatusRow>, autoAdvance: boolean, reason: string): string {
  const issueCalls = batch.issuePaths.map((issuePath) => [
    `Issue ${extractIssueNumber(issuePath)}:`,
    "```ts",
    renderIssueWorkerDirectCall(cwd, slug, issuePath, statusRows),
    "```",
  ].join("\n")).join("\n\n");

  return [
    ...commonPromptPreamble(slug, batch, statusRows, autoAdvance),
    "",
    "Worktree fallback:",
    `- ${reason}`,
    "- This batch was planned as parallel, but isolated worktrees cannot receive a safe planning snapshot for this turn.",
    "- To avoid concurrent writers clobbering each other in the shared checkout, run one issue at a time in the main checkout for this turn.",
    "",
    "Execution rules:",
    `1. Read \`PLANS/${slug}/issues/index.md\` and these issue files first:`,
    ...batch.issuePaths.map((path) => `   - \`${path}\``),
    "2. Verify prerequisite batches are already integrated and the main repo is clean enough for implementation. If not, stop and report the blocker.",
    "3. Run `issue-worker-tdd` followed by a no-edit `reviewer` pass for the first issue in fresh context without `worktree: true`.",
    "4. After the chain finishes, inspect the diff, integrate the result into the main branch, resolve hotspots in the parent session, and run focused validation for that issue.",
    "5. If the current issue is blocked or still in progress, stop there and leave untouched later issues unchanged.",
    "6. Only after settling the earlier issue should you run the next issue in the same way.",
    "7. Only mark an issue `complete` after its integrated branch state is green for the issue's required validation.",
    "",
    "Use these exact subagent payload shapes, one issue at a time:",
    issueCalls,
    ...buildSettlementInstructions(slug, batch),
  ].join("\n");
}

function buildSingleIssuePrompt(cwd: string, slug: string, issue: IssueEntry, statusRows: Map<string, IssueStatusRow>, autoAdvance: boolean): string {
  const batch: BatchEntry = {
    key: issue.number,
    label: `Issue ${issue.number}`,
    parallel: false,
    issueNumbers: [issue.number],
    issuePaths: [issue.path],
  };
  const reads = buildIssueWorkerReads(cwd, slug, issue.path, statusRows);
  const task = buildIssueWorkerTask(cwd, slug, issue.path, statusRows);

  return [
    ...commonPromptPreamble(slug, batch, statusRows, autoAdvance),
    "",
    "Execution rules:",
    `1. Read \`PLANS/${slug}/issues/index.md\` and \`${issue.path}\` first.`,
    "2. Verify the issue prerequisites appear satisfied in the current codebase state. If not, stop and report that the issue is blocked.",
    "3. Implement with `issue-worker-tdd` in fresh context.",
    "4. Then run a no-edit `reviewer` pass focused on correctness, scope drift, and whether the tests verify behavior instead of implementation details.",
    "5. Integrate any required follow-up fixes in the parent session before marking the issue `complete`.",
    "",
    "Use this exact subagent payload shape:",
    "```ts",
    "subagent({",
    "  chain: [",
    "    {",
    '      agent: "issue-worker-tdd",',
    `      task: ${JSON.stringify(task)},`,
    renderReadsBlock(reads, "      "),
    "      output: false,",
    "      progress: false",
    "    },",
    "    {",
    '      agent: "reviewer",',
    `      task: "Review the current diff for ${issue.path}. Focus on correctness/regressions, issue-scope drift, and whether tests verify behavior rather than implementation details. Do not edit files.",`,
    "      output: false,",
    "      progress: false",
    "    }",
    "  ],",
    '  context: "fresh",',
    "  clarify: false",
    "})",
    "```",
    ...buildSettlementInstructions(slug, batch),
  ].join("\n");
}

function buildSequentialBatchPrompt(cwd: string, slug: string, batch: BatchEntry, statusRows: Map<string, IssueStatusRow>, autoAdvance: boolean): string {
  const steps = batch.issuePaths.flatMap((issuePath) => {
    const reads = buildIssueWorkerReads(cwd, slug, issuePath, statusRows);
    const task = buildIssueWorkerTask(cwd, slug, issuePath, statusRows);
    return [
      [
        "    {",
        '      agent: "issue-worker-tdd",',
        `      task: ${JSON.stringify(task)},`,
        renderReadsBlock(reads, "      "),
        "      output: false,",
        "      progress: false",
        "    }",
      ].join("\n"),
      [
        "    {",
        '      agent: "reviewer",',
        `      task: "Review the current diff for ${issuePath}. Focus on correctness/regressions, issue-scope drift, and whether tests verify behavior rather than implementation details. Do not edit files.",`,
        "      output: false,",
        "      progress: false",
        "    }",
      ].join("\n"),
    ];
  }).join(",\n");

  return [
    ...commonPromptPreamble(slug, batch, statusRows, autoAdvance),
    "",
    "Execution rules:",
    `1. Read \`PLANS/${slug}/issues/index.md\` and these issue files first:`,
    ...batch.issuePaths.map((path) => `   - \`${path}\``),
    "2. Verify prerequisite batches are already integrated. If not, stop and report the blocker.",
    "3. Run one `issue-worker-tdd` implementation pass followed by one no-edit `reviewer` pass for each issue, in order.",
    "4. If an earlier issue in the serial batch blocks, stop there, persist its status, and leave untouched later issues unchanged.",
    "5. Only mark an issue `complete` after its parent-branch integrated state passes the required validation.",
    "",
    "Use this exact subagent payload shape:",
    "```ts",
    "subagent({",
    "  chain: [",
    steps,
    "  ],",
    '  context: "fresh",',
    "  clarify: false",
    "})",
    "```",
    ...buildSettlementInstructions(slug, batch),
  ].join("\n");
}

function buildBatchPrompt(cwd: string, slug: string, batch: BatchEntry, statusRows: Map<string, IssueStatusRow>, autoAdvance: boolean): string {
  if (batch.parallel && batch.issuePaths.length > 1) {
    const executionMode = resolveParallelBatchExecutionMode(cwd, slug, batch);
    if (executionMode.kind === "serial-fallback") {
      return buildParallelFallbackPrompt(cwd, slug, batch, statusRows, autoAdvance, executionMode.reason);
    }
    return buildParallelPrompt(cwd, slug, batch, statusRows, autoAdvance, executionMode.artifactSource);
  }
  if (batch.issuePaths.length === 1) {
    return buildSingleIssuePrompt(cwd, slug, {
      number: batch.issueNumbers[0] ?? "",
      path: batch.issuePaths[0]!,
    }, statusRows, autoAdvance);
  }
  return buildSequentialBatchPrompt(cwd, slug, batch, statusRows, autoAdvance);
}

async function pickSlug(args: string, ctx: { cwd: string; ui: { notify: (message: string, level?: string) => void; select: (title: string, options: string[]) => Promise<string | null>; }; }, commandName: string): Promise<string | null> {
  let slug = extractSlug(args);
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

async function pickBatch(cwd: string, slug: string, provided: string, ctx: { ui: { notify: (message: string, level?: string) => void; select: (title: string, options: string[]) => Promise<string | null>; }; }): Promise<BatchEntry | null> {
  const content = readIssuesIndex(cwd, slug);
  if (!content) {
    ctx.ui.notify(`Missing PLANS/${slug}/issues/index.md`, "warning");
    return null;
  }
  const batches = parseBatches(content);
  if (batches.length === 0) {
    ctx.ui.notify(issueEntriesMissingMessage(slug), "warning");
    return null;
  }
  const resolved = resolveBatch(batches, provided);
  if (resolved) return resolved;
  if (provided.trim()) {
    ctx.ui.notify(`Unknown batch '${provided}' for ${slug}`, "warning");
    return null;
  }
  if (batches.length === 1) return batches[0] ?? null;
  const options = batches.map((batch) => `${batch.key}${batch.parallel ? " (parallel)" : ""} — ${batch.issueNumbers.join(" + ")}`);
  const picked = await ctx.ui.select(`Pick an execution batch for ${slug}`, options);
  if (!picked) return null;
  const key = picked.split("—")[0]?.replace(/\(parallel\)/i, "").trim() ?? "";
  return resolveBatch(batches, key);
}

async function pickIssue(cwd: string, slug: string, provided: string, ctx: { ui: { notify: (message: string, level?: string) => void; select: (title: string, options: string[]) => Promise<string | null>; }; }): Promise<IssueEntry | null> {
  const content = readIssuesIndex(cwd, slug);
  if (!content) {
    ctx.ui.notify(`Missing PLANS/${slug}/issues/index.md`, "warning");
    return null;
  }
  const issues = parseIssueEntries(content);
  if (issues.length === 0) {
    ctx.ui.notify(issueEntriesMissingMessage(slug), "warning");
    return null;
  }
  const resolved = resolveIssue(issues, provided);
  if (resolved) return resolved;
  if (provided.trim()) {
    ctx.ui.notify(`Unknown issue '${provided}' for ${slug}`, "warning");
    return null;
  }
  if (issues.length === 1) return issues[0] ?? null;
  const options = issues.map((issue) => `${issue.number} — ${basename(issue.path)}`);
  const picked = await ctx.ui.select(`Pick an issue for ${slug}`, options);
  if (!picked) return null;
  const issueNumber = picked.split("—")[0]?.trim() ?? "";
  return resolveIssue(issues, issueNumber);
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

function persistStatusAudit(pi: ExtensionAPI, slug: string, updates: IssueStatusUpdate[], source: string) {
  pi.appendEntry(STATUS_UPDATE_ENTRY_TYPE, {
    slug,
    source,
    updates: updates.map((update) => ({
      issue: extractIssueNumber(update.issue),
      status: update.status,
      note: sanitizeNote(update.note),
    })),
    updatedAt: Date.now(),
  });
}

function selectNextWork(state: IssueIndexState):
  | { kind: "done" }
  | { kind: "blocked"; row: IssueStatusRow }
  | { kind: "work"; batch: BatchEntry } {
  for (const batch of state.batches) {
    const remainingNumbers = batch.issueNumbers.filter((issue) => state.statusRows.get(issue)?.status !== "complete");
    if (remainingNumbers.length === 0) continue;

    const blockedIssue = remainingNumbers.find((issue) => state.statusRows.get(issue)?.status === "blocked");
    if (blockedIssue) {
      const row = state.statusRows.get(blockedIssue);
      if (row) return { kind: "blocked", row };
    }

    const remainingPaths = remainingNumbers
      .map((issue) => state.issueEntries.find((entry) => entry.number === issue)?.path)
      .filter((path): path is string => Boolean(path));

    return {
      kind: "work",
      batch: {
        key: batch.key,
        label: batch.label,
        parallel: batch.parallel && remainingNumbers.length > 1,
        issueNumbers: remainingNumbers,
        issuePaths: remainingPaths,
      },
    };
  }

  return { kind: "done" };
}

function issueNumbersToStartForBatch(cwd: string, slug: string, batch: BatchEntry): string[] {
  if (!(batch.parallel && batch.issuePaths.length > 1)) {
    return batch.issueNumbers;
  }

  const executionMode = resolveParallelBatchExecutionMode(cwd, slug, batch);
  if (executionMode.kind === "serial-fallback") {
    const firstIssue = batch.issueNumbers[0];
    return firstIssue ? [firstIssue] : [];
  }

  return batch.issueNumbers;
}

function startIssueWork(cwd: string, slug: string, issueNumbers: string[], options?: { reopenAll?: boolean }): { state: IssueIndexState; appliedUpdates: IssueStatusUpdate[] } {
  const state = ensureExecutionStatusTable(cwd, slug);
  if (!state) throw new Error(`Missing PLANS/${slug}/issues/index.md`);

  const appliedUpdates = issueNumbers
    .map((issue) => extractIssueNumber(issue))
    .filter(Boolean)
    .flatMap((issue) => {
      const row = state.statusRows.get(issue);
      if (!row) return [];
      if (!options?.reopenAll && row.status === "progress") return [];
      return [{ issue, status: "progress" as IssueStatus, note: "" }];
    });

  if (appliedUpdates.length === 0) {
    return { state, appliedUpdates };
  }

  return {
    state: updateIssueStatusesOnDisk(cwd, slug, appliedUpdates),
    appliedUpdates,
  };
}

function notify(ctx: { ui: { notify: (message: string, level?: string) => void; }; }, message: string, level: string = "info") {
  ctx.ui.notify(message, level);
}

function stopBuild(pi: ExtensionAPI, slug: string, digest: string, reason: string) {
  persistBuildState(pi, {
    active: false,
    slug,
    lastStatusDigest: digest,
    lastBatchKey: null,
    lastIssueNumbers: [],
    stopReason: reason,
  });
}

function pauseActiveBuildForManualCommand(pi: ExtensionAPI, ctx: { sessionManager: { getBranch?: () => SessionCustomEntry[]; getEntries?: () => SessionCustomEntry[]; }; ui: { notify: (message: string, level?: string) => void; }; }, commandName: string) {
  const activeBuild = loadBuildState(ctx);
  if (!activeBuild?.active) return;
  stopBuild(pi, activeBuild.slug, activeBuild.lastStatusDigest, `paused-by-${commandName}`);
  notify(ctx, `Paused /build ${activeBuild.slug} while starting /${commandName}. Run /build ${activeBuild.slug} to resume.`, "info");
}

function launchNextBuildStep(pi: ExtensionAPI, ctx: { cwd: string; ui: { notify: (message: string, level?: string) => void; }; isIdle: () => boolean; }, slug: string): boolean {
  let state = ensureExecutionStatusTable(ctx.cwd, slug);
  if (!state) {
    notify(ctx, `Missing PLANS/${slug}/issues/index.md`, "warning");
    stopBuild(pi, slug, "", "missing-index");
    return false;
  }

  const selection = selectNextWork(state);
  if (selection.kind === "done") {
    stopBuild(pi, slug, state.digest, "complete");
    notify(ctx, `/build ${slug} complete — all issues are marked complete.`, "success");
    return false;
  }

  if (selection.kind === "blocked") {
    stopBuild(pi, slug, state.digest, "blocked");
    const detail = selection.row.note
      ? ` (${selection.row.note})`
      : " (blocked with no recorded note; rerun the issue and persist a blocker note with issue_status_update)";
    notify(ctx, `/build ${slug} stopped on blocked issue ${selection.row.issue}${detail}`, "warning");
    return false;
  }

  const issueNumbersToStart = issueNumbersToStartForBatch(ctx.cwd, slug, selection.batch);
  const needsStart = issueNumbersToStart.some((issue) => state?.statusRows.get(issue)?.status !== "progress");
  if (needsStart) {
    const started = startIssueWork(ctx.cwd, slug, issueNumbersToStart);
    state = started.state;
    if (started.appliedUpdates.length > 0) {
      persistStatusAudit(pi, slug, started.appliedUpdates, "build-start");
    }
  }

  const prompt = buildBatchPrompt(ctx.cwd, slug, selection.batch, state.statusRows, true);
  persistBuildState(pi, {
    active: true,
    slug,
    lastStatusDigest: state.digest,
    lastBatchKey: selection.batch.key,
    lastIssueNumbers: [...selection.batch.issueNumbers],
    stopReason: null,
  });
  sendPrompt(pi, prompt, ctx, `Queued /build ${slug} ${selection.batch.key}`);
  return true;
}

export default function issueExec(pi: ExtensionAPI) {
  const IssueStatusSchema = StringEnum(["todo", "progress", "blocked", "complete"] as const);

  pi.on("input", async (event, ctx) => {
    if (event.source === "extension") {
      return { action: "continue" };
    }

    const state = loadBuildState(ctx);
    if (!state?.active) {
      return { action: "continue" };
    }

    const text = event.text.trim();
    if (text.startsWith("/build")) {
      return { action: "continue" };
    }

    stopBuild(pi, state.slug, state.lastStatusDigest, "paused-by-user-input");
    notify(ctx, `Paused /build ${state.slug}. Run /build ${state.slug} to resume.`, "info");
    return { action: "continue" };
  });

  pi.on("agent_end", async (_event, ctx) => {
    const state = loadBuildState(ctx);
    if (!state?.active) return;
    if (typeof ctx.hasPendingMessages === "function" && ctx.hasPendingMessages()) return;

    const latest = ensureExecutionStatusTable(ctx.cwd, state.slug);
    if (!latest) {
      stopBuild(pi, state.slug, state.lastStatusDigest, "missing-index");
      notify(ctx, `Missing PLANS/${state.slug}/issues/index.md`, "warning");
      return;
    }

    if (state.lastBatchKey && latest.digest === state.lastStatusDigest) {
      stopBuild(pi, state.slug, latest.digest, "no-status-progress");
      const issueList = state.lastIssueNumbers.length > 0 ? ` (${state.lastIssueNumbers.join(", ")})` : "";
      notify(ctx, `/build ${state.slug} stopped because batch ${state.lastBatchKey}${issueList} ended without changing \`## Execution status\`. Call issue_status_update with a changed status or note before ending the batch turn.`, "warning");
      return;
    }

    launchNextBuildStep(pi, ctx, state.slug);
  });

  pi.registerTool({
    name: "issue_status_update",
    label: "Issue Status Update",
    description: "Deterministically update the `## Execution status` table in `PLANS/<slug>/issues/index.md`.",
    promptSnippet: "Deterministically update the Execution status table in PLANS/<slug>/issues/index.md.",
    promptGuidelines: [
      "Use issue_status_update from the top-level parent session after settling an issue or batch.",
      "Persist issue status in issues/index.md; do not rename issue files to encode status.",
      "Use `progress` for work or rework still needed, `blocked` for real blockers, and `complete` only after integration plus validation.",
    ],
    parameters: Type.Object({
      slug: Type.String({ description: "Project slug under PLANS/<slug>/issues" }),
      updates: Type.Array(Type.Object({
        issue: Type.String({ description: "Issue number like 01 or a path containing the issue number" }),
        status: IssueStatusSchema,
        note: Type.Optional(Type.String({ description: "Concise status note. Use when status is progress or blocked." })),
      }), { minItems: 1 }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const updates = validateIssueStatusUpdates(params.slug, params.updates.map((update) => ({
        issue: update.issue,
        status: update.status as IssueStatus,
        note: update.note,
      })));

      const nextState = updateIssueStatusesOnDisk(ctx.cwd, params.slug, updates);
      persistStatusAudit(pi, params.slug, updates, "tool");
      const summary = updates.map((update) => `${update.issue}:${update.status}`).join(", ");
      return {
        content: [{ type: "text", text: `Updated ${nextState.indexPath}: ${summary}` }],
        details: {
          indexPath: nextState.indexPath,
          updates,
          digest: nextState.digest,
        },
      };
    },
  });

  pi.registerCommand("build", {
    description: "Deterministically run all issue batches for a slug using PLANS/<slug>/issues/index.md until complete or blocked",
    getArgumentCompletions: (prefix) => getSlugCompletions(process.cwd(), prefix.trimStart()),
    handler: async (args, ctx) => {
      const slug = await pickSlug(args, ctx, "build");
      if (!slug) return;

      const activeBuild = loadBuildState(ctx);
      if (activeBuild?.active && activeBuild.slug !== slug) {
        ctx.ui.notify(`/build ${activeBuild.slug} is already active. Let it finish or pause it before starting /build ${slug}.`, "warning");
        return;
      }
      if (activeBuild?.active && activeBuild.slug === slug) {
        if (ctx.isIdle()) {
          launchNextBuildStep(pi, ctx, slug);
        } else {
          ctx.ui.notify(`/build ${slug} is already active and will continue after the current turn.`, "info");
        }
        return;
      }

      const state = ensureExecutionStatusTable(ctx.cwd, slug);
      if (!state) {
        ctx.ui.notify(`Missing PLANS/${slug}/issues/index.md`, "warning");
        return;
      }
      if (state.issueEntries.length === 0) {
        ctx.ui.notify(issueEntriesMissingMessage(slug), "warning");
        return;
      }

      persistBuildState(pi, {
        active: true,
        slug,
        lastStatusDigest: state.digest,
        lastBatchKey: null,
        lastIssueNumbers: [],
        stopReason: null,
      });

      if (ctx.isIdle()) {
        launchNextBuildStep(pi, ctx, slug);
      } else {
        ctx.ui.notify(`Queued /build for ${slug}`, "info");
      }
    },
  });

  pi.registerCommand("issue-batch", {
    description: "Run one issue batch from PLANS/<slug>/issues/index.md and persist status updates in the Execution status table",
    getArgumentCompletions: (prefix) => {
      const trimmed = prefix.trimStart();
      if (!trimmed.includes(" ")) return getSlugCompletions(process.cwd(), trimmed);
      const [slug, ...rest] = trimmed.split(/\s+/);
      return getBatchCompletions(process.cwd(), slug ?? "", rest.join(" "));
    },
    handler: async (args, ctx) => {
      const slug = await pickSlug(args, ctx, "issue-batch");
      if (!slug) return;
      const rawBatch = args.trim().split(/\s+/).slice(1).join(" ");
      const batch = await pickBatch(ctx.cwd, slug, rawBatch, ctx);
      if (!batch) return;
      pauseActiveBuildForManualCommand(pi, ctx, "issue-batch");
      const started = startIssueWork(ctx.cwd, slug, issueNumbersToStartForBatch(ctx.cwd, slug, batch), { reopenAll: true });
      if (started.appliedUpdates.length > 0) {
        persistStatusAudit(pi, slug, started.appliedUpdates, "command-batch-start");
      }
      sendPrompt(pi, buildBatchPrompt(ctx.cwd, slug, batch, started.state.statusRows, false), ctx, `Queued /issue-batch for ${slug} ${batch.key}`);
    },
  });

  pi.registerCommand("issue-run", {
    description: "Run one issue with TDD implementation plus review and persist status updates in the Execution status table",
    getArgumentCompletions: (prefix) => {
      const trimmed = prefix.trimStart();
      if (!trimmed.includes(" ")) return getSlugCompletions(process.cwd(), trimmed);
      const [slug, ...rest] = trimmed.split(/\s+/);
      return getIssueCompletions(process.cwd(), slug ?? "", rest.join(" "));
    },
    handler: async (args, ctx) => {
      const slug = await pickSlug(args, ctx, "issue-run");
      if (!slug) return;
      const rawIssue = args.trim().split(/\s+/).slice(1).join(" ");
      const issue = await pickIssue(ctx.cwd, slug, rawIssue, ctx);
      if (!issue) return;
      pauseActiveBuildForManualCommand(pi, ctx, "issue-run");
      const started = startIssueWork(ctx.cwd, slug, [issue.number], { reopenAll: true });
      if (started.appliedUpdates.length > 0) {
        persistStatusAudit(pi, slug, started.appliedUpdates, "command-issue-start");
      }
      sendPrompt(pi, buildSingleIssuePrompt(ctx.cwd, slug, issue, started.state.statusRows, false), ctx, `Queued /issue-run for ${slug} ${issue.number}`);
    },
  });
}
