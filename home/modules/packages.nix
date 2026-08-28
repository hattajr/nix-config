{ lib, pkgs, ... }:

{
  # Global user tools formerly installed through mise. Nix is the sole owner of
  # these tools in the new configuration; project-specific versions can later
  # use per-project flakes or dev shells.
  home.packages = with pkgs; [
    bat
    bun
    cargo
    cloudflared
    deno
    dprint
    eza
    fd
    gh
    gnumake
    go
    jq
    lazygit
    lazydocker
    lumen
    nodejs
    pkg-config
    procps
    proton-pass-cli
    python3
    ripgrep
    rustc
    uv
    wrangler
  ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    gcc
    keyutils
    util-linuxMinimal
    xclip
  ];
}
