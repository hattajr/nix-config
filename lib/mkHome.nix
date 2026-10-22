# Builds one Home Manager configuration from an explicitly supplied identity.
inputs:

# jobs names the background jobs this machine runs. It is per-machine state that
# bro reads and passes explicitly, like the identity, so it defaults to none.
{ system, username, homeDirectory, jobs ? [ ], extraModules ? [ ] }:

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
assert require (builtins.isList jobs) "jobs must be a list of background job names";

inputs.home-manager.lib.homeManagerConfiguration {
  inherit pkgs;

  modules = [
    ../home/base.nix
    ../home/default.nix
    {
      home.username = username;
      home.homeDirectory = homeDirectory;
      nixConfig.backgroundJobs = jobs;
    }
  ] ++ extraModules;
}
