#!/usr/bin/env bash
set -euo pipefail

repo_root=${BOOTSTRAP_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
system_path=$PATH
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
home="$workdir/home"
mockbin="$workdir/bin"
logfile="$workdir/commands.log"
state="$workdir/state"
mkdir -p "$home/.config/proton-pass" "$home/.config/git" "$home/.pi/agent" \
  "$home/.cloudflared" "$mockbin" "$state"
: >"$logfile"

file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

run_pty() {
  GUIDED_INPUT=$1 SETUP_COMMAND="$repo_root/bin/nix-config-setup" python3 <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import time

pid, master = pty.fork()
if pid == 0:
    os.execv(os.environ["SETUP_COMMAND"], [os.environ["SETUP_COMMAND"]])
payload = os.environ["GUIDED_INPUT"].encode()
if payload:
    os.write(master, payload)
deadline = time.monotonic() + 5
while True:
    remaining = deadline - time.monotonic()
    if remaining <= 0 or not select.select([master], [], [], remaining)[0]:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
        print("setup test: PTY scenario timed out after 5 seconds", file=sys.stderr)
        sys.exit(124)
    try:
        data = os.read(master, 4096)
    except OSError as error:
        if error.errno == errno.EIO:
            break
        raise
    if not data:
        break
    sys.stdout.buffer.write(data)
_, status = os.waitpid(pid, 0)
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(128 + os.WTERMSIG(status))
PY
}

cat >"$mockbin/pass-cli" <<'EOF_PASS'
#!/usr/bin/env bash
set -euo pipefail
printf 'pass-cli %s\n' "$*" >>"$TEST_LOG"
case "${1:-}" in
  info) exit 0 ;;
  vault)
    printf '%s\n' '{"vaults":[{"name":"Development","vault_id":"vault-dev","share_id":"share-dev"}]}'
    ;;
  item)
    if [ "${MOCK_MISSING_MOONSHOT:-0}" = 1 ]; then
      cat <<'EOF_ITEMS_SHORT'
{"items":[
  {"id":"item-deepseek","share_id":"share-dev","vault_id":"vault-dev","state":"active","flags":[],"create_time":"2026-01-01T00:00:00","modify_time":"2026-01-01T00:00:00","title":"llm-deepseek","item_type":"custom"},
  {"id":"item-gemini","share_id":"share-dev","vault_id":"vault-dev","state":"active","flags":[],"create_time":"2026-01-01T00:00:00","modify_time":"2026-01-01T00:00:00","title":"llm-gemini","item_type":"custom"}
]}
EOF_ITEMS_SHORT
    else
      cat <<'EOF_ITEMS'
{"items":[
  {"id":"item-deepseek","share_id":"share-dev","vault_id":"vault-dev","state":"active","flags":[],"create_time":"2026-01-01T00:00:00","modify_time":"2026-01-01T00:00:00","title":"llm-deepseek","item_type":"custom"},
  {"id":"item-gemini","share_id":"share-dev","vault_id":"vault-dev","state":"active","flags":[],"create_time":"2026-01-01T00:00:00","modify_time":"2026-01-01T00:00:00","title":"llm-gemini","item_type":"custom"},
  {"id":"item-moonshot","share_id":"share-dev","vault_id":"vault-dev","state":"active","flags":[],"create_time":"2026-01-01T00:00:00","modify_time":"2026-01-01T00:00:00","title":"llm-moonshot","item_type":"custom"}
]}
EOF_ITEMS
    fi
    ;;
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
set -euo pipefail
printf 'gh %s\n' "$*" >>"$TEST_LOG"
[ "${1:-}" = auth ] || exit 2
case "${2:-}" in
  status) [ -f "$TEST_STATE/gh" ] ;;
  login) touch "$TEST_STATE/gh" ;;
  *) exit 2 ;;
esac
EOF_GH
cat >"$mockbin/cloudflared" <<'EOF_CLOUDFLARED'
#!/usr/bin/env bash
set -euo pipefail
printf 'cloudflared %s\n' "$*" >>"$TEST_LOG"
if [ "${1:-}" = tunnel ] && [ "${2:-}" = login ]; then
  mkdir -p "$HOME/.cloudflared"
  printf '%s\n' certificate >"$HOME/.cloudflared/cert.pem"
fi
EOF_CLOUDFLARED
cat >"$mockbin/wrangler" <<'EOF_WRANGLER'
#!/usr/bin/env bash
set -euo pipefail
printf 'wrangler %s\n' "$*" >>"$TEST_LOG"
case "${1:-}" in
  whoami) [ -f "$TEST_STATE/wrangler" ] ;;
  login) touch "$TEST_STATE/wrangler" ;;
  *) exit 2 ;;
