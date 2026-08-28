import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AutocompleteItem, AutocompleteProvider, AutocompleteSuggestions } from "@earendil-works/pi-tui";

type Exec = (command: string, args: string[], options: {
  cwd: string;
  signal: AbortSignal;
  timeout: number;
}) => Promise<{ stdout: string; code: number }>;

type AtPrefix = {
  prefix: string;
  rawPath: string;
  quoted: boolean;
};

const MAX_RESULTS = 50;
const FD_TIMEOUT_MS = 1_500;

function atPrefix(text: string): AtPrefix | null {
  const quoted = text.match(/(?:^|\s)(@")([^"\n]*)$/);
  if (quoted) {
    return { prefix: quoted[1] + quoted[2], rawPath: quoted[2], quoted: true };
  }

  const unquoted = text.match(/(?:^|\s)(@[^\s@]*)$/);
  if (!unquoted) return null;
  return { prefix: unquoted[1], rawPath: unquoted[1].slice(1), quoted: false };
}

function completionValue(path: string, quoted: boolean): string {
  return quoted || path.includes(" ") ? `@"${path}"` : `@${path}`;
}

function plansQuery(rawPath: string): string | null {
  const normalized = rawPath.replace(/^\.\//, "");
  if (!normalized || "PLANS".startsWith(normalized.toUpperCase())) return "";
  if (!normalized.toUpperCase().startsWith("PLANS/")) return normalized;
  return normalized.slice("PLANS/".length);
}

function isDirectoryPath(path: string): boolean {
  return path.endsWith("/");
}

function score(path: string, query: string): number {
  if (!query) return 1;
  const name = path.replace(/\/$/, "").split("/").pop()!.toLowerCase();
  const normalizedQuery = query.toLowerCase();
  const fullPath = path.toLowerCase();
  if (name === normalizedQuery) return 100;
  if (name.startsWith(normalizedQuery)) return 80;
  if (name.includes(normalizedQuery)) return 50;
  if (fullPath.includes(normalizedQuery)) return 30;
  return 0;
}

/** Wrap Pi's provider, exposing only ignored paths below the documented PLANS root. */
export function createPlansAutocompleteProvider(
  current: AutocompleteProvider,
  options: { cwd: string; exec: Exec },
): AutocompleteProvider {
  return {
    triggerCharacters: current.triggerCharacters,
    async getSuggestions(lines, cursorLine, cursorCol, suggestionOptions) {
      const builtin = await current.getSuggestions(lines, cursorLine, cursorCol, suggestionOptions);
      const prefix = atPrefix((lines[cursorLine] ?? "").slice(0, cursorCol));
      if (!prefix || suggestionOptions.signal.aborted) return builtin;

      const query = plansQuery(prefix.rawPath);
      if (query === null) return builtin;

      let stdout: string;
      try {
        const result = await options.exec("fd", [
          "--no-ignore",
          "--hidden",
          "--type", "f",
          "--type", "d",
          "--max-results", String(MAX_RESULTS),
          "--ignore-case",
          "--full-path",
          "--exclude", ".git",
          "--exclude", ".git/*",
          "--exclude", ".git/**",
          ...(query ? [query] : []),
          ".",
        ], {
          cwd: `${options.cwd}/PLANS`,
          signal: suggestionOptions.signal,
          timeout: FD_TIMEOUT_MS,
        });
        if (suggestionOptions.signal.aborted || result.code !== 0 && result.code !== 1) return builtin;
        stdout = result.stdout;
      } catch {
        return builtin;
      }

      const customPaths = stdout.split(/\r?\n/).filter(Boolean)
        .map((entry) => entry.replace(/^\.\//, ""))
        .filter((entry) => !entry.split("/").includes(".git"))
        .map((entry) => entry.startsWith("PLANS/") ? entry : `PLANS/${entry}`);
      // fd searches descendants, so add the root itself for @pla and @PLANS.
      if ("PLANS".startsWith(prefix.rawPath.toUpperCase())) customPaths.push("PLANS/");

      const items = customPaths
        .map((path) => isDirectoryPath(path) ? path : path)
        .map((path) => ({ path, score: score(path, prefix.rawPath.replace(/^PLANS\/?/i, "")) }))
        .filter((entry) => entry.score > 0 || entry.path === "PLANS/")
        .sort((a, b) => (isDirectoryPath(b.path) ? 1 : 0) - (isDirectoryPath(a.path) ? 1 : 0) || b.score - a.score || a.path.localeCompare(b.path))
        .slice(0, 20)
        .map(({ path }) => ({
          value: completionValue(path, prefix.quoted),
          label: path.split("/").filter(Boolean).at(-1)! + (isDirectoryPath(path) ? "/" : ""),
          description: path,
        }));

      const merged = [...(builtin?.items ?? []), ...items];
      const deduped = merged.filter((item, index) => merged.findIndex((candidate) => candidate.value === item.value) === index);
      if (deduped.length === 0) return builtin;
      return { items: deduped, prefix: builtin?.prefix ?? prefix.prefix } satisfies AutocompleteSuggestions;
    },
    applyCompletion: current.applyCompletion.bind(current),
    shouldTriggerFileCompletion: current.shouldTriggerFileCompletion?.bind(current),
  };
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    ctx.ui.addAutocompleteProvider((current) => createPlansAutocompleteProvider(current, {
      cwd: ctx.cwd,
      exec: (command, args, options) => pi.exec(command, args, options),
    }));
  });
}
