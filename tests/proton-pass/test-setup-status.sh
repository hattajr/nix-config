#!/usr/bin/env bash
# The status mode other programs read: one row per --check line, with a level,
# and failures exactly where --check fails.
set -euo pipefail

repo_root=${BOOTSTRAP_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
setup="$repo_root/bin/nix-config-setup"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
home="$workdir/home"
mockbin="$workdir/bin"
state="$workdir/state"
mkdir -p "$home/.config/proton-pass" "$home/.pi/agent" "$mockbin" "$state"

fail_test() {
  printf 'setup status test: %s\n' "$1" >&2
  exit 1
}

# Each mock answers from a state file, so a fixture is a set of touched files.
# Resolving a reference exports a recognisable value that must never be shown.
cat >"$mockbin/pass-cli" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  info) [ -f "$TEST_STATE/pass" ] ;;
  run)
    [ ! -f "$TEST_STATE/pass-unresolved" ] || exit 1
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
    shift
    export DEEPSEEK_API_KEY=secret-value-never-shown GEMINI_API_KEY=secret-value-never-shown \
      MOONSHOT_API_KEY=secret-value-never-shown
    exec "$@"
    ;;
  *) exit 2 ;;
esac
EOF
cat >"$mockbin/tailscale" <<'EOF'
#!/usr/bin/env bash
[ -f "$TEST_STATE/tailscaled" ] || exit 1
if [ -f "$TEST_STATE/tailscale" ]; then
  printf '%s\n' '{"BackendState":"Running"}'
else
  printf '%s\n' '{"BackendState":"NeedsLogin"}'
fi
EOF
for tool in claude gh wrangler; do
  cat >"$mockbin/$tool" <<EOF