esac
EOF_WRANGLER
cat >"$mockbin/pi" <<'EOF_PI'
#!/usr/bin/env bash
printf 'pi %s\n' "$*" >>"$TEST_LOG"
exit 0
EOF_PI
cat >"$mockbin/nvim" <<'EOF_NVIM'
#!/usr/bin/env bash
printf '%s\n' 'setup test: editor must not be opened' >&2
exit 99
EOF_NVIM
chmod +x "$mockbin/pass-cli" "$mockbin/gh" "$mockbin/cloudflared" \
  "$mockbin/wrangler" "$mockbin/pi" "$mockbin/nvim"

export HOME="$home"
export XDG_CONFIG_HOME="$home/.config"
export PI_CODING_AGENT_DIR="$home/.pi/agent"
export TEST_LOG="$logfile"
export TEST_STATE="$state"
export PATH="$mockbin:$system_path"
touch "$state/gh" "$state/wrangler"

# Match Home Manager: XDG's Git config is a read-only managed symlink that
# includes a separate writable identity file.
managed_gitconfig="$workdir/managed.gitconfig"
# The literal tilde is expanded later by Git when it reads include.path.
# shellcheck disable=SC2088
git config --file "$managed_gitconfig" include.path '~/.config/git/identity'
chmod 444 "$managed_gitconfig"
ln -s "$managed_gitconfig" "$HOME/.config/git/config"
git config --file "$HOME/.config/git/identity" user.name 'Test User'
git config --file "$HOME/.config/git/identity" user.email 'test@example.com'
printf '%s\n' '{"openai-codex":{"type":"oauth","refresh":"must-survive"}}' >"$home/.pi/agent/auth.json"
printf '%s\n' certificate >"$home/.cloudflared/cert.pem"
auth_before=$(file_hash "$home/.pi/agent/auth.json")

cat >"$home/.config/proton-pass/pi.env" <<'EOF_ENV'
DEEPSEEK_API_KEY=pass://share-dev/item-deepseek/API%20Key
GEMINI_API_KEY=pass://share-dev/item-gemini/API%20Key
MOONSHOT_API_KEY=pass://share-dev/item-moonshot/API%20Key
EOF_ENV
chmod 600 "$home/.config/proton-pass/pi.env"

output=$("$repo_root/bin/nix-config-setup" --check)
grep -Eq 'DeepSeek API key +ready' <<<"$output" || { printf '%s\n' 'setup test: DeepSeek status is wrong' >&2; exit 1; }
grep -Eq 'Pi account login +ready' <<<"$output" || { printf '%s\n' 'setup test: OAuth status is wrong' >&2; exit 1; }
grep -Eq 'GitHub CLI +ready' <<<"$output" || { printf '%s\n' 'setup test: GitHub status is wrong' >&2; exit 1; }
grep -Eq 'Cloudflare Tunnel +ready' <<<"$output" || { printf '%s\n' 'setup test: cloudflared status is wrong' >&2; exit 1; }
grep -Eq 'Wrangler +ready' <<<"$output" || { printf '%s\n' 'setup test: Wrangler status is wrong' >&2; exit 1; }
[ "$auth_before" = "$(file_hash "$home/.pi/agent/auth.json")" ] || {
  printf '%s\n' 'setup test: status check modified Pi auth' >&2
  exit 1
}

# A local API-key entry shadows the runtime environment and must fail --check.
printf '%s\n' '{"openai-codex":{"type":"oauth","refresh":"must-survive"},"deepseek":{"type":"api_key","key":"old-local-key"}}' >"$home/.pi/agent/auth.json"
conflict_before=$(file_hash "$home/.pi/agent/auth.json")
set +e
conflict_output=$("$repo_root/bin/nix-config-setup" --check)
conflict_status=$?
set -e
[ "$conflict_status" -eq 1 ] || { printf '%s\n' 'setup test: shadowing key did not fail check' >&2; exit 1; }
grep -Eq 'Pi API shadowing +deepseek' <<<"$conflict_output" || { printf '%s\n' 'setup test: shadowing key was not reported' >&2; exit 1; }
[ "$conflict_before" = "$(file_hash "$home/.pi/agent/auth.json")" ] || { printf '%s\n' 'setup test: conflict check modified Pi auth' >&2; exit 1; }
printf '%s\n' '{"openai-codex":{"type":"oauth","refresh":"must-survive"}}' >"$home/.pi/agent/auth.json"
auth_before=$(file_hash "$home/.pi/agent/auth.json")

