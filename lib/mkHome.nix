{ inputs, system, username, homeDirectory, extraModules ? [] }:

let
  pkgs = import inputs.nixpkgs {
    inherit system;
  };
in
inputs.home-manager.lib.homeManagerConfiguration {
  inherit pkgs;

  modules = [
    ../home/base.nix
    ../home/default.nix
    ../profiles/docker.nix
    inputs.sops-nix.homeManagerModules.sops
    {
      home.username = username;
      home.homeDirectory = homeDirectory;
    }
  ] ++ extraModules;
}
