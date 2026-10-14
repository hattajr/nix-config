{ ... }:

let
  sharedInstructions = ../../config/agents/AGENTS.md;
in
{
  # One source of global rules so Pi and Claude Code never drift apart.
  home.file = {
    ".pi/agent/AGENTS.md" = { source = sharedInstructions; force = true; };
    ".claude/CLAUDE.md" = { source = sharedInstructions; force = true; };
  };
}
