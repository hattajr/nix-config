{ lib, ... }:

let
  relativeFiles = root: prefix:
    map
      (source: "${prefix}/${lib.removePrefix "${toString root}/" (toString source)}")
      (lib.filesystem.listFilesRecursive root);

  nvimRoot = ../../config/nvim;
  piRoot = ../../config/pi/agent;
  piSettings = ../../config/pi/agent/settings.json;
  piTargets = map
    (source: ".pi/agent/${lib.removePrefix "${toString piRoot}/" (toString source)}")
    (builtins.filter (source: toString source != toString piSettings)
      (lib.filesystem.listFilesRecursive piRoot));

  forcedTargets = [
    ".inputrc"
    ".ssh/config"
    ".zprofile"
    ".zshenv"
    ".zshrc"
    ".config/bottom/bottom.toml"
    ".config/git/ignore"
    ".config/tmux/keys.sh"
    ".config/tmux/tmux.conf"
    ".local/bin/bro"
    ".local/bin/devtunnel"
    ".local/bin/nix-config-setup"
    ".local/bin/pi"
    ".local/bin/pi-models-sync"
    ".local/bin/proton-pass-pi-env"
    ".local/bin/proton-pass-session"
    ".local/bin/vi"
    ".local/bin/vim"
    ".pi/.claude/settings.local.json"
    ".pi/.gitignore"
    ".pi/.nvmrc"
    ".pi/README.md"
    ".claude/settings.local.json"
    ".config/proton-pass/README.md"
    ".config/proton-pass/pi.env.example"
    ".config/proton-pass/references.md"
  ] ++ relativeFiles nvimRoot ".config/nvim" ++ piTargets;

  # Home Manager's force flag skips collision checks, but its linker cannot
  # replace a directory occupying a file target. Managed symlinks are safe to
  # unlink; regular files and directories are quarantined so activation never
  # destroys a colliding user path.
  backupForcedTargets = lib.concatMapStringsSep "\n"
    (target: ''backupManagedTarget ${lib.escapeShellArg target}'')
    forcedTargets;
in
{
  # Generated program files need the same destructive leaf ownership as static
  # files that declare force at their source definition.
  home.file.".inputrc".force = true;
  home.file.".ssh/config".force = true;
  home.file."./.zprofile" = { target = ".zprofile"; force = true; };
  home.file."./.zshenv" = { target = ".zshenv"; force = true; };
  home.file."./.zshrc" = { target = ".zshrc"; force = true; };

  xdg.configFile."bottom/bottom.toml".force = true;
  xdg.configFile."git/ignore".force = true;
  xdg.configFile."tmux/keys.sh".force = true;
  xdg.configFile."tmux/tmux.conf".force = true;

  home.activation.overwriteManagedLeaves = lib.hm.dag.entryBetween
    [ "linkGeneration" ]
    [ "checkLinkTargets" ]
    ''
      takeoverBackupRoot=""

      backupManagedTarget() {
        local relative=$1 target backup stateHome takeoverRoot
        target="$HOME/$relative"
        if [ -L "$target" ]; then
          rm -f -- "$target"
          return
        fi
        [ -e "$target" ] || return 0

        if [ -z "$takeoverBackupRoot" ]; then
          stateHome="''${XDG_STATE_HOME:-$HOME/.local/state}"
          takeoverRoot="$stateHome/home-manager/takeover"
          mkdir -p "$takeoverRoot"
          takeoverBackupRoot=$(mktemp -d "$takeoverRoot/activation.XXXXXX")
          printf 'Backing up colliding managed paths to %s\n' "$takeoverBackupRoot"
        fi

        backup="$takeoverBackupRoot/$relative"
        mkdir -p "$(dirname "$backup")"
        mv -- "$target" "$backup"
      }

      ${backupForcedTargets}
    '';

  # programs.git owns the XDG config. Retire the legacy global path only after
  # collision validation and successful managed-link creation, preserving an
  # existing regular file or directory in the same activation quarantine.
  home.activation.removeLegacyGitConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    backupManagedTarget .gitconfig
  '';
}
