{ config, lib, pkgs, ... }:

let
  statusLineScript = ".claude/statusline-command.sh";
  statusLine = {
    type = "command";
    command = "bash ${config.home.homeDirectory}/${statusLineScript}";
  };
in
{
  home.file.${statusLineScript} = {
    source = ../../config/claude/statusline-command.sh;
    executable = true;
    force = true;
  };

  # Claude Code rewrites settings.json itself (theme, model, plugins), so a
  # read-only store link would break it. Merge only the managed key instead.
  home.activation.claudeStatusLine = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    settings="$HOME/.claude/settings.json"
    temporary="$settings.tmp.$$"
    mkdir -p "$(dirname "$settings")"
    [ -f "$settings" ] || printf '{}\n' > "$settings"

    if ${pkgs.jq}/bin/jq --argjson statusLine ${lib.escapeShellArg (builtins.toJSON statusLine)} \
      '.statusLine = $statusLine' "$settings" > "$temporary"; then
      chmod 0600 "$temporary"
      mv -f "$temporary" "$settings"
    else
      rm -f "$temporary"
      printf 'claudeStatusLine: %s is not valid JSON; statusLine left unchanged\n' "$settings" >&2
    fi
  '';
}
