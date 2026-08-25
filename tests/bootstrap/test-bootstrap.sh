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
export BOOTSTRAP_REPO_ROOT="$repo_root"
export MOCK_LOG="$logfile"
export MOCK_BIN="$mockbin"

# The bootstrap gets an isolated PATH so a Git binary supplied by the
# container cannot make a deliberately missing mocked tool appear present.
for command_name in bash env dirname mkdir chmod cp grep cat; do
  command_path=$(command -v "$command_name")
  ln -s "$command_path" "$mockbin/$command_name"
done

cat > "$mockbin/nix" <<'EOF_NIX'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix %s\n' "$*" >>"$MOCK_LOG"
case "${1:-}" in
  profile)
    if printf '%s\n' "$*" | grep -Fq 'nixpkgs#git'; then
      cp "$MOCK_GIT_STUB" "$MOCK_BIN/git"
      chmod +x "$MOCK_BIN/git"
    fi
    exit 0
    ;;
  shell)
    while [ "$#" -gt 0 ] && [ "$1" != --command ]; do shift; done
    [ "$1" = --command ] || exit 1
    shift
    exec "$@"
    ;;
  flake|eval) exit 0 ;;
  build)
    mkdir -p "$MOCK_ACTIVATION"
    cat > "$MOCK_ACTIVATION/activate" <<'EOF_ACTIVATE'
#!/usr/bin/env bash
printf 'activation\n' >>"$MOCK_LOG"
EOF_ACTIVATE
    chmod +x "$MOCK_ACTIVATION/activate"
    printf '%s\n' "$MOCK_ACTIVATION"
    ;;
  *) exit 0 ;;
esac
EOF_NIX

cat > "$workdir/git.stub" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$MOCK_LOG"
if [ "${1:-}" = clone ]; then
  destination=${3:?missing clone destination}
  mkdir -p "$destination/.git"
  printf '[remote "origin"]\n\turl = https://github.com/hattajr/nix-config.git\n' >"$destination/.git/config"
elif [ "${1:-}" = -C ] && [ "${3:-}" = remote ] && [ "${4:-}" = get-url ]; then
  printf '%s\n' 'https://github.com/hattajr/nix-config.git'
fi
EOF_GIT

cat > "$mockbin/age-keygen" <<'EOF_AGE'
#!/usr/bin/env bash
set -euo pipefail
printf 'age-keygen %s\n' "$*" >>"$MOCK_LOG"
if [ "${1:-}" = -o ]; then
  printf '%s\n' 'mock-age-private-key' >"${2:?missing output path}"
  exit 0
fi
[ "${1:-}" = -y ] || exit 0
[ -s "${2:-}" ]
printf '%s\n' 'age1mockrecipient'
EOF_AGE
chmod +x "$mockbin/nix" "$mockbin/age-keygen" "$workdir/git.stub"
export MOCK_GIT_STUB="$workdir/git.stub"

install_mock_tool() {
  cp "$workdir/$1.stub" "$mockbin/$1"
  chmod +x "$mockbin/$1"
}

run_bootstrap() {
  PATH="$mockbin" "$bootstrap" "$@"
}

install_mock_tool git
printf '%s\n' 'mock-age-private-key' >"$home/.config/sops/age/keys.txt"

# Missing host must fail before authentication or clone.
if printf '\n' | NIX_CONFIG_HOST= run_bootstrap >/dev/null 2>&1; then
  printf '%s\n' 'bootstrap test: missing host unexpectedly succeeded' >&2
  exit 1
fi
! grep -q 'clone' "$logfile" || { printf '%s\n' 'bootstrap test: missing host reached clone' >&2; exit 1; }
: >"$logfile"

# Public HTTPS cloning does not require GitHub authentication or gh.
printf 'n\n' | run_bootstrap latte "$home/src/public-clone" >/dev/null
[ -d "$home/src/public-clone/.git" ] || { printf '%s\n' 'bootstrap test: public clone did not occur' >&2; exit 1; }
! grep -q '^gh ' "$logfile" || { printf '%s\n' 'bootstrap test: public clone invoked gh' >&2; exit 1; }
grep -q 'git clone https://github.com/hattajr/nix-config.git' "$logfile" || {
  printf '%s\n' 'bootstrap test: public HTTPS clone URL was not used' >&2
  exit 1
}
: >"$logfile"

