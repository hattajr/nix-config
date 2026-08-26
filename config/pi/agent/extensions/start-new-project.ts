/**
 * Start New Project Extension
 *
 * Interactive flow inside pi:
 *   /start-new-project my-project-name
 *
 * The command does NOT scaffold immediately.
 * Instead it loads a review prompt template into pi's input editor so the user can:
 * - use their external-editor shortcut to open the draft in an editor
 * - write the initial draft there
 * - quit the editor, then press Enter in pi
 *
 * The agent then reviews the draft at a high level first. Once the user approves,
 * the agent can call `start_new_project` to scaffold the repo/branch/files.
 *
 * Non-interactive scaffold behavior remains available via the `start_new_project` tool.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { constants } from "node:fs";
import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { join } from "node:path";
import { promisify } from "node:util";
import { Type } from "typebox";

const execFileAsync = promisify(execFile);
const START_NEW_PROJECT_RE = /^start\s+new\s+project\s*--\s*(.+)$/i;

type NotifyLevel = "info" | "success" | "warning" | "error";
type GitignoreStatus = "created" | "updated" | "existing";
type BranchStatus = "created" | "existing";
type DraftWriteStatus = "created" | "updated" | "kept";

type StartNewProjectResult = {
  ok: boolean;
  requestedName: string;
  projectSlug?: string;
  workspaceRoot?: string;
  repoRoot?: string;
  repoInitialized?: boolean;
  gitignoreStatus?: GitignoreStatus;
  draftPath?: string;
  branchStatus?: BranchStatus;
  draftAlreadyExists?: boolean;
  draftWriteStatus?: DraftWriteStatus;
  message: string;
};

type PreparedProject = {
  ok: true;
  requestedName: string;
  projectSlug: string;
  workspaceRoot: string;
  repoRoot: string;
  repoInitialized: boolean;
  gitignoreStatus?: GitignoreStatus;
  draftPath: string;
  branchStatus: BranchStatus;
  draftAlreadyExists: boolean;
  trashDirCreated: boolean;
};

const GITIGNORE_SECTIONS = [
  {
    header: "# OS",
    lines: [".DS_Store", "Thumbs.db"],
  },
  {
    header: "# Editors / IDEs",
    lines: [".vscode/", ".idea/", "*.swp", "*.swo", "*~"],
  },
  {
    header: "# Logs",
    lines: ["*.log", "logs/"],
  },
  {
    header: "# Environment / secrets",
    lines: [".env", ".env.*", "!.env.example"],
  },
  {
    header: "# Dependencies",
    lines: ["node_modules/"],
  },
  {
    header: "# Python",
    lines: ["__pycache__/", "*.py[cod]", ".python-version", ".venv/", "venv/"],
  },
  {
    header: "# Build / coverage",
    lines: ["build/", "dist/", "out/", "coverage/", ".tmp/", "tmp/"],
  },
  {
    header: "# Planning artifacts",
    lines: ["PLANS/"],
  },
  {
    header: "# Local scratch space",
    lines: [".trash/"],
  },
] as const;

const DEFAULT_GITIGNORE = `${GITIGNORE_SECTIONS.flatMap((section) => [
  section.header,
  ...section.lines,
  "",
]).join("\n")}`.trimEnd() + "\n";

function slugifyProjectName(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-");
}

function buildDraftTemplate(projectName: string, branchName: string): string {
  const today = new Date().toISOString().slice(0, 10);

  return `# ${projectName}

Status: draft  
Created: ${today}  
Branch: ${branchName}

This draft is the working document that will later be refined into \`PRD.md\`.

## What
- What are we building?
- Who is it for?
- What problem does it solve?
- What does success look like?

## Why
- Why is this worth doing now?
- What user, business, or engineering outcome are we targeting?
- What pain, risk, or opportunity is driving this work?

## How
- Proposed approach
- Scope
- Non-goals
- Milestones / phases
- Risks / assumptions

## References
- Links:
- Docs:
- Code:
- Issues / tickets:
- Notes:

## Open Questions
- 
`;
}

function buildReviewPrompt(projectName: string, projectSlug: string): string {
  return `Project name: ${projectName}
Project slug: ${projectSlug}
Planned draft path: PLANS/${projectSlug}/draft.md

I am starting a new project.

Please follow this workflow exactly:
1. First review the initial draft below at a high level.
2. Critique it, recommend improvements, and ask structured clarification questions about goals, users, scope, success criteria, constraints, risks, and non-goals.
3. Stay high level for now. Do not get into implementation details yet.
4. Do NOT create files, branches, or directories yet.
5. Do NOT call \`start_new_project\` yet.
6. Once I explicitly approve the draft, then scaffold the project by:
   - calling \`start_new_project\` with project name \`${projectName}\`
   - ensuring the repo scaffold exists (.trash/, .gitignore with PLANS/ ignored, branch, PLANS/${projectSlug}/draft.md)
   - updating \`PLANS/${projectSlug}/draft.md\` with the approved draft content

Initial draft:

# ${projectName}

## What
- What are we building?
- Who is it for?
- What problem does it solve?
- What does success look like?

## Why
- Why is this worth doing now?
- What user, business, or engineering outcome are we targeting?
- What pain, risk, or opportunity is driving this work?

## Scope
- In scope:
- Out of scope:

## Constraints
- 

## Risks / assumptions
- 

## Open Questions
- 
`;
}

async function execGit(cwd: string, args: string[]) {
  return execFileAsync("git", args, { cwd });
}

async function getRepoRoot(cwd: string): Promise<string> {
  const { stdout } = await execGit(cwd, ["rev-parse", "--show-toplevel"]);
  return stdout.trim();
}

async function getCurrentBranch(gitCwd: string): Promise<string> {
  try {
    const { stdout } = await execGit(gitCwd, ["branch", "--show-current"]);
    return stdout.trim();
  } catch {
    return "";
  }
}

async function branchExists(gitCwd: string, branchName: string): Promise<boolean> {
  if ((await getCurrentBranch(gitCwd)) === branchName) {
    return true;
  }

  try {
    await execGit(gitCwd, ["show-ref", "--verify", "--quiet", `refs/heads/${branchName}`]);
    return true;
  } catch {
    return false;
  }
}

async function switchToBranch(gitCwd: string, branchName: string): Promise<BranchStatus> {
  if ((await getCurrentBranch(gitCwd)) === branchName) {
    return "existing";
  }

  if (await branchExists(gitCwd, branchName)) {
    await execGit(gitCwd, ["switch", branchName]);
    return "existing";
  }

  await execGit(gitCwd, ["switch", "-c", branchName]);
  return "created";
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function ensureGitignore(gitignorePath: string): Promise<GitignoreStatus> {
  if (!(await pathExists(gitignorePath))) {
    await writeFile(gitignorePath, DEFAULT_GITIGNORE, "utf8");
    return "created";
  }

  const existing = await readFile(gitignorePath, "utf8");
  const normalizedLines = new Set(
    existing
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean),
  );

  const missingSections = GITIGNORE_SECTIONS
    .map((section) => ({
      ...section,
      lines: section.lines.filter((line) => !normalizedLines.has(line)),
    }))
    .filter((section) => section.lines.length > 0);

  if (missingSections.length === 0) {
    return "existing";
  }

  const additionLines = ["# Added by /start-new-project"];
  for (const section of missingSections) {
    additionLines.push("", section.header, ...section.lines);
  }

  const next = `${existing.replace(/\s*$/, "")}\n\n${additionLines.join("\n")}\n`;
  await writeFile(gitignorePath, next, "utf8");
  return "updated";
}

async function ensureWorkspaceRepo(workspaceRoot: string): Promise<{
  repoRoot: string;
  repoInitialized: boolean;
  gitignoreStatus?: GitignoreStatus;
}> {
  let repoInitialized = false;

  try {
    await getRepoRoot(workspaceRoot);
  } catch {
    await execGit(workspaceRoot, ["init"]);
    repoInitialized = true;
  }

  const repoRoot = await getRepoRoot(workspaceRoot);
  const gitignoreStatus = await ensureGitignore(join(workspaceRoot, ".gitignore"));
  return { repoRoot, repoInitialized, gitignoreStatus };
}

function notify(ctx: ExtensionContext, message: string, level: NotifyLevel) {
  if (ctx.hasUI) {
    ctx.ui.notify(message, level);
    return;
  }

  console.log(`[start-new-project] ${level.toUpperCase()}: ${message}`);
}

async function prepareProjectWorkspace(requestedName: string, ctx: ExtensionContext): Promise<PreparedProject | StartNewProjectResult> {
  const trimmedName = requestedName.trim();
  const projectSlug = slugifyProjectName(trimmedName);

  if (!projectSlug) {
    return {
      ok: false,
      requestedName: trimmedName,
      message: "Could not derive a valid project name. Try letters, numbers, or dashes.",
    };
  }

  try {
    const workspaceRoot = ctx.cwd;
    const { repoRoot, repoInitialized, gitignoreStatus } = await ensureWorkspaceRepo(workspaceRoot);
    const branchStatus = await switchToBranch(workspaceRoot, projectSlug);

    const trashDir = join(workspaceRoot, ".trash");
    const plansDir = join(workspaceRoot, "PLANS");
    const projectDir = join(plansDir, projectSlug);
    const draftPath = join(projectDir, "draft.md");

    const trashDirExists = await pathExists(trashDir);
    if (!trashDirExists) {
      await mkdir(trashDir, { recursive: true });
    }
    await mkdir(projectDir, { recursive: true });

    return {
      ok: true,
      requestedName: trimmedName,
      projectSlug,
      workspaceRoot,
      repoRoot,
      repoInitialized,
      gitignoreStatus,
      draftPath,
      branchStatus,
      draftAlreadyExists: await pathExists(draftPath),
      trashDirCreated: !trashDirExists,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      requestedName: trimmedName,
      projectSlug,
      message: `Failed to start project: ${message}`,
    };
  }
}

function buildResult(prepared: PreparedProject, draftWriteStatus: DraftWriteStatus): StartNewProjectResult {
  const messageParts: string[] = [];

  if (prepared.repoInitialized) {
    messageParts.push(`initialized git repo in ${prepared.repoRoot}`);
  }

  const gitignoreMessage = prepared.gitignoreStatus === "created"
    ? `created .gitignore in ${prepared.workspaceRoot}`
    : prepared.gitignoreStatus === "updated"
      ? `updated .gitignore in ${prepared.workspaceRoot}`
      : `kept existing .gitignore in ${prepared.workspaceRoot}`;
  messageParts.push(gitignoreMessage);

  const branchMessage = prepared.branchStatus === "created"
    ? `created and switched to branch ${prepared.projectSlug}`
    : `switched to existing branch ${prepared.projectSlug}`;
  messageParts.push(branchMessage);
  messageParts.push(
    prepared.trashDirCreated
      ? `created .trash/ in ${prepared.workspaceRoot}`
      : `kept existing .trash/ in ${prepared.workspaceRoot}`,
  );

  const draftMessage = draftWriteStatus === "created"
    ? "created draft.md"
    : draftWriteStatus === "updated"
      ? "updated draft.md"
      : "kept existing draft.md";
  messageParts.push(`${draftMessage} at ${prepared.draftPath}`);

  return {
    ok: true,
    requestedName: prepared.requestedName,
    projectSlug: prepared.projectSlug,
    workspaceRoot: prepared.workspaceRoot,
    repoRoot: prepared.repoRoot,
    repoInitialized: prepared.repoInitialized,
    gitignoreStatus: prepared.gitignoreStatus,
    draftPath: prepared.draftPath,
    branchStatus: prepared.branchStatus,
    draftAlreadyExists: prepared.draftAlreadyExists,
    draftWriteStatus,
    message: messageParts.join("; "),
  };
}

async function writeDraft(prepared: PreparedProject, draftContent: string, draftWriteStatus: DraftWriteStatus): Promise<StartNewProjectResult> {
  try {
    if (draftWriteStatus !== "kept") {
      const normalized = draftContent.replace(/\s+$/, "");
      await writeFile(prepared.draftPath, `${normalized}\n`, "utf8");
    }

    return buildResult(prepared, draftWriteStatus);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      requestedName: prepared.requestedName,
      projectSlug: prepared.projectSlug,
      draftPath: prepared.draftPath,
      message: `Failed to write draft: ${message}`,
    };
  }
}

async function startNewProject(requestedName: string, ctx: ExtensionContext): Promise<StartNewProjectResult> {
  const prepared = await prepareProjectWorkspace(requestedName, ctx);
  if (!prepared.ok) {
    return prepared;
  }

  if (prepared.draftAlreadyExists) {
    return buildResult(prepared, "kept");
  }

  const defaultDraft = buildDraftTemplate(prepared.requestedName, prepared.projectSlug);
  return writeDraft(prepared, defaultDraft, "created");
}

async function promptForProjectName(args: string, ctx: ExtensionContext): Promise<string | undefined> {
  const fromArgs = args.trim();
  if (fromArgs) {
    return fromArgs;
  }

  if (!ctx.hasUI) {
    return undefined;
  }

  const entered = await ctx.ui.input("Project name:", "my-project-name");
  return entered?.trim() || undefined;
}

async function seedStartNewProjectPrompt(args: string, ctx: ExtensionContext): Promise<void> {
  const requestedName = await promptForProjectName(args, ctx);
  if (!requestedName) {
    notify(ctx, "Usage: /start-new-project <project-name>", "warning");
    return;
  }

  const projectSlug = slugifyProjectName(requestedName);
  if (!projectSlug) {
    notify(ctx, "Could not derive a valid project slug. Try letters, numbers, or dashes.", "error");
    return;
  }

  if (!ctx.hasUI) {
    console.log(buildReviewPrompt(requestedName, projectSlug));
    return;
  }

  ctx.ui.setEditorText(buildReviewPrompt(requestedName, projectSlug));
  notify(ctx, "Draft prompt loaded into the editor. Use your external-editor shortcut to open it in your editor, write the draft, then press Enter to send it to the agent.", "info");
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("start-new-project", {
    description: "Prepare a draft-review prompt in the editor; after approval the agent can scaffold PLANS/<slug>/draft.md",
    handler: async (args, ctx) => {
      await seedStartNewProjectPrompt(args, ctx);
    },
  });

  pi.registerTool({
    name: "start_new_project",
    label: "Start New Project",
    description: "Create or switch to a project branch, ensure .trash/ and .gitignore (including PLANS/), and scaffold PLANS/<slug>/draft.md under the current workspace",
    promptSnippet: "Create or switch to a project branch, ensure .trash/ and .gitignore (including PLANS/), and scaffold PLANS/<slug>/draft.md under the current workspace",
    promptGuidelines: [
      "Use start_new_project when the user explicitly approves creating the new project scaffold.",
      "After calling start_new_project, update PLANS/<slug>/draft.md with the approved draft content if needed.",
    ],
    parameters: Type.Object({
      projectName: Type.String({ description: "Human-readable project name or slug" }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const result = await startNewProject(params.projectName, ctx);
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
        isError: !result.ok,
      };
    },
  });

  pi.on("input", async (event, ctx) => {
    if (event.source === "extension") {
      return { action: "continue" };
    }

    const match = event.text.trim().match(START_NEW_PROJECT_RE);
    if (!match) {
      return { action: "continue" };
    }

    await seedStartNewProjectPrompt(match[1], ctx);
    return { action: "handled" };
  });
}
