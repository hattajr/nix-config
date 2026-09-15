# nix-config

Personal Home Manager configuration for macOS (Apple Silicon) and Linux (x86-64, ARM64).

## Included

- Shell and terminal: zsh, tmux, Neovim, Git, SSH, fzf, atuin
- Development: Node.js, Bun, Deno, Python, uv, Go, Rust, Cargo, GCC, Make
- CLI tools: gh, ripgrep, fd, bat, btop, lazygit, lazydocker, rclone, Wrangler, Cloudflared
- Apps: Pi, Claude Code, Lumen, Proton Pass CLI; Linux also gets Chromium and Google Chrome

## Install

One command, no arguments, no configuration:

```sh
curl -fsSL https://raw.githubusercontent.com/hattajr/nix-config/main/scripts/install.sh | sh
```

It shows what it is about to do, then asks before each step: installing Nix if
it is missing, cloning to `~/src/nix-config`, activating, configuring accounts,
and entering the managed shell. Declining any step leaves the machine unchanged.
The platform is detected from the machine and the destination is fixed, so there
is nothing to pass and nothing to set.

Installation needs a terminal. There is no unattended mode: every choice is a
prompt, and running without a terminal fails rather than guessing an answer.

### Everything else is one menu

```sh
bro
```

```text
  1) Apply        activate this checkout
  2) Sync         fast-forward from upstream, then apply
  3) Update       change pinned versions or update Pi extensions
  4) Accounts     configure logins and API keys
  5) Health       check shell, accounts, and PATH
  6) Clean up     quarantine binaries shadowing Nix
  7) Quit         leave the menu
```

`bro` takes no arguments and no flags. Choices that used to be flags, such as
pushing after a sync or showing a generated diff, are prompts inside the step
that needs them. A step that fails returns to the menu rather than ending the
session.

`Sync` makes a machine match the versions committed here. `Update` is the
intentional version-change workflow: it syncs first, asks what may change, shows
an old-to-new summary, then asks before applying, committing, and pushing. Other
machines receive the result with `Sync`.

`Update` offers Nixpkgs, Pi, Pi extensions, or everything. Nixpkgs and Pi are
pins in tracked files, so they go through that review-and-commit flow. Pi
extensions are the npm packages listed in `config/pi/agent/settings.json`, which
Pi installs into its own writable state; choosing them runs `pi update
--extensions` on this machine only and changes nothing in the repository, so
each machine updates them itself.

### How ownership works

Home Manager is the sole owner of each configuration file it manages. Activation
replaces conflicting files at those managed leaves, including files previously
managed by Chezmoi, while preserving unrelated files in shared directories. A
colliding regular file or directory is moved under
`$XDG_STATE_HOME/home-manager/takeover/` before replacement; existing managed
symlinks are simply refreshed. The legacy `~/.gitconfig` is quarantined there
after `~/.config/git/config` is linked. Runtime state and secrets outside the
managed paths remain writable.

### Manual macOS ownership

Browsers on macOS are intentionally installed and updated manually. Home Manager does not install Chrome or take ownership of browser profiles. Tailscale and Proton split DNS are external host state on every platform: install Tailscale through its signed system package repository, then enable and maintain it through the host tools. The managed `devtunnel` command defaults to the `mbp` SSH hostname and only uses ordinary SSH forwarding. The managed SSH client is the GSSAPI build, because hosts such as Ubuntu set `GSSAPIAuthentication` in `/etc/ssh/ssh_config` and a client built without that keyword warns on every connection.

### Identity

Home Manager uses the active user's `$USER` and `$HOME`, so it works for arbitrary local account names. Identity is read from the account itself and cannot be set by hand.

The flake itself stays pure: it never reads the environment during evaluation. The menu and the installer resolve the identity in the shell and pass it to the `lib.mkHome` builder as an explicit argument, so any account can be activated without committing it. The owner's own configurations are also committed, keyed by system (`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`) rather than by `user@host`, which keeps `nix flake check` and evaluation caching working and survives a host being renamed or replaced.

For direct Nix use outside the menu, the attribute is a system rather than `$USER@$(hostname)`, so it must be named explicitly:

```sh
home-manager switch --flake ~/nix-config#x86_64-linux
nix build ~/nix-config#homeConfigurations."x86_64-linux".activationPackage

# any other account, without editing the flake
nix build --impure --expr '((builtins.getFlake "path:'"$PWD"'").lib.mkHome {
  system = "x86_64-linux"; username = "alice"; homeDirectory = "/home/alice";
}).activationPackage'
```

## Shadowed binaries

`~/.local/bin` deliberately outranks `~/.nix-profile/bin` on PATH so that the
wrappers this repository installs there, such as `pi` and `vim`, take
precedence over the packages they wrap. A tool installed by hand into the same
directory inherits that precedence and silently shadows its Nix-managed
counterpart, which is how a stale `uv` keeps running after Nix ships a newer one.

Every activation reports such files and never blocks on them:

```
warning: 2 unmanaged binaries are shadowing the Nix profile (rclone uv).
         Run bro and choose Clean up to review them.
```

`Health` reports the same finding as `PATH WARN` and offers to review it there
and then, and `Clean up` goes straight to the review. It stays a warning rather
than a failure: a hand-installed tool in `~/.local/bin` is common enough that
failing on one would break a first install.

Reviewing walks each finding one at a time. Files move under
`$XDG_STATE_HOME/home-manager/shadowed/` and are never deleted, so a tool kept
on purpose can be restored from there.

Symlinks into the Nix store are this repository's own wrappers and are never
reported. Tools that update themselves into the user profile, currently
`claude`, are expected to outrank the Nix copy and are listed in
`allowedShadows` in `home/modules/shadowed-binaries.nix`.

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
