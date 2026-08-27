{ lib, pkgs, ... }:

{
  # Global user tools formerly installed through mise. Nix is the sole owner of
  # these tools in the new configuration; project-specific versions can later
  # use per-project flakes or dev shells.
  home.packages = with pkgs; [
    bat
    bottom
    bun
    cargo
    cloudflared
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
    lumen
    nodejs
    proton-pass-cli
    ripgrep
    rustc
    uv
  ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    gcc
    keyutils
    xclip
  ];
}
