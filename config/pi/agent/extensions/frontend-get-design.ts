/**
 * Frontend Get Design Extension
 *
 * Deterministic flow:
 *   /frontend-get-design <slug>
 *
 * Fetches a DESIGN.md file from VoltAgent/awesome-design-md and writes it to
 * DESIGN.md in the current workspace root.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { withFileMutationQueue } from "@earendil-works/pi-coding-agent";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { Type } from "typebox";

const SOURCE_REPO = "VoltAgent/awesome-design-md";
const SOURCE_TREE_URL = "https://github.com/VoltAgent/awesome-design-md/tree/main/design-md";
const SOURCE_RAW_BASE_URL = "https://raw.githubusercontent.com/VoltAgent/awesome-design-md/refs/heads/main/design-md";

type NotifyLevel = "info" | "warning" | "error";
type WriteStatus = "created" | "updated" | "unchanged";

export type FrontendGetDesignResult = {
	ok: true;
	slug: string;
	sourceUrl: string;
	destinationPath: string;
	writeStatus: WriteStatus;
	bytes: number;
	message: string;
};

class FrontendGetDesignError extends Error {
	readonly level: NotifyLevel;

	constructor(message: string, level: NotifyLevel = "error") {
		super(message);
		this.name = "FrontendGetDesignError";
		this.level = level;
	}
}

function normalizeDesignSlug(input: string): string {
	let slug = input.trim();
	slug = slug.replace(/^['"]+|['"]+$/g, "");
	slug = slug.replace(/^https?:\/\/raw\.githubusercontent\.com\/VoltAgent\/awesome-design-md\/refs\/heads\/main\/design-md\//i, "");
	slug = slug.replace(/^https?:\/\/github\.com\/VoltAgent\/awesome-design-md\/tree\/main\/design-md\//i, "");
	slug = slug.replace(/^design-md\//i, "");
	slug = slug.replace(/\/(?:DESIGN|README)\.md$/i, "");
	slug = slug.replace(/^\/+|\/+$/g, "");
	return slug.toLowerCase();
}

function validateDesignSlug(slug: string): void {
	if (!slug) {
		throw new FrontendGetDesignError(
			"Usage: /frontend-get-design <slug>\nExample: /frontend-get-design vercel",
			"warning",
		);
	}

	if (!/^[a-z0-9][a-z0-9._-]*$/.test(slug) || slug.includes("..") || slug.includes("/")) {
		throw new FrontendGetDesignError(
			`Invalid design slug \"${slug}\". Use a single repo slug like \"vercel\", \"linear.app\", or \"stripe\".`,
			"warning",
		);
	}
}

function buildSourceUrl(slug: string): string {
	return `${SOURCE_RAW_BASE_URL}/${encodeURIComponent(slug)}/DESIGN.md`;
}

function buildResultMessage(
	slug: string,
	destinationPath: string,
	sourceUrl: string,
	writeStatus: WriteStatus,
	bytes: number,
): string {
	if (writeStatus === "unchanged") {
		return `DESIGN.md already matches slug \"${slug}\" at ${destinationPath}. Source: ${sourceUrl} (${bytes} bytes).`;
	}

	const action = writeStatus === "created" ? "Created" : "Updated";
	return `${action} ${destinationPath} from slug \"${slug}\". Source: ${sourceUrl} (${bytes} bytes).`;
}

function isNotFoundError(error: unknown): boolean {
	return typeof error === "object" && error !== null && "code" in error && (error as NodeJS.ErrnoException).code === "ENOENT";
}

function throwIfAborted(signal?: AbortSignal, message = "frontend_get_design was aborted."): void {
	if (signal?.aborted) {
		throw new FrontendGetDesignError(message);
	}
}

async function fetchDesignMarkdown(slug: string, signal?: AbortSignal): Promise<{ sourceUrl: string; content: string }> {
	const sourceUrl = buildSourceUrl(slug);
	let response: Response;

	try {
		response = await fetch(sourceUrl, {
			signal,
			headers: {
				accept: "text/plain, text/markdown;q=0.9, */*;q=0.1",
				"user-agent": "pi-frontend-get-design-extension",
			},
		});
	} catch (error) {
		if (signal?.aborted) {
			throw new FrontendGetDesignError("frontend_get_design was aborted while fetching the remote DESIGN.md.");
		}
		const message = error instanceof Error ? error.message : String(error);
		throw new FrontendGetDesignError(`Failed to fetch DESIGN.md for slug \"${slug}\" from ${SOURCE_REPO}: ${message}`);
	}

	if (response.status === 404) {
		throw new FrontendGetDesignError(
			`No DESIGN.md found for slug \"${slug}\" in ${SOURCE_REPO}.\nTried: ${sourceUrl}\nBrowse available slugs: ${SOURCE_TREE_URL}`,
		);
	}

	if (!response.ok) {
		throw new FrontendGetDesignError(
			`Failed to fetch DESIGN.md for slug \"${slug}\" from ${SOURCE_REPO} (HTTP ${response.status} ${response.statusText}).\nURL: ${sourceUrl}`,
		);
	}

	const content = await response.text();
	if (!content.trim()) {
		throw new FrontendGetDesignError(`Fetched an empty DESIGN.md for slug \"${slug}\".\nURL: ${sourceUrl}`);
	}

	return { sourceUrl, content };
}