#!/usr/bin/env bash
[ -f "\$TEST_STATE/$tool" ]
EOF
done
# Tailscale is managed only on Linux, so every host reports it as Linux does.
printf '#!/bin/sh\nprintf "%%s\\n" Linux\n' >"$mockbin/uname"
chmod +x "$mockbin"/*

export HOME="$home"
export XDG_CONFIG_HOME="$home/.config"
export PI_CODING_AGENT_DIR="$home/.pi/agent"
export TEST_STATE="$state"
# Only the tools the setup tool and this test use, so a CLI installed on the
# host never stands in for a mock that a fixture removed.
minimalbin="$workdir/minimal-bin"
mkdir -p "$minimalbin"
for tool in bash cat chmod cut git grep jq mkdir mktemp node rm tail touch; do
  tool_path=$(type -a -p "$tool" 2>/dev/null | grep -v '/intercepted-commands/' | head -n 1 || true)
  [ -n "$tool_path" ] || fail_test "$tool is required"
  ln -s "$tool_path" "$minimalbin/$tool"
done
export PATH="$mockbin:$minimalbin"
unset GIT_CONFIG_GLOBAL

# Runs both modes and asserts that --status says, row for row and in order,
# what the --check table says, that both exit alike, and that the levels are
# EXPECTED_STATUS then the given "level<TAB>label" pairs.
expect_rows() {
  local name=$1 expected_status=$2 && shift 2
  local check_output status_output check_status=0 status_status=0 table
  check_output=$("$setup" --check 2>/dev/null) || check_status=$?
  status_output=$("$setup" --status 2>/dev/null) || status_status=$?
  [ "$check_status" = "$expected_status" ] || fail_test "$name: --check exited $check_status"
  [ "$status_status" = "$check_status" ] \
    || fail_test "$name: --status exited $status_status but --check exited $check_status"
  table=$(printf '\n== Current setup status ==\n'
    while IFS=$'\t' read -r _ label detail; do
      printf '  %-22s %s\n' "$label" "$detail"
    done <<<"$status_output")
  [ "$table" = "$check_output" ] \
    || fail_test "$name: --status rows differ from the --check table:"$'\n'"$status_output"$'\n'"$check_output"
  [ "$(cut -f 1,2 <<<"$status_output")" = "$(printf '%s\n' "$@")" ] \
    || fail_test "$name: unexpected levels:"$'\n'"$status_output"
  ! grep -Fq 'secret-value-never-shown' <<<"$status_output" \
    || fail_test "$name: --status printed a secret value"
  ! grep -Fq 'old-local-key' <<<"$status_output" \
    || fail_test "$name: --status printed a Pi API key"
}

# Nothing set up: every row is optional and nothing fails.
expect_rows 'nothing configured' 0 \
  $'optional\tProton Pass' \
  $'optional\tDeepSeek API key' \
  $'optional\tGemini API key' \
  $'optional\tMoonshot API key' \
  $'optional\tPi account login' \
  $'optional\tClaude Code' \
  $'optional\tTailscale' \
  $'optional\tGit identity' \
  $'optional\tGitHub CLI' \
  $'optional\tCloudflare Tunnel' \
  $'optional\tWrangler'
grep -Fxq $'optional\tTailscale\tdaemon is not running' <<<"$("$setup" --status)" \
  || fail_test 'a stopped Tailscale daemon was not reported as optional'

# Everything ready.
touch "$state/pass" "$state/tailscaled" "$state/tailscale" "$state/claude" "$state/gh" "$state/wrangler"
mkdir -p "$home/.cloudflared"
printf '%s\n' certificate >"$home/.cloudflared/cert.pem"
git config --file "$home/.gitconfig" user.name 'Test User'
git config --file "$home/.gitconfig" user.email 'test@example.com'
printf '%s\n' '{"openai-codex":{"type":"oauth","refresh":"oauth-token"}}' >"$home/.pi/agent/auth.json"
cat >"$home/.config/proton-pass/pi.env" <<'EOF'
DEEPSEEK_API_KEY=pass://share-dev/item-deepseek/API%20Key
GEMINI_API_KEY=pass://share-dev/item-gemini/API%20Key
EOF
chmod 600 "$home/.config/proton-pass/pi.env"
expect_rows 'everything ready' 0 \
  $'ok\tProton Pass' \
  $'ok\tDeepSeek API key' \
  $'ok\tGemini API key' \
  $'optional\tMoonshot API key' \
  $'ok\tPi account login' \
  $'ok\tClaude Code' \
  $'ok\tTailscale' \
  $'ok\tGit identity' \
  $'ok\tGitHub CLI' \
  $'ok\tCloudflare Tunnel' \
  $'ok\tWrangler'
grep -Fxq $'ok\tGit identity\tTest User <test@example.com>' <<<"$("$setup" --status)" \
  || fail_test 'the Git identity row did not carry the --check detail'

# A reference that no longer resolves and a local Pi key that shadows Proton
# Pass both fail --check, so both are failing rows.
touch "$state/pass-unresolved"
printf '%s\n' '{"openai-codex":{"type":"oauth"},"deepseek":{"type":"api_key","key":"old-local-key"}}' \
  >"$home/.pi/agent/auth.json"
expect_rows 'unresolved and shadowed' 1 \
  $'ok\tProton Pass' \
  $'fail\tDeepSeek API key' \
  $'fail\tGemini API key' \
  $'optional\tMoonshot API key' \
  $'fail\tPi API shadowing' \
  $'ok\tPi account login' \
  $'ok\tClaude Code' \
  $'ok\tTailscale' \
  $'ok\tGit identity' \
  $'ok\tGitHub CLI' \
  $'ok\tCloudflare Tunnel' \
  $'ok\tWrangler'
rm -f "$state/pass-unresolved"
printf '%s\n' '{"openai-codex":{"type":"oauth"}}' >"$home/.pi/agent/auth.json"

# Configured references with Proton Pass logged out fail; the logged-out
# Proton Pass row itself stays optional, as in --check.
rm -f "$state/pass"
expect_rows 'Proton Pass logged out' 1 \
  $'optional\tProton Pass' \
  $'fail\tDeepSeek API key' \
  $'fail\tGemini API key' \
  $'optional\tMoonshot API key' \
  $'ok\tPi account login' \
  $'ok\tClaude Code' \
  $'ok\tTailscale' \
  $'ok\tGit identity' \
  $'ok\tGitHub CLI' \
  $'ok\tCloudflare Tunnel' \
  $'ok\tWrangler'

# An invalid reference file is one failing row in place of the providers.
printf '%s\n' 'DEEPSEEK_API_KEY=pass://REPLACE_SHARE_ID/item/API%20Key' >"$home/.config/proton-pass/pi.env"
expect_rows 'invalid references' 1 \
  $'optional\tProton Pass' \
  $'fail\tPi API references' \
  $'ok\tPi account login' \
  $'ok\tClaude Code' \
  $'ok\tTailscale' \
  $'ok\tGit identity' \
  $'ok\tGitHub CLI' \
  $'ok\tCloudflare Tunnel' \
  $'ok\tWrangler'

# Missing tools are reported, never failed.
rm -f "$home/.config/proton-pass/pi.env" "$mockbin/tailscale" "$mockbin/claude" "$mockbin/gh"
expect_rows 'missing tools' 0 \
  $'optional\tProton Pass' \
  $'optional\tDeepSeek API key' \
  $'optional\tGemini API key' \
  $'optional\tMoonshot API key' \
  $'ok\tPi account login' \
  $'optional\tClaude Code' \
  $'optional\tTailscale' \
  $'ok\tGit identity' \
  $'optional\tGitHub CLI' \
  $'ok\tCloudflare Tunnel' \
  $'ok\tWrangler'

# A row is one line of three fields even when a detail holds a tab.
git config --file "$home/.gitconfig" user.name $'Tab\tUser'
grep -Fxq $'ok\tGit identity\tTab User <test@example.com>' <<<"$("$setup" --status)" \
  || fail_test 'a tab in a detail split its row'

printf '%s\n' 'setup status test: PASSED (rows match --check, failing rows, optional rows, no secret values)'
