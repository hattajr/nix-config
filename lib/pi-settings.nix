# Resolve shared model presets into Pi's native settings. Builtin personas stay
# upstream-owned; only their model and thinking fields are overridden.
{ settings, presets, agentPresets }:
let
  presetFor = name:
    if builtins.hasAttr name presets then presets.${name}
    else throw "Unknown Pi model preset: ${name}";
  defaultPreset = presetFor "fast";
  subagents = settings.subagents or { };
  overrides = subagents.agentOverrides or { };
  resolvedOverrides = builtins.mapAttrs (agent: name:
    let preset = presetFor name;
    in (overrides.${agent} or { }) // {
      model = "${preset.provider}/${preset.model}";
      thinking = preset.thinkingLevel;
    }
  ) agentPresets;
in
settings // {
  defaultProvider = defaultPreset.provider;
  defaultModel = defaultPreset.model;
  defaultThinkingLevel = defaultPreset.thinkingLevel;
  subagents = subagents // {
    agentOverrides = overrides // resolvedOverrides;
  };
}
