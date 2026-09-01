# nix-config

Personal Home Manager configuration for macOS (Apple Silicon) and Linux (x86-64, ARM64).

## Included

- Shell and terminal: zsh, tmux, Neovim, Git, SSH, fzf, atuin
- Development: Node.js, Bun, Deno, Python, uv, Go, Rust, Cargo, GCC, Make
- CLI tools: gh, ripgrep, fd, bat, btop, lazygit, lazydocker, rclone, Wrangler, Cloudflared
- Apps: Pi, Claude Code, Lumen, Proton Pass CLI; Linux also gets Chromium and Google Chrome

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/hattajr/nix-config/main/scripts/install.sh | sh
```

The installer detects the platform, reuses a working Nix installation when available, otherwise installs the official multi-user Nix daemon. It clones this repository to `~/src/nix-config`, fast-forwards a clean existing checkout to the latest `origin/main`, and prompts to apply the configuration. Local changes and diverged commits are never overwritten.

Home Manager is the sole owner of each configuration file it manages. Activation deliberately replaces conflicting files at those managed leaves, including files previously managed by Chezmoi, while preserving unrelated files in shared directories. The legacy `~/.gitconfig` is removed in favor of `~/.config/git/config`. No migration, backup, approval digest, or Chezmoi source checkout is used. Runtime state and secrets outside the managed paths remain writable.

### Manual macOS ownership

Browsers on macOS are intentionally installed and updated manually. Home Manager does not install Chrome or take ownership of browser profiles. Tailscale/Proton split DNS is also external host state: enable and maintain it through the macOS/Tailscale tools, not this repository. The managed `devtunnel` command defaults to the `mbp` SSH hostname and only uses ordinary SSH forwarding.

Home Manager uses the active user's `$USER` and `$HOME`, so it works for arbitrary local account names; automation may override them with `NIX_CONFIG_USERNAME` and `NIX_CONFIG_HOME`. Run `bro auth` after activation to configure optional accounts and API keys.

## `bro` commands

```text
bro health        Check shell and account setup health
bro apply         Build and activate this checkout
bro sync           Fast-forward from upstream, then apply
bro sync --push    Sync, apply, then push local commits
bro auth          Configure accounts and API keys
```

## Multipass validation

Install Multipass, then run the full integration suite in a disposable Ubuntu VM:

```sh
make multipass-validation
```

The suite launches Ubuntu 24.04, copies only tracked and non-ignored project files into the VM, and runs the public curl installer against that local fixture. It then validates the generated Home Manager activation, idempotence, managed tools, shell startup, Neovim, and credential-free bootstrap tests. The VM is deleted on exit.

Set `MULTIPASS_VALIDATION_IMAGE` to select another Ubuntu image.

### Interactive Multipass testing

To manually test the current working tree without pushing it, run:

```sh
make test-interactive
```

This launches (or reuses) a persistent Ubuntu 24.04 VM, mounts the working tree, converts its tracked and non-ignored files—including uncommitted changes—into a local Git fixture, installs the prerequisites, and opens a shell. Follow the displayed local-source installer command. After host edits, run `make test-interactive` again and rerun that installer command to refresh the fixture and activation. The VM remains available until you delete it:

```sh
multipass delete --purge nix-config-interactive-$USER
```

Set `MULTIPASS_INTERACTIVE_IMAGE` or `MULTIPASS_INTERACTIVE_INSTANCE` to override the image or VM name.