# The wizard preserves a valid reference and auto-discovers conventionally
# named items without asking for IDs, field names, environment variables, or an editor.
cat >"$home/.config/proton-pass/pi.env" <<'EOF_PARTIAL'
DEEPSEEK_API_KEY=pass://share-dev/item-deepseek/API%20Key
EOF_PARTIAL
guided_output=$(run_pty '')
grep -Fq 'DeepSeek: existing reference is ready.' <<<"$guided_output" || { printf '%s\n' 'setup test: existing key was not preserved' >&2; exit 1; }
grep -Fq 'Gemini: found and verified llm-gemini.' <<<"$guided_output" || { printf '%s\n' 'setup test: Gemini was not auto-discovered' >&2; exit 1; }
grep -Fq 'Moonshot: found and verified llm-moonshot.' <<<"$guided_output" || { printf '%s\n' 'setup test: Moonshot was not auto-discovered' >&2; exit 1; }
grep -Fxq 'DEEPSEEK_API_KEY=pass://share-dev/item-deepseek/API%20Key' "$home/.config/proton-pass/pi.env" || exit 1
grep -Fxq 'GEMINI_API_KEY=pass://share-dev/item-gemini/API%20Key' "$home/.config/proton-pass/pi.env" || exit 1
grep -Fxq 'MOONSHOT_API_KEY=pass://share-dev/item-moonshot/API%20Key' "$home/.config/proton-pass/pi.env" || exit 1
[ "$(file_mode "$home/.config/proton-pass/pi.env")" = 600 ] || { printf '%s\n' 'setup test: reference mode is not 600' >&2; exit 1; }
[ "$auth_before" = "$(file_hash "$home/.pi/agent/auth.json")" ] || { printf '%s\n' 'setup test: wizard modified Pi auth' >&2; exit 1; }
! grep -q '^nvim ' "$logfile" || { printf '%s\n' 'setup test: wizard opened an editor' >&2; exit 1; }

# Missing optional providers can be skipped gracefully; ready providers remain.
grep -v '^MOONSHOT_API_KEY=' "$home/.config/proton-pass/pi.env" >"$home/.config/proton-pass/pi.env.tmp"
mv "$home/.config/proton-pass/pi.env.tmp" "$home/.config/proton-pass/pi.env"
chmod 600 "$home/.config/proton-pass/pi.env"
export MOCK_MISSING_MOONSHOT=1
skipped_output=$(run_pty $'s\n')
unset MOCK_MISSING_MOONSHOT
grep -Fq 'Moonshot API key       skipped for now' <<<"$skipped_output" || { printf '%s\n' 'setup test: optional skip was not summarized' >&2; exit 1; }
! grep -q '^MOONSHOT_API_KEY=' "$home/.config/proton-pass/pi.env" || { printf '%s\n' 'setup test: skipped key was written' >&2; exit 1; }
grep -q '^GEMINI_API_KEY=' "$home/.config/proton-pass/pi.env" || { printf '%s\n' 'setup test: ready key was lost after skip' >&2; exit 1; }

# Missing account state is handled inside the wizard: direct values for Git,
# and each service's own login command for authentication.
rm -f "$home/.pi/agent/auth.json" "$home/.config/git/identity" \
  "$home/.cloudflared/cert.pem" "$state/gh" "$state/wrangler"
account_input=$'s\n\nWizard User\n\nwizard@example.com\n\ny\ny\n'
account_output=$(run_pty "$account_input")
grep -Fq 'Pi account login       skipped for now' <<<"$account_output" || { printf '%s\n' 'setup test: Pi login skip was not summarized' >&2; exit 1; }
grep -Fq 'Git identity           ready (Wizard User <wizard@example.com>)' <<<"$account_output" || { printf '%s\n' 'setup test: Git identity was not collected' >&2; exit 1; }
[ -L "$home/.config/git/config" ] || { printf '%s\n' 'setup test: managed Git config symlink was replaced' >&2; exit 1; }
[ "$(git config --file "$home/.config/git/identity" user.name)" = 'Wizard User' ] || { printf '%s\n' 'setup test: Git name was not written to the identity include' >&2; exit 1; }
[ "$(git config --file "$home/.config/git/identity" user.email)" = 'wizard@example.com' ] || { printf '%s\n' 'setup test: Git email was not written to the identity include' >&2; exit 1; }
grep -Fq 'GitHub CLI             ready' <<<"$account_output" || { printf '%s\n' 'setup test: GitHub login was not completed' >&2; exit 1; }
grep -Fq 'Cloudflare Tunnel      ready' <<<"$account_output" || { printf '%s\n' 'setup test: cloudflared login was not completed' >&2; exit 1; }
grep -Fq 'Wrangler               ready' <<<"$account_output" || { printf '%s\n' 'setup test: Wrangler login was not completed' >&2; exit 1; }
grep -Fq 'gh auth login' "$logfile" || { printf '%s\n' 'setup test: GitHub login command did not run' >&2; exit 1; }
grep -Fq 'cloudflared tunnel login' "$logfile" || { printf '%s\n' 'setup test: cloudflared login command did not run' >&2; exit 1; }
grep -Fq 'wrangler login' "$logfile" || { printf '%s\n' 'setup test: Wrangler login command did not run' >&2; exit 1; }
printf '%s\n' '{"openai-codex":{"type":"oauth","refresh":"must-survive"}}' >"$home/.pi/agent/auth.json"
auth_before=$(file_hash "$home/.pi/agent/auth.json")

