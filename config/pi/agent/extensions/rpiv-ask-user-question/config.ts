import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

export interface GuidanceFields {
	promptSnippet?: string;
	promptGuidelines?: string[];
}

interface AskUserQuestionConfig {
	guidance?: GuidanceFields;
}

function configCandidates(name: string): string[] {
	const base = process.env.XDG_CONFIG_HOME || join(homedir(), ".config");
	return [
		join(base, "rpiv-config", `${name}.json`),
		join(base, `${name}.json`),
		join(base, name, "config.json"),
	];
}

function loadJsonConfig<T>(paths: string[]): T {
	for (const filePath of paths) {
		if (!existsSync(filePath)) continue;
		try {
			const parsed = JSON.parse(readFileSync(filePath, "utf-8")) as T;
			if (parsed && typeof parsed === "object") return parsed;
		} catch {
			// Ignore malformed optional config and fall back to defaults.
		}
	}
	return {} as T;
}

export function validateGuidanceFields(value: unknown): GuidanceFields {
	if (!value || typeof value !== "object" || Array.isArray(value)) return {};
	const input = value as Record<string, unknown>;
	const guidance: GuidanceFields = {};
	if (typeof input.promptSnippet === "string" && input.promptSnippet.trim()) {
		guidance.promptSnippet = input.promptSnippet;
	}
	if (Array.isArray(input.promptGuidelines)) {
		const promptGuidelines = input.promptGuidelines
			.filter((item): item is string => typeof item === "string")
			.map((item) => item.trim())
			.filter(Boolean);
		if (promptGuidelines.length > 0) guidance.promptGuidelines = promptGuidelines;
	}
	return guidance;
}

export function loadConfig(): AskUserQuestionConfig {
	return loadJsonConfig<AskUserQuestionConfig>(configCandidates("rpiv-ask-user-question"));
}
