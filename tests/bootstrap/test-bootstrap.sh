#!/usr/bin/env bash
# Mocked bootstrap tests. Run this script inside an ephemeral container.
set -euo pipefail

repo_root=${BOOTSTRAP_REPO_ROOT:-$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
bootstrap="$repo_root/scripts/bootstrap.sh"
[ -x "$bootstrap" ] || { printf '%s\n' 'bootstrap test: script is not executable' >&2; exit 1; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
mockbin="$workdir/bin"
home="$workdir/home"
logfile="$workdir/commands.log"
mkdir -p "$mockbin" "$home/.config/sops/age" "$home/src"
: >"$logfile"
export HOME="$home"
export PATH="$mockbin:$PATH"
export BOOTSTRAP_REPO_ROOT="$repo_root"
export MOCK_LOG="$logfile"

cat > "$mockbin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix %s\n' "$*" >>"$MOCK_LOG"
case "${1:-}" in
  profile) exit 0 ;;
  shell) exec age-keygen "$@" ;;
  flake|eval) exit 0 ;;
  build)
    mkdir -p "$MOCK_ACTIVATION"
    cat > "$MOCK_ACTIVATION/activate" <<'ACTIVATE'
#!/usr/bin/env bash
printf 'activation\n' >>"$MOCK_LOG"
ACTIVATE
    chmod +x "$MOCK_ACTIVATION/activate"
    printf '%s\n' "$MOCK_ACTIVATION"
    ;;
  *) exit 0 ;;
esac
EOF

cat > "$mockbin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$MOCK_LOG"
if [ "${1:-}" = clone ]; then
  destination=${3:?missing clone destination}
  mkdir -p "$destination/.git"
  printf '[remote "origin"]\n\turl = git@github.com:hattajr/nix-config.git\n' >"$destination/.git/config"
elif [ "${1:-}" = -C ] && [ "${3:-}" = remote ] && [ "${4:-}" = get-url ]; then
  printf '%s\n' 'git@github.com:hattajr/nix-config.git'
fi
EOF

cat > "$mockbin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$MOCK_LOG"
if [ "${MOCK_GH_AUTH:-yes}" = no ] && [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 1
fi
exit 0
EOF

cat > "$mockbin/age-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'age-keygen %s\n' "$*" >>"$MOCK_LOG"
[ "${1:-}" = -y ] || exit 0
[ -s "${2:-}" ]
printf '%s\n' 'age1mockrecipient'
EOF
chmod +x "$mockbin"/*

printf '%s\n' 'mock-age-private-key' >"$home/.config/sops/age/keys.txt"

# Missing host must fail before authentication or clone.
if printf '\n' | NIX_CONFIG_HOST= "$bootstrap" >/dev/null 2>&1; then
  printf '%s\n' 'bootstrap test: missing host unexpectedly succeeded' >&2
  exit 1
fi
! grep -q 'clone' "$logfile" || { printf '%s\n' 'bootstrap test: missing host reached clone' >&2; exit 1; }
: >"$logfile"

# Missing GitHub authentication must fail before clone.
if MOCK_GH_AUTH=no "$bootstrap" latte "$home/src/auth-failure" </dev/null >/dev/null 2>&1; then
  printf '%s\n' 'bootstrap test: missing GitHub auth unexpectedly succeeded' >&2
  exit 1
fi
! grep -q 'git clone' "$logfile" || { printf '%s\n' 'bootstrap test: auth failure reached clone' >&2; exit 1; }
: >"$logfile"

# A missing externally provisioned age identity must fail before GitHub auth or clone.
if SOPS_AGE_KEY_FILE="$home/missing-identity" "$bootstrap" latte "$home/src/identity-failure" </dev/null >/dev/null 2>&1; then
  printf '%s\n' 'bootstrap test: missing age identity unexpectedly succeeded' >&2
  exit 1
fi
! grep -q 'git clone' "$logfile" || { printf '%s\n' 'bootstrap test: identity failure reached clone' >&2; exit 1; }
: >"$logfile"

# A valid identity and authenticated GitHub CLI may clone, then skip activation
# when the user declines. The private key contents must never appear in logs.
export MOCK_ACTIVATION="$workdir/activation"
printf 'n\n' | "$bootstrap" latte "$home/src/nix-config" >/dev/null
[ -d "$home/src/nix-config/.git" ] || { printf '%s\n' 'bootstrap test: clone did not occur' >&2; exit 1; }
! grep -Fq 'mock-age-private-key' "$logfile" || { printf '%s\n' 'bootstrap test: private key leaked into logs' >&2; exit 1; }
[ ! -e "$workdir/activation/activate" ] || { printf '%s\n' 'bootstrap test: activation ran after decline' >&2; exit 1; }

# Rerunning against the existing checkout must not clone again.
: >"$logfile"
printf 'n\n' | "$bootstrap" latte "$home/src/nix-config" >/dev/null
! grep -q 'git clone' "$logfile" || { printf '%s\n' 'bootstrap test: rerun recloned repository' >&2; exit 1; }

printf '%s\n' 'bootstrap test: PASSED (host/auth/identity gates, clone, rerun, and log safety)'
