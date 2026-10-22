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

        # No committed configuration enables a background job, so this is the
        # only output that builds the Board sync units. Building the activation
        # alone would accept a misspelt unit key, which systemd merely logs and
        # ignores, so the check fails on those log lines too.
        x86_64-linux.board-sync =
          let
            home = mkHome {
              system = "x86_64-linux";
              username = "hattajr";
              homeDirectory = "/home/hattajr";
              jobs = [ "board-sync" ];
            };
            unit = type: home.config.xdg.configFile."systemd/user/gh-board-sync.${type}".source;
          in
          home.pkgs.runCommand "board-sync-check"
            { nativeBuildInputs = [ home.pkgs.systemd ]; }
            ''
              mkdir units
              cp ${unit "service"} units/gh-board-sync.service
              cp ${unit "timer"} units/gh-board-sync.timer
              # A user manager runs without /run, which the build sandbox lacks,
              # and NixOS ships the stock user targets only as examples.
              export HOME=$PWD XDG_RUNTIME_DIR=$PWD/runtime
              export SYSTEMD_UNIT_PATH=$PWD/units:${home.pkgs.systemd}/example/systemd/user
              mkdir -m 700 runtime
              systemd-analyze verify --user --man=no units/gh-board-sync.service units/gh-board-sync.timer 2>&1 | tee verify.log
              if grep -E 'gh-board-sync\.(service|timer):[0-9]+: ' verify.log; then
                echo 'board-sync check: unit has unknown or ignored settings' >&2
                exit 1
              fi
              ln -s ${home.activationPackage} $out
            '';

        aarch64-linux.activation =
          self.homeConfigurations."aarch64-linux".activationPackage;

        aarch64-darwin.activation =
          self.homeConfigurations."aarch64-darwin".activationPackage;
      };
    };
}