async function persistDesignFile(
	destinationPath: string,
	content: string,
	signal?: AbortSignal,
): Promise<{ writeStatus: WriteStatus; bytes: number }> {
	const normalized = `${content.replace(/\r\n/g, "\n").replace(/\s+$/, "")}\n`;

	return withFileMutationQueue(destinationPath, async () => {
		throwIfAborted(signal, "frontend_get_design was aborted before writing DESIGN.md.");

		let existing: string | null = null;
		try {
			existing = await readFile(destinationPath, "utf8");
		} catch (error) {
			if (!isNotFoundError(error)) {
				throw error;
			}
		}

		const writeStatus: WriteStatus = existing === null ? "created" : existing === normalized ? "unchanged" : "updated";
		if (writeStatus !== "unchanged") {
			throwIfAborted(signal, "frontend_get_design was aborted before updating DESIGN.md.");
			await writeFile(destinationPath, normalized, "utf8");
		}

		return {
			writeStatus,
			bytes: Buffer.byteLength(normalized, "utf8"),
		};
	});
}

async function promptForSlug(args: string, ctx: ExtensionContext): Promise<string | undefined> {
	const fromArgs = args.trim();
	if (fromArgs) {
		return fromArgs;
	}

	if (!ctx.hasUI) {
		return undefined;
	}

	const entered = await ctx.ui.input("Design slug:", "vercel");
	return entered?.trim() || undefined;
}

function notify(ctx: ExtensionContext, message: string, level: NotifyLevel): void {
	if (ctx.hasUI) {
		ctx.ui.notify(message, level);
		return;
	}

	if (level === "error") {
		console.error(`[frontend-get-design] ${message}`);
		return;
	}

	console.log(`[frontend-get-design] ${message}`);
}

function toErrorMessage(error: unknown): { message: string; level: NotifyLevel } {
	if (error instanceof FrontendGetDesignError) {
		return { message: error.message, level: error.level };
	}
	if (error instanceof Error) {
		return { message: error.message, level: "error" };
	}
	return { message: String(error), level: "error" };
}

export async function fetchFrontendDesignToWorkspace(
	input: string,
	cwd: string,
	signal?: AbortSignal,
): Promise<FrontendGetDesignResult> {
	const slug = normalizeDesignSlug(input);
	validateDesignSlug(slug);
	throwIfAborted(signal);

	const destinationPath = join(cwd, "DESIGN.md");

	try {
		const { sourceUrl, content } = await fetchDesignMarkdown(slug, signal);
		throwIfAborted(signal);
		const { writeStatus, bytes } = await persistDesignFile(destinationPath, content, signal);

		return {
			ok: true,
			slug,
			sourceUrl,
			destinationPath,
			writeStatus,
			bytes,
			message: buildResultMessage(slug, destinationPath, sourceUrl, writeStatus, bytes),
		};
	} catch (error) {
		if (error instanceof FrontendGetDesignError) {
			throw error;
		}
		const message = error instanceof Error ? error.message : String(error);
		throw new FrontendGetDesignError(`Failed to save DESIGN.md in ${cwd}: ${message}`);
	}
}

async function runFrontendGetDesign(args: string, ctx: ExtensionContext, signal?: AbortSignal): Promise<FrontendGetDesignResult> {
	const rawSlug = await promptForSlug(args, ctx);
	if (!rawSlug) {
		throw new FrontendGetDesignError(
			ctx.hasUI ? "Cancelled /frontend-get-design." : "Usage: /frontend-get-design <slug>",
			"warning",
		);
	}

	return fetchFrontendDesignToWorkspace(rawSlug, ctx.cwd, signal);
}

export default function frontendGetDesignExtension(pi: ExtensionAPI) {
	pi.registerCommand("frontend-get-design", {
		description: "Fetch a VoltAgent DESIGN.md by slug and save it as DESIGN.md in the workspace root",
		handler: async (args, ctx) => {
			try {
				const result = await runFrontendGetDesign(args, ctx);
				notify(ctx, result.message, "info");
			} catch (error) {
				const { message, level } = toErrorMessage(error);
				notify(ctx, message, level);
			}
		},
	});

	pi.registerTool({
		name: "frontend_get_design",
		label: "Frontend Get Design",
		description: "Fetch a DESIGN.md theme from VoltAgent/awesome-design-md by slug and write it to DESIGN.md in the current workspace root.",
		promptSnippet: "Fetch a DESIGN.md theme from VoltAgent/awesome-design-md and write it to DESIGN.md in the current workspace root.",
		promptGuidelines: [
			"Use frontend_get_design when the user wants to import or sync a DESIGN.md theme from VoltAgent/awesome-design-md.",
			"Ask the user for a slug before using frontend_get_design if they have not provided one.",
			"Prefer frontend_get_design over manual bash/curl/web fetching when the source is VoltAgent/awesome-design-md.",
		],
		parameters: Type.Object({
			slug: Type.String({
				description: "Design slug under VoltAgent/awesome-design-md/design-md, for example: vercel, linear.app, stripe",
			}),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			const result = await fetchFrontendDesignToWorkspace(params.slug, ctx.cwd, signal);
			return {
				content: [{ type: "text", text: result.message }],
				details: result,
			};
		},
	});
}
