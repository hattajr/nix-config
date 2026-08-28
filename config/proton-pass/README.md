# Proton Pass-backed Pi credentials

Run the account wizard after Home Manager activation:

```text
bro auth
```

On Linux, `bro auth` automatically places the wizard in a valid kernel-keyring
session. The wizard handles Proton Pass login, discovery, validation, optional
skips, and account logins without opening an editor or asking for environment
variables, opaque IDs, or `pass://` syntax.

## Secrets to prepare

All API-key providers are optional. For each provider you want, create one item
in Proton Pass using this exact layout:

| Vault | Item title | Hidden field | Field value |
| --- | --- | --- | --- |
| Development | `llm-deepseek` | `API Key` | DeepSeek API key |
| Development | `llm-google` | `API Key` | Gemini API key |
| Development | `llm-moonshotai` | `API Key` | Moonshot API key |

The legacy titles `llm-gemini` and `llm-moonshot` are also recognized. Keep
the wizard open while adding a missing item, then choose retry. It finds the
item automatically and validates the field without displaying its value.

GitHub CLI, Pi account providers, Cloudflare Tunnel, and Wrangler use their own
interactive OAuth/browser login flows; no additional secret needs to be stored
in Proton Pass. Git author name and email are not secrets and can be entered
directly in the wizard; they are stored in the writable
`~/.config/git/identity` include rather than Home Manager's read-only Git
configuration. A Proton Pass personal access token is needed only when
you choose token login instead of interactive Proton login.

## Runtime boundary

The wizard writes only mode-600 opaque references to
`~/.config/proton-pass/pi.env`. The managed Pi launcher internally runs
`pass-cli run --env-file` so API keys exist only in the Pi child process
environment. Pi exclusively owns `~/.pi/agent/auth.json` for per-machine OAuth
sessions. The wizard never writes or merges that file.

If `auth.json` contains old `deepseek`, `google`, or `moonshotai` API-key
entries, the wizard offers to open Pi and directs the user through `/logout`;
those local entries otherwise override Proton Pass.

On Linux, `proton-pass-session` repairs revoked SSH keyring sessions. Kernel
keys are cleared on reboot, so rerun `bro auth` when Proton Pass reports that it
is logged out.
