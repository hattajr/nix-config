#!/usr/bin/env bash
# Resolve real configuration with Nix; no activation, credentials, or network.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$repo_root/config/pi/agent/"{settings,presets,subagent-presets}.json "$work/"

resolve() {
  nix-instantiate --eval --strict --json --argstr root "$repo_root" --argstr fixture "$work" --expr '
    { root, fixture }:
    import (builtins.toPath "${root}/lib/pi-settings.nix") {
      settings = builtins.fromJSON (builtins.readFile "${fixture}/settings.json");
      presets = builtins.fromJSON (builtins.readFile "${fixture}/presets.json");
      agentPresets = builtins.fromJSON (builtins.readFile "${fixture}/subagent-presets.json");
    }
  '
}
resolve > "$work/resolved.json"
jq -e '
  .defaultProvider == "deepseek" and .defaultModel == "deepseek-flash" and
  .defaultThinkingLevel == "high" and
  .subagents.agentOverrides == {
    "scout": {"model":"openai-codex/gpt-6.1-sol", "thinking":"high"},
    "researcher": {"model":"openai-codex/gpt-6.1-sol", "thinking":"high"},
    "oracle": {"model":"openai-codex/gpt-6-astra", "thinking":"high"},
    "worker": {"model":"deepseek/deepseek-flash", "thinking":"high"},
    "reviewer": {"model":"openai-codex/gpt-6-astra", "thinking":"high"},
    "delegate": {"model":"deepseek/deepseek-flash", "thinking":"high"},
    "evidence-auditor": {"model":"openai-codex/gpt-6-astra", "thinking":"high"}
  }
' "$work/resolved.json" >/dev/null
# The base settings (package declarations, theme, model scope, etc.) survive.
jq --slurpfile base "$work/settings.json" -e '
  del(.defaultProvider, .defaultModel, .defaultThinkingLevel, .subagents) == $base[0]
' "$work/resolved.json" >/dev/null

# A single preset edit updates every assigned role and the parent default,
# including effort, without changing other roles.
jq '.fast = {provider:"test-provider", model:"replacement", thinkingLevel:"low"}' \
  "$work/presets.json" > "$work/new.json"
mv "$work/new.json" "$work/presets.json"
resolve > "$work/changed.json"
jq --slurpfile old "$work/resolved.json" -e '
  .defaultProvider == "test-provider" and .defaultModel == "replacement" and
  .defaultThinkingLevel == "low" and
  .subagents.agentOverrides.worker == {model:"test-provider/replacement", thinking:"low"} and
  .subagents.agentOverrides.delegate == .subagents.agentOverrides.worker and
  (.subagents.agentOverrides | del(.worker, .delegate)) ==
    ($old[0].subagents.agentOverrides | del(.worker, .delegate))
' "$work/changed.json" >/dev/null

# Role reassignment resolves the new preset rather than retaining the old model.
jq '.worker = "thinking"' "$work/subagent-presets.json" > "$work/new.json"
mv "$work/new.json" "$work/subagent-presets.json"
resolve | jq -e '.subagents.agentOverrides.worker == .subagents.agentOverrides.oracle' >/dev/null

# Preserve non-model overrides and unassigned custom agents.
jq '.subagents = {
  defaultThinking:"medium",
  agentOverrides:{
    worker:{model:"stale/model", thinking:"off", inheritSkills:true},
    custom:{model:"custom/model", thinking:"low"}
  }
}' "$work/settings.json" > "$work/new.json"
mv "$work/new.json" "$work/settings.json"
resolve | jq -e '
  .subagents.defaultThinking == "medium" and
  .subagents.agentOverrides.worker == {
    model:"openai-codex/gpt-6-astra", thinking:"high", inheritSkills:true
  } and
  .subagents.agentOverrides.custom == {model:"custom/model", thinking:"low"}
' >/dev/null

# Typos must fail at evaluation, never silently inherit the parent's model.
jq '.worker = "typo"' "$work/subagent-presets.json" > "$work/new.json"
mv "$work/new.json" "$work/subagent-presets.json"
if resolve > "$work/output" 2> "$work/error"; then
  printf 'Pi preset test: unknown preset was accepted\n' >&2
  exit 1
fi
grep -q 'Unknown Pi model preset: typo' "$work/error"
printf 'Pi preset settings tests: PASSED (routing, effort, updates, preservation, invalid names)\n'
