{
  description = "Nix Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = inputs:
    let
      platforms = import ./platforms;
      mkHome = platform: import ./lib/mkHome.nix ({ inherit inputs; } // platform);
    in
    {
      homeConfigurations = {
        incus-test = import ./lib/mkHome.nix {
          inherit inputs;
          system = "x86_64-linux";
          username = "test";
          homeDirectory = "/home/test";
        };
      } // builtins.mapAttrs (_: platform: mkHome platform) platforms;
    };
}