# A missing optional CLI is summarized rather than blocking unrelated setup.
minimalbin="$workdir/minimal-bin"
mkdir -p "$minimalbin"
for tool in bash cat chmod git grep jq keyctl mkdir mktemp mv node python3 rm tail touch uname; do
  tool_path=$(type -a -p "$tool" 2>/dev/null | grep -v '/intercepted-commands/' | head -n 1 || true)
  [ -z "$tool_path" ] || ln -s "$tool_path" "$minimalbin/$tool"
done
rm -f "$mockbin/wrangler"
missing_tool_output=$(PATH="$mockbin:$minimalbin" run_pty '')
grep -Fq 'Wrangler               unavailable; Wrangler is not installed' <<<"$missing_tool_output" || {
  printf '%s\n' 'setup test: missing optional CLI was not handled gracefully' >&2
  exit 1
}

# Status mode reports a missing runtime dependency without attempting to
# resolve references through an unavailable executable.
rm -f "$minimalbin/node"
: >"$logfile"
set +e
missing_node_output=$(PATH="$mockbin:$minimalbin" "$repo_root/bin/nix-config-setup" --check 2>&1)
missing_node_status=$?
set -e
[ "$missing_node_status" -eq 1 ] || { printf '%s\n' 'setup test: missing Node.js did not fail status check' >&2; exit 1; }
grep -Fq 'not checked; Node.js is unavailable' <<<"$missing_node_output" || { printf '%s\n' 'setup test: missing Node.js was not reported' >&2; exit 1; }
! grep -q 'pass-cli run' "$logfile" || { printf '%s\n' 'setup test: status check invoked missing Node.js through Proton Pass' >&2; exit 1; }

# Invalid placeholders fail before pass-cli resolution and remain a status report.
cat >"$home/.config/proton-pass/pi.env" <<'EOF_PLACEHOLDER'
DEEPSEEK_API_KEY=pass://REPLACE_SHARE_ID/item/API%20Key
EOF_PLACEHOLDER
: >"$logfile"
set +e
invalid_output=$("$repo_root/bin/nix-config-setup" --check 2>&1)
invalid_status=$?
set -e
[ "$invalid_status" -eq 1 ] || { printf '%s\n' 'setup test: placeholder did not fail check' >&2; exit 1; }
grep -Eq 'Pi API references +invalid' <<<"$invalid_output" || { printf '%s\n' 'setup test: invalid file was not reported' >&2; exit 1; }
! grep -q 'pass-cli run' "$logfile" || { printf '%s\n' 'setup test: invalid reference reached Proton Pass' >&2; exit 1; }

# Symlinks are rejected without aborting the rest of the status report.
rm -f "$home/.config/proton-pass/pi.env"
printf '%s\n' 'DEEPSEEK_API_KEY=pass://share/item/API%20Key' >"$home/.config/proton-pass/pi.env.target"
ln -s pi.env.target "$home/.config/proton-pass/pi.env"
set +e
symlink_output=$("$repo_root/bin/nix-config-setup" --check 2>&1)
symlink_status=$?
set -e
[ "$symlink_status" -eq 1 ] || { printf '%s\n' 'setup test: symlink did not fail check' >&2; exit 1; }
grep -Eq 'Pi API references +invalid' <<<"$symlink_output" || { printf '%s\n' 'setup test: symlink was not reported' >&2; exit 1; }
! grep -Fq 'ERROR:' <<<"$symlink_output" || { printf '%s\n' 'setup test: symlink aborted status reporting' >&2; exit 1; }

printf '%s\n' 'setup test: PASSED (automatic discovery, optional skips, account status, and OAuth preservation)'
