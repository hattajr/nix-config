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

The installer installs Nix when needed, detects the platform, clones this repository to `~/src/nix-config`, and prompts to apply the configuration. Run `bro auth` after activation to configure optional accounts and API keys.

## `bro` commands

```text
bro health        Check shell and account setup health
bro apply         Build and activate this checkout
bro sync           Fast-forward from upstream, then apply
bro sync --push    Sync, apply, then push local commits
bro auth          Configure accounts and API keys
```
