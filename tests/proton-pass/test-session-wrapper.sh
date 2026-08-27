#!/usr/bin/env bash
set -euo pipefail

repo_root=${BOOTSTRAP_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
system_path=$PATH
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
mockbin="$workdir/bin"
logfile="$workdir/commands.log"
mkdir -p "$mockbin"
: >"$logfile"

cat >"$mockbin/uname" <<'EOF_UNAME'
#!/usr/bin/env bash
printf '%s\n' "${TEST_UNAME:-Linux}"
EOF_UNAME
cat >"$mockbin/keyctl" <<'EOF_KEYCTL'
#!/usr/bin/env bash
printf 'keyctl %s\n' "$*" >>"$TEST_LOG"
case "${1:-}" in
  show) [ "${TEST_KEYCTL_VALID:-0}" = 1 ] ;;
  new_session) exit 0 ;;
  *) exit 2 ;;
esac
EOF_KEYCTL
cat >"$mockbin/target" <<'EOF_TARGET'
#!/usr/bin/env bash
printf 'target args=%s\n' "$*" >>"$TEST_LOG"
EOF_TARGET
chmod +x "$mockbin"/*

export TEST_LOG="$logfile"
export PATH="$mockbin:$system_path"

# A revoked Linux session gets a fresh kernel keyring before the target starts.
TEST_UNAME=Linux TEST_KEYCTL_VALID=0 "$repo_root/bin/proton-pass-session" target hello
grep -Fq 'keyctl show' "$logfile" || { printf '%s\n' 'session wrapper test: Linux did not inspect keyring' >&2; exit 1; }
grep -Fq 'keyctl new_session proton-pass' "$logfile" || {
  printf '%s\n' 'session wrapper test: revoked Linux keyring was not replaced' >&2
  exit 1
}
grep -Fq 'target args=hello' "$logfile" || { printf '%s\n' 'session wrapper test: target did not run' >&2; exit 1; }

# A valid keyring is retained so existing Proton Pass keys stay reachable.
: >"$logfile"
TEST_UNAME=Linux TEST_KEYCTL_VALID=1 "$repo_root/bin/proton-pass-session" target valid
! grep -q 'keyctl new_session' "$logfile" || { printf '%s\n' 'session wrapper test: valid keyring was replaced' >&2; exit 1; }
grep -Fq 'target args=valid' "$logfile" || { printf '%s\n' 'session wrapper test: valid-session target did not run' >&2; exit 1; }

# macOS uses Keychain and executes directly.
: >"$logfile"
TEST_UNAME=Darwin TEST_KEYCTL_VALID=0 "$repo_root/bin/proton-pass-session" target mac
grep -Fq 'target args=mac' "$logfile" || { printf '%s\n' 'session wrapper test: macOS did not execute target directly' >&2; exit 1; }
! grep -q '^keyctl ' "$logfile" || { printf '%s\n' 'session wrapper test: macOS accessed Linux keyring' >&2; exit 1; }

printf '%s\n' 'session wrapper test: PASSED (revoked/valid Linux keyrings and macOS Keychain path)'
