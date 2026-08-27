# Proton Pass references

`pi.env.example` contains no credentials. Copy it to
`~/.config/proton-pass/pi.env`, then replace each placeholder with opaque IDs:

```bash
mkdir -p ~/.config/proton-pass
cp ~/.config/proton-pass/pi.env.example ~/.config/proton-pass/pi.env
chmod 600 ~/.config/proton-pass/pi.env

pass-cli vault list --output json
pass-cli item list --vault-name Development --output json
```

A valid reference is `pass://SHARE_ID/ITEM_ID/FIELD_NAME`. Display names are
not accepted in references and the field is required. Recreate a reference if
its Proton Pass item is recreated.

On Linux, Proton Pass CLI uses the kernel keyring by default; D-Bus is not
required. `proton-pass-session` creates a fresh session when an SSH shell
inherits a revoked keyring, and the Pi wrapper invokes it automatically when
needed. Kernel keys are cleared on reboot, so rerun `nix-config-setup` afterward.

The managed `pi` launcher runs:

```text
pass-cli run --env-file ~/.config/proton-pass/pi.env -- <real-pi>
```

Thus API keys are present only in the Pi process environment. Pi exclusively
owns `~/.pi/agent/auth.json` for per-machine OAuth sessions. If that file still
contains `deepseek`, `google`, or `moonshotai` API-key entries, remove them once
through Pi `/logout`; auth-file credentials override environment variables.
`nix-config-setup --check` reports this conflict without editing the file.

To launch with OAuth only when Proton Pass is unavailable, run
`PI_SKIP_PROTON_PASS=1 pi`.
