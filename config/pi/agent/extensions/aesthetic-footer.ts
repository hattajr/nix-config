import { execFile } from "node:child_process";
import { hostname, userInfo } from "node:os";
import { promisify } from "node:util";

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

const execFileAsync = promisify(execFile);
const USER_AT_HOST = `${safeUsername()}@${safeHostname()}`;
const CONFLICT_CODES = new Set(["DD", "AU", "UD", "UA", "DU", "AA", "UU"]);
const STATUS_REFRESH_DELAY_MS = 120;

function safeUsername(): string {
  try {
    return userInfo().username || "user";
  } catch {
    return process.env.USER || process.env.USERNAME || "user";
  }
}

function safeHostname(): string {
  try {
    return hostname().split(".")[0] || "host";
  } catch {
    return "host";
  }
}

function formatTokens(count: number): string {
  if (count < 1000) return count.toString();
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  if (count < 10000000) return `${(count / 1000000).toFixed(1)}M`;
  return `${Math.round(count / 1000000)}M`;
}

function sanitizeStatusText(text: string): string {
  return text.replace(/[\r\n\t]/g, " ").replace(/ +/g, " ").trim();
}

function formatPath(cwd: string): string {
  const home = process.env.HOME || process.env.USERPROFILE;
  if (home && cwd.startsWith(home)) {
    return `~${cwd.slice(home.length)}`;
  }
  return cwd;
}

function fitLine(left: string, right: string, width: number): string {
  if (width <= 0) return "";

  const leftWidth = visibleWidth(left);
  const rightWidth = visibleWidth(right);
  if (leftWidth + rightWidth + 1 <= width) {
    return left + " ".repeat(width - leftWidth - rightWidth) + right;
  }

  if (leftWidth >= width) {
    return truncateToWidth(left, width, "…");
  }

  const availableForRight = Math.max(0, width - leftWidth - 1);
  if (availableForRight === 0) {
    return truncateToWidth(left, width, "…");
  }

  const trimmedRight = truncateToWidth(right, availableForRight, "");
  const trimmedRightWidth = visibleWidth(trimmedRight);
  return left + " ".repeat(Math.max(1, width - leftWidth - trimmedRightWidth)) + trimmedRight;
}

type GitState = {
  inRepo: boolean;
  dirty: boolean;
  untracked: boolean;
  conflicts: boolean;
};

async function getGitState(cwd: string): Promise<GitState> {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["status", "--porcelain", "--untracked-files=normal"],
      { cwd },
    );

    let dirty = false;
    let untracked = false;
    let conflicts = false;

    for (const rawLine of stdout.split(/\r?\n/)) {
      const line = rawLine.trimEnd();
      if (!line) continue;

      const code = line.slice(0, 2);
      if (code === "??") {
        untracked = true;
        continue;
      }

      if (CONFLICT_CODES.has(code) || code.includes("U")) {
        conflicts = true;
        continue;
      }

      dirty = true;
    }

    return { inRepo: true, dirty, untracked, conflicts };
  } catch {
    return { inRepo: false, dirty: false, untracked: false, conflicts: false };
  }
}

function formatRepoStatus(state: GitState): string {
  if (!state.inRepo) return "";
  if (state.conflicts) return "✗";

  let marks = "";
  if (state.dirty) marks += "!";
  if (state.untracked) marks += "?";
  return marks || "✓";
}

function styleRepoStatus(theme: ExtensionContext["ui"]["theme"], state: GitState): string {
  const text = formatRepoStatus(state);
  if (!text) return "";
  if (state.conflicts) return theme.fg("error", text);
  if (text === "✓") return theme.fg("success", text);
  return theme.fg("warning", text);
}

function getUsageTotals(ctx: ExtensionContext): {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
} {
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let cost = 0;

  for (const entry of ctx.sessionManager.getEntries()) {
    if (entry.type === "message" && entry.message.role === "assistant") {
      input += entry.message.usage.input;
      output += entry.message.usage.output;
      cacheRead += entry.message.usage.cacheRead;
      cacheWrite += entry.message.usage.cacheWrite;
      cost += entry.message.usage.cost.total;
    }
  }

  return { input, output, cacheRead, cacheWrite, cost };
}

