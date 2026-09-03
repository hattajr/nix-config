{
  description = "Nix Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = { self, ... }@inputs:
    let
      mkHome = import ./lib/mkHome.nix inputs;
    in
    {
      # The installer activates accounts that are not committed here. Exposing
      # the builder rather than reading $USER during evaluation keeps every
      # flake output pure, so `nix flake check` and evaluation caching work.
      lib = { inherit mkHome; };

      homeConfigurations = {
        "hattajr@latte" = mkHome {
          system = "x86_64-linux";
          username = "hattajr";
          homeDirectory = "/home/hattajr";
        };

        "hattajr@mbp" = mkHome {
          system = "aarch64-darwin";
          username = "hattajr";
          homeDirectory = "/Users/hattajr";
        };

        multipass-test = mkHome {
          system = "x86_64-linux";
          username = "test";
          homeDirectory = "/home/test";
        };
      };

      checks = {
        x86_64-linux.activation =
          self.homeConfigurations."hattajr@latte".activationPackage;

        aarch64-darwin.activation =
          self.homeConfigurations."hattajr@mbp".activationPackage;
      };
    };
}
