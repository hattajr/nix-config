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
    ".pi/.claude/settings.local.json".source = ../../config/pi/.claude/settings.local.json;
    ".claude/settings.local.json".source = ../../config/claude/settings.local.json;
  };
}
