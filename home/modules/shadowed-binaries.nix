{ config, lib, ... }:

let
  searchDirs = import ../../lib/path-dirs.nix;

  # Tools that update themselves into the user profile are expected to
  # outrank the Nix copy; reporting them every activation would be noise.
  allowedShadows = [ "claude" ];

  searchPath = lib.concatStringsSep ":" searchDirs;
  allowList = lib.concatStringsSep ":" allowedShadows;

  # Installed outside PATH on purpose. The bro menu and the activation warning
  # below are the only ways to reach it, so there is no command to memorise.
  scanner = ".local/share/nix-config/shadow-scan";
in
{
  home.file.${scanner} = {
    source = ../../bin/shadow-scan;
    executable = true;
    force = true;
  };

  home.sessionVariables = {
    NIX_CONFIG_SHADOW_DIRS = searchPath;
    NIX_CONFIG_SHADOW_ALLOW = allowList;
  };

  # Activation only reports. Quarantining stays an explicit user action, a
  # prompt here would hang every non-interactive switch, and a nonzero exit
  # would fail a switch over binaries the user may have installed on purpose.
  home.activation.reportShadowedBinaries =
    lib.hm.dag.entryAfter [ "linkGeneration" "installPackages" ] ''
      NIX_CONFIG_SHADOW_DIRS="${searchPath}" \
      NIX_CONFIG_SHADOW_ALLOW="${allowList}" \
      NIX_CONFIG_PROFILE_DIR="${config.home.profileDirectory}" \
        "$HOME/${scanner}" --warn || true
    '';
}