function renderStatsLeft(theme: ExtensionContext["ui"]["theme"], ctx: ExtensionContext): string {
  const totals = getUsageTotals(ctx);
  const parts: string[] = [];

  if (totals.input) parts.push(`↑${formatTokens(totals.input)}`);
  if (totals.output) parts.push(`↓${formatTokens(totals.output)}`);
  if (totals.cacheRead) parts.push(`R${formatTokens(totals.cacheRead)}`);
  if (totals.cacheWrite) parts.push(`W${formatTokens(totals.cacheWrite)}`);

  const usingSubscription = !!(ctx.model && ctx.modelRegistry.isUsingOAuth(ctx.model));
  if (totals.cost || usingSubscription) {
    parts.push(`$${totals.cost.toFixed(3)}${usingSubscription ? " (sub)" : ""}`);
  }

  const usage = ctx.getContextUsage();
  const percent = usage?.percent;
  const contextWindow = usage?.contextWindow ?? ctx.model?.contextWindow;
  if (contextWindow && percent !== null && percent !== undefined) {
    const text = `ctx ${percent.toFixed(1)}%/${formatTokens(contextWindow)}`;
    if (percent > 90) {
      parts.push(theme.fg("error", text));
    } else if (percent > 70) {
      parts.push(theme.fg("warning", text));
    } else {
      parts.push(text);
    }
  } else {
    parts.push("ctx ?");
  }

  return theme.fg("dim", parts.join(" "));
}

function renderStatsRight(theme: ExtensionContext["ui"]["theme"], ctx: ExtensionContext, pi: ExtensionAPI): string {
  const model = ctx.model?.id || "no-model";
  const thinking = pi.getThinkingLevel();
  return theme.fg("dim", `${model} • ${thinking}`);
}

class AestheticFooter {
  private readonly pi: ExtensionAPI;
  private readonly ctx: ExtensionContext;
  private readonly tui: { requestRender: () => void };
  private readonly theme: ExtensionContext["ui"]["theme"];
  private readonly footerData: {
    getGitBranch(): string | null;
    getExtensionStatuses(): ReadonlyMap<string, string>;
    onBranchChange(callback: () => void): () => void;
  };
  private gitState: GitState = { inRepo: false, dirty: false, untracked: false, conflicts: false };
  private refreshTimer: ReturnType<typeof setTimeout> | undefined;
  private disposed = false;
  private readonly unsubscribeBranchChange: () => void;

  constructor(
    pi: ExtensionAPI,
    ctx: ExtensionContext,
    tui: { requestRender: () => void },
    theme: ExtensionContext["ui"]["theme"],
    footerData: {
      getGitBranch(): string | null;
      getExtensionStatuses(): ReadonlyMap<string, string>;
      onBranchChange(callback: () => void): () => void;
    },
  ) {
    this.pi = pi;
    this.ctx = ctx;
    this.tui = tui;
    this.theme = theme;
    this.footerData = footerData;
    this.unsubscribeBranchChange = footerData.onBranchChange(() => this.scheduleRefresh(0));
    this.scheduleRefresh(0);
  }

  scheduleRefresh(delay = STATUS_REFRESH_DELAY_MS): void {
    if (this.disposed) return;
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = undefined;
      void this.refreshGitState();
    }, delay);
  }

  private async refreshGitState(): Promise<void> {
    const nextState = await getGitState(this.ctx.cwd);
    if (this.disposed) return;
    this.gitState = nextState;
    this.tui.requestRender();
  }

  render(width: number): string[] {
    const sep = this.theme.fg("dim", " · ");
    const branch = this.footerData.getGitBranch();
    const repoStatus = branch ? styleRepoStatus(this.theme, this.gitState) : "";

    const promptParts = [
      this.theme.fg("muted", `> ${USER_AT_HOST}`),
      this.theme.fg("accent", `󰉋 ${formatPath(this.ctx.cwd)}`),
      branch ? this.theme.fg("success", ` ${branch}`) : "",
      repoStatus,
    ].filter(Boolean);

    const promptLine = truncateToWidth(promptParts.join(sep), width, "…");
    const statsLine = fitLine(
      renderStatsLeft(this.theme, this.ctx),
      renderStatsRight(this.theme, this.ctx, this.pi),
      width,
    );

    const lines = [promptLine, statsLine];

    const extensionStatuses = this.footerData.getExtensionStatuses();
    if (extensionStatuses.size > 0) {
      const statusLine = Array.from(extensionStatuses.entries())
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([, text]) => sanitizeStatusText(text))
        .join(" ");
      lines.push(truncateToWidth(statusLine, width, this.theme.fg("dim", "…")));
    }

    return lines;
  }

  invalidate(): void {}

  dispose(): void {
    this.disposed = true;
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    this.unsubscribeBranchChange();
  }
}

export default function (pi: ExtensionAPI) {
  let activeFooter: AestheticFooter | undefined;

  const refreshFooter = () => activeFooter?.scheduleRefresh();

  pi.on("session_start", (_event, ctx) => {
    ctx.ui.setFooter((tui, theme, footerData) => {
      activeFooter?.dispose();
      activeFooter = new AestheticFooter(pi, ctx, tui, theme, footerData);
      return activeFooter;
    });
  });

  pi.on("turn_end", () => {
    refreshFooter();
  });

  pi.on("user_bash", () => {
    refreshFooter();
  });

  pi.on("session_shutdown", () => {
    activeFooter?.dispose();
    activeFooter = undefined;
  });
}
