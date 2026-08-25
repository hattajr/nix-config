{ ... }:

{
  imports = [
    ./modules/core-files.nix
    ./modules/git.nix
    ./modules/nvim.nix
    ./modules/packages.nix
    ./modules/pi.nix
    ./modules/shell.nix
    ./modules/tmux.nix
  ];
}
