/**
 * GitHub Issue Draft Extension
 *
 * Interactive flow inside pi:
 *   /gh-create-issue
 *   /gh-create-issue short issue title
 *
 * The command does NOT create the issue immediately.
 * Instead it validates the current workspace, prompts for a title if needed,
 * and loads a review prompt template into pi's input editor so the user can:
 * - use their external-editor shortcut to open the draft in an editor
 * - fill the issue template there
 * - quit the editor, then press Enter in pi
 *
 * The agent then reviews/critiques the issue at a high level first.
 * Once the user explicitly approves, the agent can call `create_github_issue`
 * to publish the issue to the current GitHub repo.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { promisify } from "node:util";
import { Type } from "typebox";

const execFileAsync = promisify(execFile);

type NotifyLevel = "info" | "success" | "warning" | "error";

type ExecFileError = NodeJS.ErrnoException & {
  stdout?: string;
  stderr?: string;
  code?: number | string;
};

type RepoResolution =
  | {
      ok: true;
      repoRoot: string;
      repo: string;
      remoteName: string;
      remoteUrl: string;
    }
  | {
      ok: false;
      message: string;
    };

type CreateGitHubIssueResult = {
  ok: boolean;
  title: string;
  repo?: string;
  repoRoot?: string;
  remoteName?: string;
  remoteUrl?: string;
  issueUrl?: string;
  issueNumber?: number;
  message: string;
};

type GitHubRemote = {
  repo: string;
  remoteName: string;
  remoteUrl: string;
};

async function execGit(cwd: string, args: string[], signal?: AbortSignal) {
  return execFileAsync("git", args, { cwd, signal });
}

async function execGh(args: string[], cwd?: string, signal?: AbortSignal) {
  return execFileAsync("gh", args, {
    cwd,
    signal,
    env: {
      ...process.env,
      GH_PAGER: "cat",
    },
  });
}

function extractExecErrorMessage(error: unknown, fallback: string): string {
  if (!error || typeof error !== "object") {
    return fallback;
  }

  const err = error as ExecFileError;
  const candidates = [err.stderr, err.stdout, err.message]
    .map((value) => value?.trim())
    .filter((value): value is string => Boolean(value));

  return candidates[0] ?? fallback;
}

function parseGitHubRepo(remoteUrl: string): string | undefined {
  const trimmed = remoteUrl.trim();

  const sshMatch = trimmed.match(/^git@github\.com:([^/]+\/[^/]+?)(?:\.git)?\/?$/i);
  if (sshMatch?.[1]) {
    return sshMatch[1];
  }

  const sshUrlMatch = trimmed.match(/^ssh:\/\/git@github\.com\/([^/]+\/[^/]+?)(?:\.git)?\/?$/i);
  if (sshUrlMatch?.[1]) {
    return sshUrlMatch[1];
  }

  const httpsMatch = trimmed.match(/^https?:\/\/(?:[^@/]+@)?github\.com\/([^/]+\/[^/]+?)(?:\.git)?\/?$/i);
  if (httpsMatch?.[1]) {
    return httpsMatch[1];
  }

  return undefined;
}

function parseGitHubRemotes(output: string): GitHubRemote[] {
  const remotes: GitHubRemote[] = [];

  for (const rawLine of output.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }

    const match = line.match(/^(\S+)\s+(\S+)\s+\((fetch|push)\)$/);
    if (!match || match[3] !== "fetch") {
      continue;
    }

    const remoteName = match[1] ?? "";
    const remoteUrl = match[2] ?? "";
    const repo = parseGitHubRepo(remoteUrl);
    if (!remoteName || !remoteUrl || !repo) {
      continue;
    }

    remotes.push({ repo, remoteName, remoteUrl });
  }

  return remotes.sort((left, right) => {
    if (left.remoteName === "origin" && right.remoteName !== "origin") {
      return -1;
    }
    if (left.remoteName !== "origin" && right.remoteName === "origin") {
      return 1;
    }
    return left.remoteName.localeCompare(right.remoteName);
  });
}

async function getRepoRoot(cwd: string, signal?: AbortSignal): Promise<string | null> {
  try {
    const { stdout } = await execGit(cwd, ["rev-parse", "--show-toplevel"], signal);
    const repoRoot = stdout.trim();
    return repoRoot || null;
  } catch {
    return null;
  }
}

async function getGitHubRemote(repoRoot: string, signal?: AbortSignal): Promise<GitHubRemote | null> {
  try {
    const { stdout } = await execGit(repoRoot, ["remote", "-v"], signal);
    return parseGitHubRemotes(stdout)[0] ?? null;
  } catch {
    return null;
  }
}

async function ensureGhInstalled(signal?: AbortSignal): Promise<{ ok: true } | { ok: false; message: string }> {
  try {
    await execGh(["--version"], undefined, signal);
    return { ok: true };
  } catch {
    return {
      ok: false,
      message: "GitHub CLI (`gh`) is not installed or not available in PATH.",
    };
  }
}

async function ensureGhAuth(signal?: AbortSignal): Promise<{ ok: true } | { ok: false; message: string }> {
  try {
    await execGh(["auth", "status"], undefined, signal);
    return { ok: true };
  } catch (error) {
    const detail = extractExecErrorMessage(error, "Run `gh auth login` first.");
    return {
      ok: false,
      message: `GitHub CLI is not authenticated. ${detail}`,
    };
  }
}

async function resolveGitHubWorkspace(cwd: string, signal?: AbortSignal): Promise<RepoResolution> {
  const repoRoot = await getRepoRoot(cwd, signal);
  if (!repoRoot) {
    return {
      ok: false,
      message: "/gh-create-issue must be run inside a git workspace. No git repo was found for the current directory.",
    };
  }

  const remote = await getGitHubRemote(repoRoot, signal);
  if (!remote) {
    return {
      ok: false,
      message: "This git workspace does not have a GitHub remote. Add a GitHub remote before using /gh-create-issue.",
    };
  }

  const ghInstalled = await ensureGhInstalled(signal);
  if (!ghInstalled.ok) {
    return ghInstalled;
  }

  const ghAuth = await ensureGhAuth(signal);
  if (!ghAuth.ok) {
    return ghAuth;
  }

  return {
    ok: true,
    repoRoot,
    repo: remote.repo,
    remoteName: remote.remoteName,
    remoteUrl: remote.remoteUrl,
  };
}

function buildIssueBodyTemplate(): string {
  return `## What
- What is the issue, request, or opportunity?
- Who is affected?
- What outcome do we want?
- What does success look like?

## Why
- Why is this worth addressing now?
- What user, business, or engineering outcome are we targeting?
- What pain, risk, or opportunity is driving this?

## Scope
- In scope:
- Out of scope:

## Constraints
- 

## Risks / assumptions
- 

## References
- Links:
- Docs:
- Code:
- Notes:

## Open Questions
- 
`;
}

function buildReviewPrompt(repo: string, issueTitle: string): string {
  return `Repository: ${repo}
Working title: ${issueTitle}

I am drafting a GitHub issue.

Please follow this workflow exactly:
1. First review the draft issue body below at a high level.
2. Critique it, recommend improvements, and ask structured clarification questions about the problem, affected users, desired outcome, scope, constraints, risks, urgency, dependencies, and non-goals.
3. Stay high level for now. Focus on issue framing and issue quality, not implementation details.
4. Do NOT create the GitHub issue yet.
5. If we refine the title during review, use the latest explicitly approved title.
6. Once I explicitly approve the issue, call \`create_github_issue\` using:
   - the approved title
   - the approved issue body only
   - the current workspace GitHub repo \`${repo}\`
7. Do NOT include these workflow instructions or metadata lines in the final GitHub issue body.

Draft issue body:

${buildIssueBodyTemplate()}`;
}

function notify(ctx: ExtensionContext, message: string, level: NotifyLevel) {
  if (ctx.hasUI) {
    ctx.ui.notify(message, level);
    return;
  }

  console.log(`[gh-create-issue] ${level.toUpperCase()}: ${message}`);
}

async function promptForIssueTitle(args: string, ctx: ExtensionContext): Promise<string | undefined> {
  const fromArgs = args.trim();
  if (fromArgs) {
    return fromArgs;
  }

  if (!ctx.hasUI) {
    return undefined;
  }

  const entered = await ctx.ui.input("Issue title:", "short issue summary");
  return entered?.trim() || undefined;
}

async function seedGitHubIssuePrompt(args: string, ctx: ExtensionContext): Promise<void> {
  const workspace = await resolveGitHubWorkspace(ctx.cwd);
  if (!workspace.ok) {
    notify(ctx, workspace.message, "error");
    return;
  }

  const issueTitle = await promptForIssueTitle(args, ctx);
  if (!issueTitle) {
    notify(ctx, ctx.hasUI ? "Cancelled /gh-create-issue." : "Usage: /gh-create-issue <issue-title>", "warning");
    return;
  }

  const prompt = buildReviewPrompt(workspace.repo, issueTitle);
  if (!ctx.hasUI) {
    console.log(prompt);
    return;
  }

  ctx.ui.setEditorText(prompt);
  notify(
    ctx,
    `Issue draft prompt loaded for ${workspace.repo}. Use your app.editor.external shortcut to open it in your external editor, fill the template, then press Enter to send it to the agent.`,
    "info",
  );
}

function normalizeIssueBody(body: string): string {
  const trimmed = body.trim();
  return trimmed ? `${trimmed}\n` : "";
}

function extractIssueUrl(text: string): string | undefined {
  return text.match(/https:\/\/github\.com\/[^\s]+\/issues\/\d+/)?.[0];
}

function extractIssueNumber(issueUrl: string | undefined): number | undefined {
  if (!issueUrl) {
    return undefined;
  }

  const match = issueUrl.match(/\/issues\/(\d+)(?:\D|$)/);
  if (!match?.[1]) {
    return undefined;
  }

  const parsed = Number(match[1]);
  return Number.isFinite(parsed) ? parsed : undefined;
}

async function createGitHubIssue(
  title: string,
  body: string,
  ctx: ExtensionContext,
  signal?: AbortSignal,
): Promise<CreateGitHubIssueResult> {
  const normalizedTitle = title.trim();
  if (!normalizedTitle) {
    return {
      ok: false,
      title: normalizedTitle,
      message: "GitHub issue title cannot be empty.",
    };
  }

  const normalizedBody = normalizeIssueBody(body);
  if (!normalizedBody) {
    return {
      ok: false,
      title: normalizedTitle,
      message: "GitHub issue body cannot be empty.",
    };
  }

  const workspace = await resolveGitHubWorkspace(ctx.cwd, signal);
  if (!workspace.ok) {
    return {
      ok: false,
      title: normalizedTitle,
      message: workspace.message,
    };
  }

  try {
    const { stdout, stderr } = await execGh(
      [
        "issue",
        "create",
        "--repo",
        workspace.repo,
        "--title",
        normalizedTitle,
        "--body",
        normalizedBody,
      ],
      homedir(),
      signal,
    );

    const combinedOutput = `${stdout}\n${stderr}`.trim();
    const issueUrl = extractIssueUrl(combinedOutput);
    const issueNumber = extractIssueNumber(issueUrl);

    return {
      ok: true,
      title: normalizedTitle,
      repo: workspace.repo,
      repoRoot: workspace.repoRoot,
      remoteName: workspace.remoteName,
      remoteUrl: workspace.remoteUrl,
      issueUrl,
      issueNumber,
      message: issueUrl
        ? `Created GitHub issue${issueNumber ? ` #${issueNumber}` : ""} in ${workspace.repo}: ${issueUrl}`
        : `Created GitHub issue in ${workspace.repo}.`,
    };
  } catch (error) {
    return {
      ok: false,
      title: normalizedTitle,
      repo: workspace.repo,
      repoRoot: workspace.repoRoot,
      remoteName: workspace.remoteName,
      remoteUrl: workspace.remoteUrl,
      message: `Failed to create GitHub issue in ${workspace.repo}: ${extractExecErrorMessage(error, "Unknown gh issue create error")}`,
    };
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("gh-create-issue", {
    description: "Prepare a GitHub issue draft in the editor; after approval the agent can create the issue in the current repo",
    handler: async (args, ctx) => {
      await seedGitHubIssuePrompt(args, ctx);
    },
  });

  pi.registerTool({
    name: "create_github_issue",
    label: "Create GitHub Issue",
    description: "Create a GitHub issue in the current workspace's GitHub repository using the GitHub CLI",
    promptSnippet: "Create a GitHub issue in the current workspace's GitHub repository using the GitHub CLI.",
    promptGuidelines: [
      "Use create_github_issue only after the user explicitly approves creating the GitHub issue.",
      "Use create_github_issue with the latest approved issue title and the approved issue body only.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "Approved GitHub issue title" }),
      body: Type.String({ description: "Approved GitHub issue body in markdown" }),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const result = await createGitHubIssue(params.title, params.body, ctx, signal);
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
        isError: !result.ok,
      };
    },
  });
}
