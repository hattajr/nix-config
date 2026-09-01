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

The installer detects the platform, first reuses a working Nix installation (even when its profile is not loaded), otherwise installs the official **single-user** Nix profile. It never changes `/nix` ownership. If a root-owned empty `/nix` blocks installation, it prints the narrow administrator remediation and the exact command to rerun. It then clones this repository to `~/src/nix-config` and prompts to apply the configuration.

### Existing ChezMoi installation

`~/.local/share/chezmoi` is verified at its reviewed commit before takeover. The installer makes a digest-approved, private backup of only colliding managed leaves before Home Manager activation, then adds a deterministic `.chezmoiignore` guard so later ChezMoi applies cannot overwrite those paths. It never runs ChezMoi, deletes its source, decrypts its old secret, or moves whole `.config`, `.pi`, or Neovim directories. An interrupted run is resumed by rerunning the exact installer command.

```text
bro migration status    Inspect the current transaction
bro migration resume    Resume an approved interrupted backup
bro migration rollback  Restore backups only while recorded destinations remain absent
bro migration legacy    Report retired Mosh artifacts; it never removes them
```

Pi authentication, Pi runtime state, and Proton Pass runtime files remain writable outside Home Manager. Proton Pass is the selected secret owner; the legacy ChezMoi encrypted secret is not imported or inspected.

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
bro migration …   Inspect/resume/roll back a ChezMoi takeover transaction
```

## Incus validation

Install and initialize Incus separately, then run the isolated validation suite:

```sh
make incus-validation
```

The first run launches `images:nixos/24.11`, stops it, and saves the
`nix-config-validation-base/prepared` snapshot. Every validation run is a
throwaway clone of that snapshot with this checkout mounted read-only at
`/source`; the clone is deleted on exit. This pins the test environment while
keeping failures reproducible.

To deliberately refresh the pinned base after changing the image selection,
delete the base and run validation again:

```sh
incus delete --force nix-config-validation-base
make incus-validation
```

Set `INCUS_VALIDATION_IMAGE`, `INCUS_VALIDATION_BASE`, or
`INCUS_VALIDATION_SNAPSHOT` to use different image or snapshot names.
`make test-interactive` opens a disposable shell from the same base snapshot.

`make incus-alice-validation` uses a separate Ubuntu snapshot with a real
`alice` account and a real official single-user (`--no-daemon`) Nix install. It
runs `install.sh` with Nix deliberately absent from `PATH`, verifying that the
user profile hook is reused rather than attempting the daemon installer. The
scenario copies only Git-tracked/non-ignored source files into the instance;
it never mounts or reads `.env`.
