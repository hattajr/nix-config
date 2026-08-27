# Proton Pass bootstrap: revised POC

This is the authoritative V2 design and implementation record. Proton Pass is
the source of truth for long-lived credentials; Git, Nix, and `/nix/store`
contain none.

## Mental model

```text
1. PUBLIC BOOTSTRAP (no secrets)
   install.sh
   ├─ detect OS and CPU architecture automatically
   │  ├─ Apple Silicon macOS ──> aarch64-darwin
   │  ├─ ARM64 Linux ──────────> aarch64-linux
   │  └─ x86-64 Linux ─────────> x86_64-linux
   ├─ install Nix                         (only when missing)
   ├─ obtain temporary Git with Nix       (only when Git is missing)
   ├─ clone public nix-config repository  (no GitHub login)
   └─ run bootstrap.sh DEST
                         │
                         ▼
2. HOME MANAGER ACTIVATION (declarative, no account logins)
   ├─ build the detected platform configuration
   ├─ install Git, pass-cli, Pi, Lumen, Node, and setup/session helpers
   ├─ install uv, lazydocker, fzf, and the other development tools
   ├─ install shell, SSH, tmux, Neovim, and static Pi configuration
   └─ finish successfully even when no account is authenticated
                         │
                         ▼
3. LOCAL CREDENTIAL STORE (required by pass-cli itself)
   WHY: pass-cli encrypts its local database with a key from the OS keyring;
        without one, every command fails before login—including PAT login.
   ├─ macOS ──> use the user's system Keychain
   └─ Linux ──> use the default kernel keyring; repair revoked SSH sessions
                 with proton-pass-session/keyctl (no D-Bus required)
                         │
                         ▼
4. PROTON PASS LOGIN (interactive, resumable)
   ├─ local terminal ──> pass-cli login --interactive
   └─ SSH/headless ────> restricted PAT or a tested terminal login flow
       CASE: remotely provisioning a Linux system without a browser
                         │
                         ▼
5. PROTON PASS-BACKED PI LAUNCH (no auth.json writes)
   ├─ pi.env contains only opaque pass://SHARE_ID/ITEM_ID/FIELD references
   ├─ the Pi wrapper runs pass-cli run --env-file pi.env -- <real-pi>
   ├─ API keys exist only in the launched Pi process environment
   └─ Pi remains the sole owner of local account/OAuth auth.json state
                         │
                         ▼
6. PER-MACHINE ACCOUNT LOGINS (interactive post-activation setup)
   ├─ Pi account/OAuth providers are logged into manually on every machine
   └─ GitHub, Claude, and Cloudflare each run their own interactive login

Ownership boundary:
  Proton Pass ──> long-lived API keys
  Each machine ──> its own mutable Pi/service OAuth sessions
  Git/Nix store ──> only non-secret references; no auth.json snapshot
```

## Installation order

1. **Remove dead SOPS bootstrap first.** It currently stops a fresh host
   waiting for a nonexistent SOPS policy. Remove SOPS and bootstrap-only age
   dependencies; retain `age` only if an independent use remains after audit.
2. **Stage zero:** `install.sh` installs Nix if needed, detects
   `aarch64-darwin`, `aarch64-linux`, or `x86_64-linux`, clones the public
   repository, then calls `bootstrap.sh DEST`. `NIX_CONFIG_PLATFORM` can
   override detection for automation. An Ubuntu ARM64 UTM guest naturally uses
   `aarch64-linux`; no disposable machine-specific target is needed. All three
   platform outputs target the `hattajr` account and its conventional home.
3. **Activate Home Manager.** It installs Git, `proton-pass-cli`, Pi, Lumen,
   Node, `uv`, lazydocker, `fzf`, and the setup/session helpers. Activation
   remains non-interactive and never contacts Proton Pass.
