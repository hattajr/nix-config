{ ... }:

{
  # Static Pi configuration only. Runtime state, credentials, caches, and
  # installed extensions remain outside Home Manager.
  home.file = {
    ".pi/README.md".source = ../../config/pi/README.md;
    ".pi/.gitignore".source = ../../config/pi/.gitignore;
    ".pi/.nvmrc".source = ../../config/pi/.nvmrc;
    ".pi/agent/scoped-models.json".source = ../../config/pi/agent/scoped-models.json;
    ".pi/agent/keybindings.json".source = ../../config/pi/agent/keybindings.json;
    ".pi/agent/settings.json".source = ../../config/pi/agent/settings.json;
    ".pi/agent/agents".source = ../../config/pi/agent/agents;
    ".pi/agent/chains".source = ../../config/pi/agent/chains;
    ".pi/agent/extensions".source = ../../config/pi/agent/extensions;
    ".pi/agent/intercepted-commands".source = ../../config/pi/agent/intercepted-commands;
    ".pi/agent/messenger".source = ../../config/pi/agent/messenger;
    ".pi/agent/scripts".source = ../../config/pi/agent/scripts;
    ".pi/agent/skills".source = ../../config/pi/agent/skills;
    ".pi/agent/themes".source = ../../config/pi/agent/themes;
    ".pi/.claude/settings.local.json".source = ../../config/pi/.claude/settings.local.json;
    ".claude/settings.local.json".source = ../../config/claude/settings.local.json;
  };
}
