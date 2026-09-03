# nix-config

Personal Home Manager configuration for macOS (Apple Silicon) and Linux (x86-64, ARM64).

## Included

- Shell and terminal: zsh, tmux, Neovim, Git, SSH, fzf, atuin
- Development: Node.js, Bun, Deno, Python, uv, Go, Rust, Cargo, GCC, Make
- CLI tools: gh, ripgrep, fd, bat, btop, lazygit, lazydocker, rclone, Wrangler, Cloudflared
- Apps: Pi, Claude Code, Lumen, Proton Pass CLI; Linux also gets Chromium and Google Chrome

## Install

Install with one command:

```sh
curl -fsSL https://raw.githubusercontent.com/hattajr/nix-config/main/scripts/install.sh | sh
```

The installer detects the platform, reuses a working Nix installation when available, otherwise downloads the official multi-user Nix installer and verifies its reviewed SHA-256 checksum before execution. It clones the repository to `~/src/nix-config`, then prompts to apply the configuration. If that checkout already exists, it must be clean. Routine updates remain a separate `bro sync` action.

Home Manager is the sole owner of each configuration file it manages. Activation replaces conflicting files at those managed leaves, including files previously managed by Chezmoi, while preserving unrelated files in shared directories. A colliding regular file or directory is moved under `$XDG_STATE_HOME/home-manager/takeover/` before replacement; existing managed symlinks are simply refreshed. The legacy `~/.gitconfig` is quarantined there after `~/.config/git/config` is linked. Runtime state and secrets outside the managed paths remain writable.

### Manual macOS ownership

Browsers on macOS are intentionally installed and updated manually. Home Manager does not install Chrome or take ownership of browser profiles. Tailscale and Proton split DNS are external host state on every platform: install Tailscale through its signed system package repository, then enable and maintain it through the host tools. The managed `devtunnel` command defaults to the `mbp` SSH hostname and only uses ordinary SSH forwarding.

Home Manager uses the active user's `$USER` and `$HOME`, so it works for arbitrary local account names; automation may override them with `NIX_CONFIG_USERNAME` and `NIX_CONFIG_HOME`. Run `bro auth` after activation to configure optional accounts and API keys.

The flake itself stays pure: it never reads the environment during evaluation. `bro` and the installer resolve the identity in the shell and pass it to the `lib.mkHome` builder as an explicit argument, so any account can be activated without committing it. The owner's own machines are also committed as named configurations, which keeps `nix flake check`, evaluation caching, and the stock `home-manager switch --flake .` CLI working:

```sh
home-manager switch --flake ~/nix-config          # resolves hattajr@latte
nix build ~/nix-config#homeConfigurations."hattajr@latte".activationPackage

# any other account, without editing the flake
nix build --impure --expr '((builtins.getFlake "path:'"$PWD"'").lib.mkHome {
  system = "x86_64-linux"; username = "alice"; homeDirectory = "/home/alice";
}).activationPackage'
```

## `bro` commands

```text
bro health        Check shell and account setup health; does not change versions
bro apply         Build and activate this checkout
bro sync           Fast-forward from upstream, then apply
bro sync --push    Sync, apply, then push local commits
bro update         Interactively update Nixpkgs and/or the custom Pi pin
bro update --verbose  Also show the complete generated Git diff
bro auth           Configure accounts and API keys
```

`bro sync` makes a machine match the versions committed in this repository. `bro update` is the intentional version-change workflow: it first syncs, lets you select Nixpkgs (normal Nix-managed apps), Pi, or both, then shows a concise old-to-new version summary before optionally applying, committing, and pushing it. Use `bro update --verbose` to also inspect the complete generated Git diff. Other machines receive the committed update with `bro sync`.

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

To discard the persistent guest and launch a brand-new Ubuntu VM, use:

```sh
make test-interactive-new
```

`test-interactive` launches (or reuses) a persistent Ubuntu 24.04 VM, mounts the working tree, converts its tracked and non-ignored files—including uncommitted changes—into a local Git fixture, installs the prerequisites, and opens a shell. Run it from a regular host terminal rather than an embedded command pane; the launcher clears any outer `TMUX` value so tmux can start normally in the guest. Follow the displayed local-source installer command. After host edits, run `make test-interactive` again and rerun that installer command to refresh the fixture and activation. The VM remains available until you delete it:

```sh
multipass delete --purge nix-config-interactive-$USER
```

Set `MULTIPASS_INTERACTIVE_IMAGE` or `MULTIPASS_INTERACTIVE_INSTANCE` to override the image or VM name.
