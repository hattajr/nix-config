# ChezMoi takeover contract

`chezmoi-af63b22.inventory.json` is the reviewed, path-only inventory for the
ChezMoi reference commit verified before takeover. `ownership.json` assigns every discovered
path to Home Manager, Proton Pass runtime state, or explicit retirement.

Use `scripts/migrate-chezmoi.py plan` to inspect a no-change plan. It prints a
content-sensitive digest. Only `execute --digest <that-digest>` backs up exact
approved files. The journal is private under `$XDG_STATE_HOME/nix-config` and
allows the same invocation to resume after a failed activation. `rollback`
never overwrites a destination.

The tool never runs ChezMoi or reads/decrypts secret contents. After verified
backups, it appends a deterministic guard to the source `.chezmoiignore` so a
later `chezmoi apply` cannot overwrite Home Manager takeover paths. The prior
ignore file is retained in the private transaction and restored by a
pre-activation rollback. Pi auth and Proton Pass runtime state remain writable
and outside Home Manager links.

## Lifecycle ownership

- Stage-zero/bootstrap and validation are replaced by `scripts/install.sh`,
  `scripts/bootstrap.sh`, `bro apply`, and `bro health`.
- Mise, TPM, manual Neovim builds, and Mosh OSC-52 setup are retired. Mosh
  artifacts are only reported by `bro migration legacy`; no package manager is
  invoked.
- Neovim, tmux plugins, static Pi files, and custom `devtunnel`, `pi`, and
  `pi-models-sync` scripts are Home Manager/Nix-owned. Pi and Neovim runtime
  state remain writable exclusions.
- Linux browser packages are Nix-owned. macOS browsers and the macOS
  Tailscale/Proton split-DNS setup are explicit external/manual ownership.
- Proton Pass is the selected runtime-secret owner. The legacy encrypted
  ChezMoi secret is preserved in its immutable source and is not inspected.
