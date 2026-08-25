{
  description = "Nix Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    let
      hosts = import ./hosts;
      mkHome = host: import ./lib/mkHome.nix ({ inherit inputs; } // host);
    in
    {
      homeConfigurations = {
        docker-test = import ./lib/mkHome.nix {
          inherit inputs;
          system = "x86_64-linux";
          username = "test";
          homeDirectory = "/home/test";
        };
      } // builtins.mapAttrs (_: host: mkHome host) hosts;
    };
}
