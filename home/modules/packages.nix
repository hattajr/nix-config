{ lib, pkgs, ... }:

{
  # Global user tools formerly installed through mise. Nix is the sole owner of
  # these tools in the new configuration; project-specific versions can later
  # use per-project flakes or dev shells.
  home.packages = with pkgs; [
    age
    bat
    bottom
    bun
    cargo
    deno
    dprint
    eza
    fd
    fzf
    gh
    go
    jq
    lazygit
    lazydocker
    nodejs
    ripgrep
    rustc
    sops
    uv
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    xclip
  ];
}
