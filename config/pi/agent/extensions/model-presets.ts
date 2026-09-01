import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { getAgentDir } from "@earendil-works/pi-coding-agent";

type ThinkingLevel =
  | "off"
  | "minimal"
  | "low"
  | "medium"
  | "high"
  | "xhigh"
  | "max";

type Preset = {
  provider: string;
  model: string;
  thinkingLevel: ThinkingLevel;
};

type Presets = Record<string, Preset>;

const PRESETS_PATH = join(getAgentDir(), "presets.json");
const PRESET_ORDER = ["thinking", "fast"];
const DEFAULT_PRESET = "fast";

function loadPresets(): Presets {
  if (!existsSync(PRESETS_PATH)) return {};

  try {
    return JSON.parse(readFileSync(PRESETS_PATH, "utf8")) as Presets;
  } catch (error) {
    console.error(`Failed to load ${PRESETS_PATH}: ${error}`);
    return {};
  }
}

type ModelSelection = {
  provider: string;
  id: string;
};

function matchingPreset(
  model: ModelSelection | undefined,
  thinkingLevel: ThinkingLevel,
  presets: Presets,
): string | undefined {
  return Object.entries(presets).find(
    ([, preset]) =>
      model?.provider === preset.provider &&
      model.id === preset.model &&
      thinkingLevel === preset.thinkingLevel,
  )?.[0];
}

export default function modelPresets(pi: ExtensionAPI) {
  let presets: Presets = {};
  let activePreset: string | undefined;
  let selectedModel: ModelSelection | undefined;
  let selectedThinkingLevel: ThinkingLevel = "off";
  let applyingPreset = false;

  function updateStatus(ctx: ExtensionContext): void {
    activePreset = matchingPreset(
      selectedModel,
      selectedThinkingLevel,
      presets,
    );
    ctx.ui.setStatus("model-preset", activePreset?.toUpperCase());
  }

  async function applyPreset(
    name: string,
    ctx: ExtensionContext,
  ): Promise<void> {
    const preset = presets[name];
    if (!preset) {
      ctx.ui.notify(
        `Unknown preset "${name}". Available: ${Object.keys(presets).join(", ") || "none"}`,
        "error",
      );
      return;
    }

    const model = ctx.modelRegistry.find(preset.provider, preset.model);
    if (!model) {
      ctx.ui.notify(
        `Preset "${name}": model ${preset.provider}/${preset.model} is unavailable`,
        "error",
      );
      return;
    }

    applyingPreset = true;
    try {
      if (!(await pi.setModel(model))) {
        ctx.ui.notify(
          `Preset "${name}": no credentials for ${preset.provider}/${preset.model}`,
          "error",
        );
        return;
      }

      pi.setThinkingLevel(preset.thinkingLevel);
      selectedModel = model;
      selectedThinkingLevel = preset.thinkingLevel;
      activePreset = name;
      ctx.ui.setStatus("model-preset", activePreset.toUpperCase());
    } finally {
      applyingPreset = false;
    }

    ctx.ui.notify(
      `Preset: ${name} (${preset.model}, ${preset.thinkingLevel})`,
      "info",
    );
  }

  async function togglePreset(ctx: ExtensionContext): Promise<void> {
    const available = PRESET_ORDER.filter((name) => presets[name]);
    if (available.length === 0) {
      ctx.ui.notify(`No presets found in ${PRESETS_PATH}`, "error");
      return;
    }

    const current = activePreset;
    const next =
      available[
        (Math.max(available.indexOf(current ?? ""), -1) + 1) % available.length
      ];
    await applyPreset(next, ctx);
  }

  pi.registerShortcut("ctrl+shift+u", {
    description: "Toggle thinking/fast model preset",
    handler: togglePreset,
  });

  pi.registerCommand("preset", {
    description: "Switch model preset: /preset [thinking|fast]",
    handler: async (args, ctx) => {
      const name = args.trim();
      if (name) {
        await applyPreset(name, ctx);
      } else {
        await togglePreset(ctx);
      }
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    presets = loadPresets();
    selectedModel = ctx.model;
    selectedThinkingLevel = pi.getThinkingLevel();

    if (presets[DEFAULT_PRESET]) {
      await applyPreset(DEFAULT_PRESET, ctx);
    } else {
      updateStatus(ctx);
    }
  });

  pi.on("model_select", (event, ctx) => {
    selectedModel = event.model;
    if (!applyingPreset) updateStatus(ctx);
  });
  pi.on("thinking_level_select", (event, ctx) => {
    selectedThinkingLevel = event.level;
    if (!applyingPreset) updateStatus(ctx);
  });
}
