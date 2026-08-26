/**
 * Global dangerous-command guard for pi.
 *
 * Auto-discovered from ~/.pi/agent/extensions/.
 *
 * Guards assistant bash tool calls and user ! shell commands before running
 * obviously destructive operations such as rm/rm -rf, interpreter-driven
 * file deletion APIs (for example fs.rmSync or os.remove), DROP DATABASE,
 * DROP COLUMN, TRUNCATE, terraform destroy, kubectl delete, and similar.
 *
 * UX choices:
 * - Allow once
 * - Deny
 * - Always allow this session
 *
 * Session-level "always allow" state is persisted into the current pi session,
 * so it survives /reload and resume of the same session.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const STATE_ENTRY_TYPE = "danger-guard-state";
const STATUS_KEY = "danger-guard";

const SAFE_COMMAND_PATTERNS: RegExp[] = [
	/^\s*rm\s+(?:-[a-zA-Z]*\s+)*(?:false|true|null)\s*$/i, // rm false, rm -f false, etc.
	/^\s*rm\s+(?:-[a-zA-Z]*\s+)*\/dev\/null\s*$/i, // rm /dev/null
];

const DANGEROUS_PATTERNS: Array<{ label: string; regex: RegExp }> = [
	{ label: "file deletion command (rm/rmdir/unlink)", regex: /\b(?:rm|rmdir|unlink)\b/i },
	{ label: "Node.js filesystem deletion API", regex: /\b(?:fs\.(?:rmSync|unlinkSync|rmdirSync)|rmSync|unlinkSync|rmdirSync)\s*\(/i },
	{ label: "Node.js fs.promises deletion API", regex: /\bfs\.promises\.(?:rm|unlink|rmdir)\s*\(/i },
	{ label: "Python filesystem deletion API", regex: /\b(?:os\.(?:remove|unlink|rmdir)|shutil\.rmtree)\s*\(/i },
	{ label: "pathlib deletion API", regex: /\bpathlib\.Path\([^\n]*\)\.(?:unlink|rmdir)\s*\(/i },
	{ label: "destructive wipe command (shred/srm)", regex: /\b(?:shred|srm)\b/i },
	{ label: "find -delete", regex: /\bfind\b[\s\S]{0,200}\s-delete\b/i },
	{ label: "database drop/delete command", regex: /\b(?:drop|delete)\s+database\b/i },
	{ label: "Mongo dropDatabase()", regex: /\bdropdatabase\s*\(/i },
	{ label: "framework database reset/drop", regex: /\b(?:db:drop|db:reset|prisma\s+migrate\s+reset|sequelize\s+db:drop)\b/i },
	{ label: "schema or table drop", regex: /\bdrop\s+(?:schema|table)\b/i },
	{ label: "column drop/delete command", regex: /\b(?:(?:drop|delete|remove)\s+column|alter\s+table[\s\S]{0,200}drop\s+column)\b/i },
	{ label: "bulk row deletion", regex: /\bdelete\s+from\b/i },
	{ label: "truncate table", regex: /\btruncate\b/i },
	{ label: "Kubernetes resource deletion", regex: /\bkubectl\s+delete\b/i },
	{ label: "Helm uninstall", regex: /\bhelm\s+uninstall\b/i },
	{ label: "Docker destructive cleanup", regex: /\bdocker\s+(?:rm|rmi|container\s+rm|image\s+rm|volume\s+rm|system\s+prune)\b/i },
	{ label: "Terraform destroy", regex: /\bterraform\s+destroy\b/i },
	{ label: "filesystem format command", regex: /\bmkfs(?:\.[a-z0-9_+-]+)?\b/i },
	{ label: "dd writing directly to /dev", regex: /\bdd\b[\s\S]{0,200}\bof=\/dev\//i },
];

function summarizeReasons(command: string): string[] {
	// Check whitelist first
	for (const safePattern of SAFE_COMMAND_PATTERNS) {
		if (safePattern.test(command)) return [];
	}

	const matches = new Set<string>();
	for (const pattern of DANGEROUS_PATTERNS) {
		if (pattern.regex.test(command)) matches.add(pattern.label);
	}
	return [...matches];
}

function formatReasons(reasons: string[]): string {
	return reasons.map((reason) => `• ${reason}`).join("\n");
}

function blockMessage(source: string, reasons: string[]): string {
	return `Blocked ${source}. Matched guardrails: ${reasons.join(", ")}`;
}

export default function dangerousCommandGuard(pi: ExtensionAPI) {
	let alwaysAllowThisSession = false;

	const restoreState = (ctx: ExtensionContext) => {
		alwaysAllowThisSession = false;
		for (const entry of ctx.sessionManager.getEntries()) {
			if (entry.type !== "custom" || entry.customType !== STATE_ENTRY_TYPE) continue;
			if (typeof entry.data?.alwaysAllowThisSession === "boolean") {
				alwaysAllowThisSession = entry.data.alwaysAllowThisSession;
			}
		}
	};

	const updateStatus = (ctx: ExtensionContext) => {
		const statusText = alwaysAllowThisSession
			? "danger-guard: always allow (session)"
			: "danger-guard: prompt dangerous commands";

		if (!ctx.hasUI) return;

		const styledStatus = alwaysAllowThisSession
			? ctx.ui.theme.bg("toolErrorBg", ctx.ui.theme.fg("dim", ` ${statusText} `))
			: ctx.ui.theme.bg("toolSuccessBg", ctx.ui.theme.fg("dim", ` ${statusText} `));

		ctx.ui.setStatus(STATUS_KEY, styledStatus);
	};

	const setAlwaysAllow = (value: boolean, ctx: ExtensionContext) => {
		alwaysAllowThisSession = value;
		pi.appendEntry(STATE_ENTRY_TYPE, {
			alwaysAllowThisSession: value,
			updatedAt: Date.now(),
		});
		updateStatus(ctx);
	};

	const decide = async (source: string, command: string, reasons: string[], ctx: ExtensionContext) => {
		if (alwaysAllowThisSession) return "allow" as const;

		if (!ctx.hasUI) {
			return "deny" as const;
		}

		const choice = await ctx.ui.select(
			[
				`⚠️ Dangerous ${source} detected.`,
				"",
				command,
				"",
				"Matched guardrails:",
				formatReasons(reasons),
				"",
				"What do you want to do?",
			].join("\n"),
			["Allow once", "Deny", "Always allow"],
		);

		const decision =
			choice === "Allow once" ? "allow" : choice === "Always allow" ? "always" : "deny";

		switch (decision) {
			case "allow":
				ctx.ui.notify(`Allowed ${source} once`, "warning");
				return "allow" as const;
			case "always":
				setAlwaysAllow(true, ctx);
				ctx.ui.notify("Danger guard switched to always-allow for this session", "warning");
				return "allow" as const;
			case "deny":
			default:
				ctx.ui.notify(`Blocked ${source}`, "warning");
				return "deny" as const;
		}
	};

	pi.on("session_start", async (_event, ctx) => {
		restoreState(ctx);
		updateStatus(ctx);
		if (alwaysAllowThisSession) {
			ctx.ui.notify(
				"Danger guard is currently set to always allow dangerous commands for this session. Use /danger-guard-reset to re-enable prompts.",
				"warning",
			);
		}
	});

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;

		const command = typeof event.input.command === "string" ? event.input.command : "";
		const reasons = summarizeReasons(command);
		if (reasons.length === 0) return undefined;

		const decision = await decide("bash command", command, reasons, ctx);
		if (decision === "allow") return undefined;

		return {
			block: true,
			reason: ctx.hasUI
				? blockMessage("bash command", reasons)
				: `${blockMessage("bash command", reasons)}. No UI available for confirmation.`,
		};
	});

	pi.on("user_bash", async (event, ctx) => {
		const reasons = summarizeReasons(event.command);
		if (reasons.length === 0) return undefined;

		const decision = await decide("shell command", event.command, reasons, ctx);
		if (decision === "allow") return undefined;

		return {
			result: {
				output: `${blockMessage("shell command", reasons)}\nCommand: ${event.command}`,
				exitCode: 1,
				cancelled: false,
				truncated: false,
			},
		};
	});

	pi.registerCommand("danger-guard-status", {
		description: "Show dangerous-command guard status",
		handler: async (_args, ctx) => {
			updateStatus(ctx);
			ctx.ui.notify(
				alwaysAllowThisSession
					? "Danger guard: always allow dangerous commands in this session"
					: "Danger guard: prompt before dangerous commands",
				"info",
			);
		},
	});

	pi.registerCommand("danger-guard-reset", {
		description: "Re-enable dangerous-command prompts for this session",
		handler: async (_args, ctx) => {
			setAlwaysAllow(false, ctx);
			ctx.ui.notify("Danger guard reset. Dangerous commands will prompt again.", "success");
		},
	});
}
