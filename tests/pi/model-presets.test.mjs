import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { after, test } from "node:test";

// Pi's host API is process-bound and normally starts a complete session. Stub
// only that boundary; load the unchanged extension and real preset file.
const work = mkdtempSync(join(tmpdir(), "pi-model-presets-"));
after(() => rmSync(work, { recursive: true, force: true }));
const agentDir = join(work, "agent");
const hostDir = join(work, "node_modules/@earendil-works/pi-coding-agent");
mkdirSync(agentDir);
mkdirSync(hostDir, { recursive: true });
writeFileSync(join(work, "package.json"), '{"type":"module"}');
writeFileSync(join(hostDir, "package.json"), '{"type":"module","exports":"./index.js"}');
writeFileSync(join(hostDir, "index.js"), `export const getAgentDir = () => ${JSON.stringify(agentDir)};`);
const presets = JSON.parse(readFileSync(new URL("../../config/pi/agent/presets.json", import.meta.url), "utf8"));
writeFileSync(join(agentDir, "presets.json"), JSON.stringify(presets));
const extensionPath = join(work, "model-presets.ts");
writeFileSync(extensionPath, readFileSync(new URL("../../config/pi/agent/extensions/model-presets.ts", import.meta.url)));
const { default: modelPresets } = await import(pathToFileURL(extensionPath).href);

function session({ available = true, credentials = true } = {}) {
  const events = new Map();
  const commands = new Map();
  const shortcuts = new Map();
  const models = Object.values(presets).map(({ provider, model }) => ({ provider, id: model }));
  const state = { model: models[0], thinking: "medium", notifications: [] };
  const pi = {
    on: (name, handler) => events.set(name, handler),
    registerCommand: (name, command) => commands.set(name, command),
    registerShortcut: (name, shortcut) => shortcuts.set(name, shortcut),
    getThinkingLevel: () => state.thinking,
    setModel: async (model) => {
      if (!credentials) return false;
      state.model = model;
      return true;
    },
    setThinkingLevel: (level) => { state.thinking = level; },
  };
  const ctx = {
    model: state.model,
    modelRegistry: { find: (provider, id) => available ? models.find(m => m.provider === provider && m.id === id) : undefined },
    ui: {
      setStatus: (_key, status) => { state.status = status; },
      notify: (message, level) => state.notifications.push({ message, level }),
    },
  };
  modelPresets(pi);
  return { events, commands, shortcuts, state, ctx };
}

function assertPreset(state, name) {
  assert.deepEqual(state.model, { provider: presets[name].provider, id: presets[name].model });
  assert.equal(state.thinking, presets[name].thinkingLevel);
  assert.equal(state.status, name.toUpperCase());
}

test("parent starts on DeepSeek fast and switches/cycles shared presets", async () => {
  const { events, commands, shortcuts, state, ctx } = session();
  await events.get("session_start")({}, ctx);
  assertPreset(state, "fast");
  assert.equal(state.model.provider, "deepseek");
  assert.equal(state.model.id, "deepseek-flash");
  for (const name of ["medium", "thinking", "fast"]) {
    await commands.get("preset").handler(name, ctx);
    assertPreset(state, name);
  }
  await commands.get("preset").handler("", ctx);
  assertPreset(state, "thinking");
  await shortcuts.get("ctrl+shift+u").handler(ctx);
  assertPreset(state, "medium");
});

test("background child preserves its launch model and effort", () => {
  const previous = process.env.PI_SUBAGENT_CHILD;
  process.env.PI_SUBAGENT_CHILD = "1";
  try {
    const { events, commands, shortcuts, state } = session();
    assert.deepEqual(state.model, { provider: presets.thinking.provider, id: presets.thinking.model });
    assert.equal(state.thinking, "medium");
    assert.equal(events.size, 0);
    assert.equal(commands.size, 0);
    assert.equal(shortcuts.size, 0);
    assert.deepEqual(state.notifications, []);
  } finally {
    if (previous === undefined) delete process.env.PI_SUBAGENT_CHILD;
    else process.env.PI_SUBAGENT_CHILD = previous;
  }
});

for (const options of [{ available: false }, { credentials: false }]) {
  test(`unavailable preset fails visibly without changing model or effort: ${JSON.stringify(options)}`, async () => {
    const { events, state, ctx } = session(options);
    const before = { ...state.model };
    await events.get("session_start")({}, ctx);
    assert.deepEqual(state.model, before);
    assert.equal(state.thinking, "medium");
    assert.equal(state.notifications.at(-1).level, "error");
  });
}

test("unknown preset leaves the selected model unchanged", async () => {
  const { events, commands, state, ctx } = session();
  await events.get("session_start")({}, ctx);
  await commands.get("preset").handler("typo", ctx);
  assertPreset(state, "fast");
  assert.match(state.notifications.at(-1).message, /Unknown preset/);
});
