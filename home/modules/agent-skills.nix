{ lib, ... }:

let
  sharedRoot = ../../config/agents/skills;
  claudeRoot = ../../config/claude/skills;

  # Link static leaves, not whole skill roots: local skills and Claude's
  # synced/ directory must remain writable and outside Home Manager ownership.
  skillFiles = root: prefix:
    builtins.listToAttrs (map (source: {
      name = "${prefix}/${lib.removePrefix "${toString root}/" (toString source)}";
      value = { inherit source; force = true; };
    }) (if builtins.pathExists root then lib.filesystem.listFilesRecursive root else []));
in
{
  # Pi-only skills are already deployed with the rest of config/pi/agent.
  # The optional Claude-only directory can be created when its first skill is added.
  home.file = skillFiles sharedRoot ".pi/agent/skills"
    // skillFiles sharedRoot ".claude/skills"
    // skillFiles claudeRoot ".claude/skills";
}
