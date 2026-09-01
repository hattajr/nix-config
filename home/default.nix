{ ... }:

{
  imports = [
    ./modules/core-files.nix
    ./modules/git.nix
    ./modules/nvim.nix
    ./modules/packages.nix
    ./modules/pi.nix
    ./modules/proton-pass.nix
    ./modules/shell.nix
    ./modules/ssh.nix
    ./modules/tmux.nix
    ./modules/takeover.nix
  ];
}
