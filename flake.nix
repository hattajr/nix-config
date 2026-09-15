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

      # Committed configurations are keyed by system rather than by
      # user@host, so activation names a machine architecture and never has
      # to be renamed when a host is renamed or replaced.
      owner = system: homeDirectory: mkHome {
        inherit system homeDirectory;
        username = "hattajr";
      };
    in
    {
      # The installer activates accounts that are not committed here. Exposing
      # the builder rather than reading $USER during evaluation keeps every
      # flake output pure, so `nix flake check` and evaluation caching work.
      lib = { inherit mkHome; };

      homeConfigurations = {
        "x86_64-linux" = owner "x86_64-linux" "/home/hattajr";
        "aarch64-linux" = owner "aarch64-linux" "/home/hattajr";
        "aarch64-darwin" = owner "aarch64-darwin" "/Users/hattajr";

        multipass-test = mkHome {
          system = "x86_64-linux";
          username = "test";
          homeDirectory = "/home/test";
        };
      };

      checks = {
        x86_64-linux.activation =
          self.homeConfigurations."x86_64-linux".activationPackage;

        aarch64-linux.activation =
          self.homeConfigurations."aarch64-linux".activationPackage;

        aarch64-darwin.activation =
          self.homeConfigurations."aarch64-darwin".activationPackage;
      };
    };
}
