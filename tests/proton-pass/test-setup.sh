#!/usr/bin/env bash
set -euo pipefail

repo_root=${BOOTSTRAP_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
system_path=$PATH
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
home="$workdir/home"
mockbin="$workdir/bin"
logfile="$workdir/commands.log"
mkdir -p "$home/.config/proton-pass" "$home/.pi/agent" "$home/.cloudflared" "$mockbin"
: >"$logfile"

cat >"$mockbin/pass-cli" <<'EOF_PASS'
#!/usr/bin/env bash
set -euo pipefail
printf 'pass-cli %s\n' "$*" >>"$TEST_LOG"
case "${1:-}" in
  info) exit 0 ;;
  run)
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
    [ "${1:-}" = -- ] || exit 2
    shift
    export DEEPSEEK_API_KEY=test GEMINI_API_KEY=test MOONSHOT_API_KEY=test
    exec "$@"
    ;;
  *) exit 2 ;;
esac
EOF_PASS
cat >"$mockbin/gh" <<'EOF_GH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ]
EOF_GH
cat >"$mockbin/claude" <<'EOF_CLAUDE'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ]
EOF_CLAUDE
chmod +x "$mockbin/pass-cli" "$mockbin/gh" "$mockbin/claude"

cat >"$home/.config/proton-pass/pi.env" <<'EOF_ENV'
DEEPSEEK_API_KEY=pass://share/deepseek/API_KEY
GEMINI_API_KEY=pass://share/google/API_KEY
MOONSHOT_API_KEY=pass://share/moonshot/API_KEY
EOF_ENV
chmod 600 "$home/.config/proton-pass/pi.env"
printf '%s\n' '{"openai-codex":{"type":"oauth","refresh":"must-survive"}}' >"$home/.pi/agent/auth.json"
printf '%s\n' certificate >"$home/.cloudflared/cert.pem"
auth_before=$(sha256sum "$home/.pi/agent/auth.json")

export HOME="$home"
export XDG_CONFIG_HOME="$home/.config"
export PI_CODING_AGENT_DIR="$home/.pi/agent"
export TEST_LOG="$logfile"
export PATH="$mockbin:$system_path"

output=$("$repo_root/bin/nix-config-setup" --check)
grep -Fq 'Proton Pass: ready' <<<"$output" || { printf '%s\n' 'setup test: Pass was not ready' >&2; exit 1; }
grep -Fq 'Pi API-key references: ready' <<<"$output" || { printf '%s\n' 'setup test: references were not ready' >&2; exit 1; }
grep -Fq 'Pi account login: detected' <<<"$output" || { printf '%s\n' 'setup test: OAuth was not detected' >&2; exit 1; }
grep -Fq 'GitHub CLI: authenticated' <<<"$output" || { printf '%s\n' 'setup test: GitHub status is wrong' >&2; exit 1; }
grep -Fq 'Claude: authenticated' <<<"$output" || { printf '%s\n' 'setup test: Claude status is wrong' >&2; exit 1; }
grep -Fq 'Cloudflare Tunnel: authenticated' <<<"$output" || { printf '%s\n' 'setup test: Cloudflare status is wrong' >&2; exit 1; }
[ "$auth_before" = "$(sha256sum "$home/.pi/agent/auth.json")" ] || {
  printf '%s\n' 'setup test: status check modified Pi auth' >&2
  exit 1
}
grep -Fq 'pass-cli run --env-file' "$logfile" || { printf '%s\n' 'setup test: references were not resolved' >&2; exit 1; }

# Local API-key entries shadow environment variables and must be reported,
# while account/OAuth entries remain untouched.
printf '%s\n' '{"openai-codex":{"type":"oauth","refresh":"must-survive"},"deepseek":{"type":"api_key","key":"old-local-key"}}' >"$home/.pi/agent/auth.json"
conflict_before=$(sha256sum "$home/.pi/agent/auth.json")
set +e
conflict_output=$("$repo_root/bin/nix-config-setup" --check)
conflict_status=$?
set -e
[ "$conflict_status" -eq 1 ] || { printf '%s\n' 'setup test: shadowing auth entry did not fail check' >&2; exit 1; }
grep -Fq 'Pi API-key references: not ready' <<<"$conflict_output" || {
  printf '%s\n' 'setup test: shadowing auth entry was not reported' >&2
  exit 1
}
[ "$conflict_before" = "$(sha256sum "$home/.pi/agent/auth.json")" ] || {
  printf '%s\n' 'setup test: conflict check modified Pi auth' >&2
  exit 1
}
printf '%s\n' '{"openai-codex":{"type":"oauth","refresh":"must-survive"}}' >"$home/.pi/agent/auth.json"
auth_before=$(sha256sum "$home/.pi/agent/auth.json")

# Placeholder references fail before pass-cli run and do not touch OAuth state.
cat >"$home/.config/proton-pass/pi.env" <<'EOF_PLACEHOLDER'
DEEPSEEK_API_KEY=pass://REPLACE_SHARE_ID/deepseek/API_KEY
GEMINI_API_KEY=pass://share/google/API_KEY
MOONSHOT_API_KEY=pass://share/moonshot/API_KEY
EOF_PLACEHOLDER
: >"$logfile"
set +e
"$repo_root/bin/nix-config-setup" --check >/dev/null
check_status=$?
set -e
[ "$check_status" -eq 1 ] || { printf '%s\n' 'setup test: placeholder references did not fail check' >&2; exit 1; }
! grep -q 'pass-cli run' "$logfile" || { printf '%s\n' 'setup test: unresolved placeholders reached Pass' >&2; exit 1; }
[ "$auth_before" = "$(sha256sum "$home/.pi/agent/auth.json")" ] || {
  printf '%s\n' 'setup test: failed check modified Pi auth' >&2
  exit 1
}

# A symlink is invalid but --check remains a status report rather than aborting.
rm -f "$home/.config/proton-pass/pi.env"
printf '%s\n' 'DEEPSEEK_API_KEY=pass://share/item/API_KEY' >"$home/.config/proton-pass/pi.env.target"
ln -s pi.env.target "$home/.config/proton-pass/pi.env"
set +e
symlink_output=$("$repo_root/bin/nix-config-setup" --check 2>&1)
symlink_status=$?
set -e
[ "$symlink_status" -eq 1 ] || { printf '%s\n' 'setup test: symlink did not fail check' >&2; exit 1; }
grep -Fq 'Pi API-key references: not ready' <<<"$symlink_output" || {
  printf '%s\n' 'setup test: symlink status was not reported' >&2
  exit 1
}
! grep -Fq 'ERROR:' <<<"$symlink_output" || { printf '%s\n' 'setup test: symlink aborted status reporting' >&2; exit 1; }

printf '%s\n' 'setup test: PASSED (references, status, conflicts, symlinks, and OAuth preservation)'
