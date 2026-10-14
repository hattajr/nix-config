{ config, lib, pkgs, ... }:

let
  statusLineScript = ".claude/statusline-command.sh";
  statusLine = {
    type = "command";
    command = "bash ${config.home.homeDirectory}/${statusLineScript}";
  };
  permissions = ../../config/claude/permissions.json;
in
{
  home.file.${statusLineScript} = {
    source = ../../config/claude/statusline-command.sh;
    executable = true;
    force = true;
  };

  # Claude Code rewrites settings.json itself (theme, model, plugins), so a
  # read-only store link would break it. Merge only the managed keys instead.
  # Allow rules are unioned so rules granted interactively survive a rebuild;
  # settings.json is the only user-level file Claude reads permissions from.
  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    settings="$HOME/.claude/settings.json"
    temporary="$settings.tmp.$$"
    mkdir -p "$(dirname "$settings")"
    [ -f "$settings" ] || printf '{}\n' > "$settings"

    if ${pkgs.jq}/bin/jq \
      --argjson statusLine ${lib.escapeShellArg (builtins.toJSON statusLine)} \
      --slurpfile managed ${permissions} \
      '.statusLine = $statusLine
        | .permissions.allow = ((.permissions.allow // []) + $managed[0].allow | unique)' \
      "$settings" > "$temporary"; then
      chmod 0600 "$temporary"
      mv -f "$temporary" "$settings"
    else
      rm -f "$temporary"
      printf 'claudeSettings: %s is not valid JSON; settings left unchanged\n' "$settings" >&2
    fi
  '';
}