4. **Prepare Linux's credential store.** Proton Pass CLI defaults to the Linux
   kernel keyring, which requires neither D-Bus nor a graphical session. Remote
   shells can inherit a revoked keyring; `proton-pass-session` checks it and
   runs `keyctl new_session` only when needed. Kernel keys do not survive a
   reboot, so rerun login/setup afterward. D-Bus/GNOME Keyring remains an
   optional persistent desktop backend, not a bootstrap prerequisite.
5. **Log into Proton Pass.** Local terminal: `pass-cli login --interactive`.
   SSH/headless is for remotely provisioning the Linux hosts without a browser;
   use a tested terminal flow or a restricted, expiring PAT supplied through
   `PROTON_PASS_PERSONAL_ACCESS_TOKEN` for the `pass-cli login` process.
6. **Configure Pi references.** `nix-config-setup` creates a local dotenv file
   containing only opaque `pass://` references. The managed Pi wrapper resolves
   those references with `pass-cli run`; it never writes API keys to
   `auth.json`. Existing API-key entries must first be removed with Pi `/logout`
   because auth-file entries take priority over environment variables.
7. **Run account logins after activation.** `nix-config-setup` interactively
   offers Pi account providers, GitHub, Claude, and Cloudflare on each machine.
   Home Manager installs the CLIs but does not perform login during activation.

## Proton Pass references

`pass-cli` references use IDs, not vault or item display names, and the field
segment is mandatory:

```text
pass://SHARE_ID/ITEM_ID/FIELD_NAME
```

The operational file is a mode-600 dotenv file containing references only:

```dotenv
DEEPSEEK_API_KEY=pass://SHARE_ID/ITEM_ID/API_KEY
GEMINI_API_KEY=pass://SHARE_ID/ITEM_ID/API_KEY
MOONSHOT_API_KEY=pass://SHARE_ID/ITEM_ID/API_KEY
```

Populate it after login with `pass-cli vault list --output json` and
`pass-cli item list --vault-name Development --output json`. Item recreation
changes its ID. Update the non-secret map and reference file together; never
put a field value in either.

## Pi authentication ownership: no merge

The managed Pi wrapper runs:

```text
pass-cli run --env-file ~/.config/proton-pass/pi.env -- <real-pi>
```

Pi reads those API keys from its process environment. Proton Pass resolves them
at launch, so no helper injects plaintext into `auth.json`, no `jq`/Node merge
is needed, and no secret template is rendered to disk.

Pi alone owns `~/.pi/agent/auth.json`, including account access tokens, refresh
tokens, expiry, and account IDs. Account providers are logged into manually on
each machine. Existing DeepSeek, Google, or Moonshot API-key entries must be
removed once through Pi `/logout`, because Pi gives auth-file entries priority
over environment variables. The setup helper detects and reports this conflict;
it does not edit `auth.json`.

When Proton Pass is temporarily unavailable, `PI_SKIP_PROTON_PASS=1 pi` starts
Pi with only its local OAuth state.

### Why not age-encrypt the whole `auth.json` in Git?

That would bundle long-lived keys with short-lived, mutable OAuth tokens. Each
machine could overwrite the others' state, Git would retain old encrypted token
snapshots, and Home Manager would need an interactive passphrase during an
otherwise deterministic activation. Encryption hides values but does not fix
ownership or lifecycle.

`~/.pi/agent/secrets.json` remains outside this flow. It is extension-owned
runtime data (currently Telegram credentials), ignored by Git, and untouched by
Home Manager and the Pi launcher.

## Boundaries and validation

- Reference examples/maps are tracked; the operational reference file is local,
  mode 600, and contains no secret values.
- `pass-cli run` masks resolved secret values on stdout/stderr by default.
- Nix evaluation and Home Manager activation perform no login or secret
  resolution.
- Validate macOS and Linux, including an SSH shell with a fresh/revoked kernel
  keyring, live reference resolution, OAuth-only bypass, and proof that
  activation and Pi launch never modify `auth.json`.
