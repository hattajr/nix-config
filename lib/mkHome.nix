# Builds one Home Manager configuration from an explicitly supplied identity.
inputs:

{ system, username, homeDirectory, extraModules ? [ ] }:

let
  lib = inputs.nixpkgs.lib;

  # An invalid identity otherwise surfaces as a module-system type error far
  # from the caller that actually supplied it.
  require = condition: message: if condition then true else throw "mkHome: ${message}";

  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [
        "claude-code"
        "google-chrome"
      ];
  };
in
assert require (username != "") "username must not be empty";
assert require (lib.hasPrefix "/" homeDirectory)
  ''homeDirectory must be an absolute path, got "${homeDirectory}"'';

inputs.home-manager.lib.homeManagerConfiguration {
  inherit pkgs;

  modules = [
    ../home/base.nix
    ../home/default.nix
    {
      home.username = username;
      home.homeDirectory = homeDirectory;
    }
  ] ++ extraModules;
}
