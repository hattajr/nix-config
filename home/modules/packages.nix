{ lib, pkgs, ... }:

{
  # Global user tools formerly installed through mise. Nix is the sole owner of
  # these tools in the new configuration; project-specific versions can later
  # use per-project flakes or dev shells.
  home.packages = with pkgs; [
    atuin
    bat
    btop
    bun
    cargo
    chromium
    cloudflared
    claude-code
    deno
    dprint
    eza
    fd
    gh
    google-chrome
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
    rclone
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
