/**
 * Telegram notification extension for pi.
 *
 * Features:
 * - Sends a Telegram message when the parent agent finishes processing.
 * - Child/subagent processes never send Telegram notifications.
 * - Persists enabled/disabled state in ~/.pi/agent/settings.json.
 * - Reads Telegram credentials from the "telegram" key in ~/.pi/agent/secrets.json.
 * - Provides /telegram-notify [on|off|toggle|status|test].
 * - Uses an IPv4-only HTTPS request for Telegram to avoid Node fetch
 *   family-autoselection failures on some networks.
 * - Shows footer status via ctx.ui.setStatus().
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { lookup as dnsLookup } from "node:dns/promises";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { request as httpsRequest } from "node:https";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const EXTENSION_DIR = dirname(fileURLToPath(import.meta.url));
const AGENT_DIR = resolve(EXTENSION_DIR, "..");
const SETTINGS_PATH = join(AGENT_DIR, "settings.json");
const SECRETS_PATH = join(AGENT_DIR, "secrets.json");

const SETTINGS_KEY = "telegramNotification";
const STATUS_KEY = "telegram-notif";
const COMMAND_NAME = "telegram-notify";
const MAX_LAST_MESSAGE_CHARS = 1200;
const SUBAGENT_CHILD_ENV = "PI_SUBAGENT_CHILD";
const TELEGRAM_API_HOST = "api.telegram.org";
const TELEGRAM_REQUEST_TIMEOUT_MS = 10_000;

type NotifyLevel = "info" | "warning" | "error";

type TelegramCredentials = {
	botToken?: string;
	chatId?: string;
};

function isPlainObject(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readJsonObject(path: string): Record<string, unknown> {
	if (!existsSync(path)) {
		return {};
	}

	try {
		const raw = readFileSync(path, "utf8").trim();
		if (!raw) {
			return {};
		}

		const parsed = JSON.parse(raw);
		return isPlainObject(parsed) ? parsed : {};
	} catch {
		return {};
	}
}

function writeJsonObject(path: string, value: Record<string, unknown>): void {
	mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
	writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function readEnabledSetting(): boolean {
	const settings = readJsonObject(SETTINGS_PATH);
	const telegramNotification = settings[SETTINGS_KEY];

	if (!isPlainObject(telegramNotification)) {
		return false;
	}

	return typeof telegramNotification.enabled === "boolean" ? telegramNotification.enabled : false;
}

function persistEnabledSetting(enabled: boolean): void {
	const settings = readJsonObject(SETTINGS_PATH);
	const current = settings[SETTINGS_KEY];
	const nextTelegramNotification = isPlainObject(current) ? { ...current, enabled } : { enabled };
	settings[SETTINGS_KEY] = nextTelegramNotification;
	writeJsonObject(SETTINGS_PATH, settings);
}

function readTelegramCredentials(): TelegramCredentials {
	const secrets = readJsonObject(SECRETS_PATH);
	const telegram = secrets.telegram;
	if (!isPlainObject(telegram)) {
		return {};
	}

	const botToken = typeof telegram.botToken === "string" ? telegram.botToken.trim() : "";
	const chatId = typeof telegram.chatId === "string" ? telegram.chatId.trim() : "";

	return {
		botToken: botToken || undefined,
		chatId: chatId || undefined,
	};
}

function getCredentialState():
	| ({ ok: true } & Required<TelegramCredentials>)
	| {
			ok: false;
			message: string;
	  } {
	const { botToken, chatId } = readTelegramCredentials();
	if (!botToken || !chatId) {
		return {
			ok: false,
			message: `Telegram credentials are incomplete in ${SECRETS_PATH}. Fill telegram.botToken and telegram.chatId first.`,
		};
	}

	return {
		ok: true,
		botToken,
		chatId,
	};
}

function notify(ctx: ExtensionContext, message: string, level: NotifyLevel): void {
	if (ctx.hasUI) {
		ctx.ui.notify(message, level);
		return;
	}

	if (level === "error") {
		console.error(`[telegram-notify] ${message}`);
		return;
	}

	console.log(`[telegram-notify] ${message}`);
}

function renderStatus(enabled: boolean, ctx: ExtensionContext): string {
	const text = `telegram-notif: ${enabled ? "ON" : "OFF"}`;
	if (!ctx.hasUI) {
		return text;
	}

	return enabled
		? ctx.ui.theme.bg("toolSuccessBg", ctx.ui.theme.fg("dim", ` ${text} `))
		: ctx.ui.theme.bg("toolErrorBg", ctx.ui.theme.fg("dim", ` ${text} `));
}

function updateStatus(enabled: boolean, ctx: ExtensionContext): void {
	if (!ctx.hasUI) {
		return;
	}

	ctx.ui.setStatus(STATUS_KEY, renderStatus(enabled, ctx));
}

function formatTimestamp(date = new Date()): string {
	return date.toISOString().replace("T", " ").replace("Z", " UTC");
}

function getZellijSessionName(): string {
	const sessionName = process.env.ZELLIJ_SESSION_NAME?.trim();
	return sessionName || "unknown";
}

function normalizeText(input: string): string {
	return input
		.replace(/\r\n/g, "\n")
		.replace(/[ \t]+\n/g, "\n")
		.replace(/\n{3,}/g, "\n\n")
		.trim();
}

function truncateText(input: string, maxChars: number): string {
	if (input.length <= maxChars) {
		return input;
	}

	return `${input.slice(0, Math.max(0, maxChars - 1)).trimEnd()}…`;
}

function extractAssistantText(message: any): string {
	const content = Array.isArray(message?.content) ? message.content : [];
	const textParts: string[] = [];

	for (const block of content) {
		if (block?.type === "text" && typeof block.text === "string") {
			textParts.push(block.text);
		}
	}

	return normalizeText(textParts.join("\n\n"));
}

function findLatestAssistantText(messages: any[]): string {
	for (let index = messages.length - 1; index >= 0; index--) {
		const message = messages[index];
		if (message?.role !== "assistant") {
			continue;
		}

		const text = extractAssistantText(message);
		if (text) {
			return text;
		}
	}

	return "";
}

function buildCompletionMessage(lastAssistantMessage: string): string {
	const snippet = truncateText(
		lastAssistantMessage || "No assistant text was captured for the last reply.",
		MAX_LAST_MESSAGE_CHARS,
	);

	return [
		"Pi finished",
		"",
		`zellij session: ${getZellijSessionName()}`,
		`timestamp: ${formatTimestamp()}`,
		"",
		"last agent message:",
		snippet,
	].join("\n");
}

function buildTestMessage(): string {
	return [
		"Pi telegram notification test",
		"",
		`zellij session: ${getZellijSessionName()}`,
		`timestamp: ${formatTimestamp()}`,
		"",
		"This message was triggered manually from /telegram-notify test.",
	].join("\n");
}

async function postTelegramJsonOverIpv4(botToken: string, body: string): Promise<{ statusCode: number; statusText: string; bodyText: string }> {
	const { address } = await dnsLookup(TELEGRAM_API_HOST, { family: 4 });

	return await new Promise((resolve, reject) => {
		const req = httpsRequest(
			{
				hostname: address,
				port: 443,
				path: `/bot${botToken}/sendMessage`,
				method: "POST",
				agent: false,
				servername: TELEGRAM_API_HOST,
				headers: {
					host: TELEGRAM_API_HOST,
					"content-type": "application/json",
					"content-length": Buffer.byteLength(body),
				},
				timeout: TELEGRAM_REQUEST_TIMEOUT_MS,
			},
			(response) => {
				const chunks: Buffer[] = [];
				response.on("data", (chunk) => {
					chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
				});
				response.on("end", () => {
					resolve({
						statusCode: response.statusCode ?? 0,
						statusText: response.statusMessage ?? "",
						bodyText: Buffer.concat(chunks).toString("utf8"),
					});
				});
				response.on("error", reject);
			},
		);

		req.on("timeout", () => {
			req.destroy(new Error(`Telegram request timed out after ${TELEGRAM_REQUEST_TIMEOUT_MS}ms`));
		});
		req.on("error", reject);
		req.end(body);
	});
}

async function sendTelegramMessage(botToken: string, chatId: string, text: string): Promise<void> {
	const body = JSON.stringify({
		chat_id: chatId,
		text,
		disable_web_page_preview: true,
	});
	const response = await postTelegramJsonOverIpv4(botToken, body);

	let payload: unknown = null;
	try {
		payload = response.bodyText ? JSON.parse(response.bodyText) : null;
	} catch {
		payload = null;
	}

	const telegramError =
		isPlainObject(payload) && typeof payload.description === "string"
			? payload.description
			: `${response.statusCode} ${response.statusText}`.trim() || "Telegram request failed";

	if (response.statusCode < 200 || response.statusCode >= 300 || (isPlainObject(payload) && payload.ok === false)) {
		throw new Error(`Telegram API error: ${telegramError}`);
	}
}

export default function telegramNotifyExtension(pi: ExtensionAPI) {
	if (process.env[SUBAGENT_CHILD_ENV] === "1") {
		return;
	}

	let enabled = readEnabledSetting();
	let warnedAboutMissingCredentials = false;

	const refreshEnabledFromDisk = () => {
		enabled = readEnabledSetting();
		return enabled;
	};

	const setEnabled = (nextEnabled: boolean, ctx: ExtensionContext) => {
		enabled = nextEnabled;
		persistEnabledSetting(nextEnabled);
		warnedAboutMissingCredentials = false;
		updateStatus(enabled, ctx);
	};

	const maybeWarnMissingCredentials = (ctx: ExtensionContext) => {
		if (warnedAboutMissingCredentials) {
			return;
		}

		const credentials = getCredentialState();
		if (credentials.ok) {
			warnedAboutMissingCredentials = false;
			return;
		}

		warnedAboutMissingCredentials = true;
		notify(ctx, credentials.message, "warning");
	};

	const sendWithCredentialGuard = async (
		text: string,
		ctx: ExtensionContext,
		purpose: "completion" | "test",
	): Promise<boolean> => {
		const credentials = getCredentialState();
		if (!credentials.ok) {
			if (purpose === "test") {
				throw new Error(credentials.message);
			}

			maybeWarnMissingCredentials(ctx);
			return false;
		}

		warnedAboutMissingCredentials = false;
		await sendTelegramMessage(credentials.botToken, credentials.chatId, text);
		return true;
	};

	pi.on("session_start", async (_event, ctx) => {
		refreshEnabledFromDisk();
		updateStatus(enabled, ctx);
	});

	pi.on("agent_end", async (event, ctx) => {
		if (!enabled) {
			return;
		}

		const lastAssistantMessage = findLatestAssistantText(event.messages ?? []);
		try {
			await sendWithCredentialGuard(buildCompletionMessage(lastAssistantMessage), ctx, "completion");
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			notify(ctx, `Telegram notification failed: ${message}`, "warning");
		}
	});

	pi.registerCommand(COMMAND_NAME, {
		description: "Toggle, inspect, or test Telegram notifications",
		handler: async (args, ctx) => {
			const action = args.trim().toLowerCase().split(/\s+/)[0] || "toggle";

			switch (action) {
				case "toggle":
				case "": {
					setEnabled(!enabled, ctx);
					const credentials = getCredentialState();
					if (!enabled) {
						notify(ctx, "Telegram notifications disabled.", "info");
						return;
					}

					notify(
						ctx,
						credentials.ok ? "Telegram notifications enabled." : `${credentials.message} Notifications are enabled once credentials are filled.`,
						credentials.ok ? "info" : "warning",
					);
					return;
				}

				case "on": {
					setEnabled(true, ctx);
					const credentials = getCredentialState();
					notify(
						ctx,
						credentials.ok ? "Telegram notifications enabled." : `${credentials.message} Notifications are enabled once credentials are filled.`,
						credentials.ok ? "info" : "warning",
					);
					return;
				}

				case "off": {
					setEnabled(false, ctx);
					notify(ctx, "Telegram notifications disabled.", "info");
					return;
				}

				case "status": {
					refreshEnabledFromDisk();
					updateStatus(enabled, ctx);
					const credentials = getCredentialState();
					notify(
						ctx,
						enabled
							? credentials.ok
								? "Telegram notifications are ON. Credentials are configured."
								: `Telegram notifications are ON, but credentials are incomplete in ${SECRETS_PATH}.`
							: "Telegram notifications are OFF.",
						enabled && !credentials.ok ? "warning" : "info",
					);
					return;
				}

				case "test": {
					try {
						await sendWithCredentialGuard(buildTestMessage(), ctx, "test");
						notify(ctx, "Telegram test notification sent.", "info");
					} catch (error) {
						const message = error instanceof Error ? error.message : String(error);
						notify(ctx, `Telegram test notification failed: ${message}`, "error");
					}
					return;
				}

				default: {
					notify(ctx, `Usage: /${COMMAND_NAME} [on|off|toggle|status|test]`, "warning");
				}
			}
		},
	});
}
