{ inputs, system, username, homeDirectory, extraModules ? [] }:

let
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfreePredicate = pkg:
      builtins.elem (inputs.nixpkgs.lib.getName pkg) [
        "claude-code"
        "google-chrome"
      ];
  };
in
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