# Missing Git installs only Git, without replacing an existing package.
rm -f "$mockbin/git"
printf 'n\n' | run_bootstrap latte "$home/src/missing-git" >/dev/null
[ -x "$mockbin/git" ] || {
  printf '%s\n' 'bootstrap test: missing Git was not made available after profile install' >&2
  exit 1
}
[ -d "$home/src/missing-git/.git" ] || { printf '%s\n' 'bootstrap test: missing-Git clone did not occur' >&2; exit 1; }
grep -Fxq 'nix profile install --accept-flake-config nixpkgs#git' "$logfile" || {
  printf '%s\n' 'bootstrap test: missing-Git path did not install exactly Git' >&2
  exit 1
}
: >"$logfile"

# Existing Git does not mutate the Nix profile.
printf 'n\n' | run_bootstrap latte "$home/src/existing-git" >/dev/null
[ -d "$home/src/existing-git/.git" ] || { printf '%s\n' 'bootstrap test: existing-Git clone did not occur' >&2; exit 1; }
! grep -Fq 'nix profile install' "$logfile" || {
  printf '%s\n' 'bootstrap test: existing Git unexpectedly triggered profile install' >&2
  exit 1
}
: >"$logfile"

# A missing age identity is generated after Nix is available. Generation must
# create a mode-700 parent and mode-600 key, print only the public recipient,
# return failure deliberately, and stop before clone.
generated_identity="$home/generated/sops/age/keys.txt"
set +e
identity_output=$(SOPS_AGE_KEY_FILE="$generated_identity" run_bootstrap latte "$home/src/identity-generation" </dev/null 2>&1)
identity_status=$?
set -e
[ "$identity_status" -ne 0 ] || {
  printf '%s\n' 'bootstrap test: identity generation did not stop the bootstrap' >&2
  exit 1
}
grep -Fq 'public age recipient: age1mockrecipient' <<<"$identity_output" || {
  printf '%s\n' 'bootstrap test: generated public recipient was not reported' >&2
  printf '%s\n' "$identity_output" >&2
  exit 1
}
grep -Fq 'ACTION REQUIRED: add this recipient to the SOPS policy' <<<"$identity_output" || {
  printf '%s\n' 'bootstrap test: identity generation did not report the intentional action' >&2
  exit 1
}
! grep -Fq 'nix-bootstrap: ERROR:' <<<"$identity_output" || {
  printf '%s\n' 'bootstrap test: intentional SOPS pause was reported as an error' >&2
  exit 1
}
[ "$(stat -c '%a' "$(dirname "$generated_identity")")" = 700 ] || {
  printf '%s\n' 'bootstrap test: generated identity directory permissions were not 700' >&2
  exit 1
}
[ "$(stat -c '%a' "$generated_identity")" = 600 ] || {
  printf '%s\n' 'bootstrap test: generated identity permissions were not 600' >&2
  exit 1
}
! grep -Fq 'mock-age-private-key' <<<"$identity_output" || {
  printf '%s\n' 'bootstrap test: generated private key leaked into output' >&2
  exit 1
}
! grep -Fq 'mock-age-private-key' "$logfile" || {
  printf '%s\n' 'bootstrap test: generated private key leaked into command logs' >&2
  exit 1
}
! grep -q '^git clone' "$logfile" || { printf '%s\n' 'bootstrap test: identity generation reached clone' >&2; exit 1; }
[ ! -e "$home/src/identity-generation" ] || { printf '%s\n' 'bootstrap test: identity generation created a checkout destination' >&2; exit 1; }
: >"$logfile"

# A valid identity may clone the public repository, then skip activation when
# the user declines. The private key contents must never appear in logs.
export MOCK_ACTIVATION="$workdir/activation"
printf 'n\n' | run_bootstrap latte "$home/src/nix-config" >/dev/null
[ -d "$home/src/nix-config/.git" ] || { printf '%s\n' 'bootstrap test: clone did not occur' >&2; exit 1; }
! grep -Fq 'mock-age-private-key' "$logfile" || { printf '%s\n' 'bootstrap test: private key leaked into logs' >&2; exit 1; }
[ ! -e "$workdir/activation/activate" ] || { printf '%s\n' 'bootstrap test: activation ran after decline' >&2; exit 1; }

# Rerunning against the existing checkout must not clone again.
: >"$logfile"
printf 'n\n' | run_bootstrap latte "$home/src/nix-config" >/dev/null
! grep -q 'git clone' "$logfile" || { printf '%s\n' 'bootstrap test: rerun recloned repository' >&2; exit 1; }

printf '%s\n' 'bootstrap test: PASSED (public clone, Git availability, host/identity gates, permissions, clone stop, rerun, and private-key log safety)'
