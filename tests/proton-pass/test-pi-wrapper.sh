#!/usr/bin/env bash
set -euo pipefail

repo_root=${BOOTSTRAP_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
python3_bin=$(PATH="/usr/bin:/bin:$PATH" command -v python3)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
home="$workdir/home"
realbin="$workdir/realbin"
passbin="$workdir/passbin"
supportbin="$workdir/supportbin"
logfile="$workdir/commands.log"
mkdir -p "$home/.local/bin" "$home/.config/proton-pass" "$home/.pi/agent" "$realbin" "$passbin" "$supportbin"
for command_name in bash cat chmod env grep rm sha256sum uname; do
  ln -s "$(command -v "$command_name")" "$supportbin/$command_name"
done
: >"$logfile"
cp "$repo_root/bin/pi" "$home/.local/bin/pi"
cp "$repo_root/bin/proton-pass-pi-env" "$home/.local/bin/proton-pass-pi-env"
chmod +x "$home/.local/bin/pi" "$home/.local/bin/proton-pass-pi-env"

cat >"$realbin/pi" <<'EOF_PI'
#!/usr/bin/env bash
tty_state=''
for fd in 0 1 2; do
  if [ -t "$fd" ]; then tty_state+='1'; else tty_state+='0'; fi
done
printf 'real-pi %s tty=%s key=%s\n' "$*" "$tty_state" "${DEEPSEEK_API_KEY:-no-api-key}" >>"$TEST_LOG"
printf '%s\n' "${DEEPSEEK_API_KEY:-no-api-key}"
EOF_PI
chmod +x "$realbin/pi"

cat >"$passbin/pass-cli" <<'EOF_PASS'
#!/usr/bin/env bash
set -euo pipefail
printf 'pass-cli %s\n' "$*" >>"$TEST_LOG"
[ "${1:-}" = run ] || exit 2
shift
[ "${1:-}" = --env-file ] || exit 2
[ -f "${2:-}" ] || exit 2
shift 2
[ "${1:-}" = -- ] || exit 2
shift
[ "${1:-}" = bash ] || exit 2
printf "export DEEPSEEK_API_KEY='resolved-test-key'\\n"
EOF_PASS
chmod +x "$passbin/pass-cli"

export HOME="$home"
export XDG_CONFIG_HOME="$home/.config"
export TEST_LOG="$logfile"
export PATH="$home/.local/bin:$realbin:$passbin:$supportbin"

# With no reference file, Pi starts normally and Proton Pass is not contacted.
output=$(pi --version)
[ "$output" = no-api-key ] || { printf '%s\n' 'pi wrapper test: direct launch output is wrong' >&2; exit 1; }
! grep -q '^pass-cli ' "$logfile" || { printf '%s\n' 'pi wrapper test: Pass ran without a reference file' >&2; exit 1; }
: >"$logfile"

cat >"$home/.config/proton-pass/pi.env" <<'EOF_ENV'
DEEPSEEK_API_KEY=pass://share/item/API_KEY
EOF_ENV
chmod 600 "$home/.config/proton-pass/pi.env"
printf '%s\n' '{"openai-codex":{"type":"oauth","refresh":"preserve-me"}}' >"$home/.pi/agent/auth.json"
chmod 600 "$home/.pi/agent/auth.json"
auth_before=$(sha256sum "$home/.pi/agent/auth.json")

# A configured reference file resolves the Pass environment before Pi starts.
output=$(pi hello)
[ "$output" = resolved-test-key ] || { printf '%s\n' 'pi wrapper test: Pass environment was not delivered' >&2; exit 1; }
grep -Fq "pass-cli run --env-file $home/.config/proton-pass/pi.env -- bash -c" "$logfile" || {
  printf '%s\n' 'pi wrapper test: pass-cli resolution arguments are wrong' >&2
  exit 1
}

# Regression: the real Pi must inherit the terminal's three descriptors, not
# the pipes pass-cli gives to its own child command.
: >"$logfile"
"$python3_bin" - "$home/.local/bin/pi" <<'PY'
import errno
import os
import pty
import sys

pid, master_fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], "pty"])
while True:
    try:
        if not os.read(master_fd, 1024):
            break
    except OSError as error:
        if error.errno == errno.EIO:
            break
        raise
_, status = os.waitpid(pid, 0)
if status != 0:
    raise SystemExit(f"PTY Pi launch failed with status {status}")
PY
grep -Fq 'real-pi pty tty=111 key=resolved-test-key' "$logfile" || {
  printf '%s\n' 'pi wrapper test: Pi did not receive TTY stdin/stdout/stderr and Pass key' >&2
  exit 1
}
[ "$auth_before" = "$(sha256sum "$home/.pi/agent/auth.json")" ] || {
  printf '%s\n' 'pi wrapper test: auth.json was modified' >&2
  exit 1
}
: >"$logfile"

# OAuth-only bypass never invokes Proton Pass.
output=$(PI_SKIP_PROTON_PASS=1 pi oauth-only)
[ "$output" = no-api-key ] || { printf '%s\n' 'pi wrapper test: OAuth-only bypass is wrong' >&2; exit 1; }
! grep -q '^pass-cli ' "$logfile" || { printf '%s\n' 'pi wrapper test: bypass invoked pass-cli' >&2; exit 1; }
: >"$logfile"

# A revoked Linux keyring automatically re-enters through proton-pass-session.
cat >"$supportbin/keyctl" <<'EOF_KEYCTL'
#!/usr/bin/env bash
[ "${1:-}" = show ] && [ "${TEST_KEYCTL_VALID:-0}" = 1 ]
EOF_KEYCTL
cat >"$supportbin/proton-pass-session" <<'EOF_SESSION'
#!/usr/bin/env bash
printf 'proton-pass-session %s\n' "$*" >>"$TEST_LOG"
export TEST_KEYCTL_VALID=1
exec "$@"
EOF_SESSION
chmod +x "$supportbin/keyctl" "$supportbin/proton-pass-session"
: >"$logfile"
output=$(TEST_KEYCTL_VALID=0 pi repaired-keyring)
[ "$output" = resolved-test-key ] || { printf '%s\n' 'pi wrapper test: keyring repair lost Pass environment' >&2; exit 1; }
grep -Fq "proton-pass-session $home/.local/bin/pi repaired-keyring" "$logfile" || {
  printf '%s\n' 'pi wrapper test: revoked keyring did not re-enter the session wrapper' >&2
  exit 1
}
rm -f "$supportbin/keyctl" "$supportbin/proton-pass-session"
: >"$logfile"

# A configured file fails closed when pass-cli is missing and directs setup repair.
rm -f "$passbin/pass-cli"
set +e
missing_output=$(pi 2>&1)
missing_status=$?
set -e
[ "$missing_status" -eq 127 ] || { printf '%s\n' 'pi wrapper test: missing pass-cli did not fail' >&2; exit 1; }
grep -Fq 'run bro auth' <<<"$missing_output" || {
  printf '%s\n' 'pi wrapper test: missing pass-cli did not direct setup repair' >&2
  exit 1
}
! grep -q '^real-pi ' "$logfile" || { printf '%s\n' 'pi wrapper test: missing pass-cli still started Pi' >&2; exit 1; }

printf '%s\n' 'pi wrapper test: PASSED (runtime injection, OAuth ownership, bypass, and fail-closed behavior)'
