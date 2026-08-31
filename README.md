# nix-config

Personal Home Manager configuration for macOS (Apple Silicon) and Linux (x86-64, ARM64).

## Included

- Shell and terminal: zsh, tmux, Neovim, Git, SSH, fzf, atuin
- Development: Node.js, Bun, Deno, Python, uv, Go, Rust, Cargo, GCC, Make
- CLI tools: gh, ripgrep, fd, bat, btop, lazygit, lazydocker, rclone, Wrangler, Cloudflared
- Apps: Pi, Claude Code, Lumen, Proton Pass CLI; Linux also gets Chromium and Google Chrome

## Install

```sh
curl -fsSLO https://raw.githubusercontent.com/hattajr/nix-config/main/scripts/install.sh
sh install.sh
```

The installer detects the platform, first reuses a working Nix installation (even when its profile is not loaded), otherwise installs multi-user Nix through the official daemon installer. The initial installation requires `sudo`; the installer manages the root-owned `/nix` store. It then clones this repository to `~/src/nix-config` and prompts to apply the configuration.

Existing ChezMoi sources are detected and left unchanged. Do not let ChezMoi and Home Manager manage the same paths; review and migrate colliding files deliberately before applying Home Manager. Home Manager uses the active user's `$USER` and `$HOME`, so it works for arbitrary local account names; automation may override them with `NIX_CONFIG_USERNAME` and `NIX_CONFIG_HOME`. Run `bro auth` after activation to configure optional accounts and API keys.

## `bro` commands

```text
bro health        Check shell and account setup health
bro apply         Build and activate this checkout
bro sync           Fast-forward from upstream, then apply
bro sync --push    Sync, apply, then push local commits
bro auth          Configure accounts and API keys
```
