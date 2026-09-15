#!/usr/bin/env bash
# Mocked stage-zero and activation tests. No network or real account is used.
#
# Both entry points are interactive, so every case drives real prompts through
# a pseudo-terminal rather than presetting environment variables.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
pty_run="$repo_root/tests/lib/pty-run"
system_bash=$(command -v bash)
install_script="$repo_root/scripts/install.sh"
bootstrap="$repo_root/scripts/bootstrap.sh"
for required in "$install_script" "$bootstrap" "$pty_run"; do
  [ -x "$required" ] || { printf 'bootstrap test: not executable: %s\n' "$required" >&2; exit 1; }
done

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
mockbin="$workdir/bin"
home="$workdir/home"
logfile="$workdir/commands.log"
activation="$workdir/activation"
destination="$home/src/nix-config"
mkdir -p "$mockbin" "$home/src"
: >"$logfile"
export HOME="$home"
export XDG_STATE_HOME="$home/.local/state"
export MOCK_LOG="$logfile"
export MOCK_BIN="$mockbin"
export MOCK_ACTIVATION="$activation"

# Isolate PATH so missing-tool cases are real within the test.
for command_name in bash sh env dirname mkdir cp chmod grep cat mktemp rm mv ps tty ls awk id sed python3 locale; do
  command_path=$(command -v "$command_name" 2>/dev/null || true)
  [ -z "$command_path" ] || ln -sf "$command_path" "$mockbin/$command_name"
done
for command_name in sha256sum shasum; do
  command_path=$(command -v "$command_name" 2>/dev/null || true)
  [ -z "$command_path" ] || ln -sf "$command_path" "$mockbin/$command_name"
done

command cat >"$mockbin/nix" <<'EOF_NIX'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix %s\n' "$*" >>"$MOCK_LOG"
[ "${1:-}" != --impure ] || shift
case "${1:-}" in
  shell)
    while [ "$#" -gt 0 ] && [ "$1" != --command ]; do shift; done
    [ "${1:-}" = --command ] || exit 1
    shift
    if [ "${1:-}" = git ] && ! command -v git >/dev/null 2>&1; then
      shift
      exec "$MOCK_GIT_STUB" "$@"
    fi
    exec "$@"
    ;;
  flake|eval) exit 0 ;;
  build)
    mkdir -p "$MOCK_ACTIVATION"
    cat >"$MOCK_ACTIVATION/activate" <<'EOF_ACTIVATE'
#!/usr/bin/env bash
printf 'activation\n' >>"$MOCK_LOG"
mkdir -p "$HOME/.nix-profile/bin" "$HOME/.config/tmux"
for managed in zsh tmux; do
  if [ ! -x "$HOME/.nix-profile/bin/$managed" ]; then
    printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.nix-profile/bin/$managed"
    chmod +x "$HOME/.nix-profile/bin/$managed"
  fi
done
: >"$HOME/.config/tmux/tmux.conf"
EOF_ACTIVATE
    chmod +x "$MOCK_ACTIVATION/activate"
    printf '%s\n' "$MOCK_ACTIVATION"
    ;;
  *) exit 0 ;;
esac
EOF_NIX

command cat >"$mockbin/uname" <<'EOF_UNAME'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${MOCK_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${MOCK_UNAME_M:-x86_64}" ;;
  *) exit 2 ;;
esac
EOF_UNAME

command cat >"$workdir/bootstrap.stub" <<'EOF_BOOTSTRAP'
#!/usr/bin/env bash
printf 'checkout-bootstrap args=%s\n' "$*" >>"$MOCK_LOG"
EOF_BOOTSTRAP

command cat >"$workdir/git.stub" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$MOCK_LOG"
if [ "${1:-}" = clone ]; then
  target=${3:?missing clone destination}
  mkdir -p "$target/.git" "$target/scripts"
  cp "$MOCK_BOOTSTRAP_STUB" "$target/scripts/bootstrap.sh"
  chmod +x "$target/scripts/bootstrap.sh"
elif [ "${1:-}" = -C ]; then
  shift 2
  case "${1:-}" in
    remote) [ "${2:-}" = get-url ] && printf '%s\n' 'https://github.com/hattajr/nix-config.git' ;;
    status|fetch|reset) ;;
  esac
fi
EOF_GIT

chmod +x "$mockbin/nix" "$mockbin/uname" "$workdir/git.stub" "$workdir/bootstrap.stub"
export MOCK_GIT_STUB="$workdir/git.stub"
export MOCK_BOOTSTRAP_STUB="$workdir/bootstrap.stub"

install_mock_git() { cp "$MOCK_GIT_STUB" "$mockbin/git"; chmod +x "$mockbin/git"; }
install_mock_git

# Answers are fed to the real prompts; the installer reads its terminal, never stdin.
run_install() {
  local answers=$1 script=${2:-$install_script}
  printf '%b' "$answers" | "$pty_run" env PATH="$mockbin" "$script"
}
run_bootstrap() {
  local answers=$1
  printf '%b' "$answers" | "$pty_run" env PATH="$mockbin" "$bootstrap" "$repo_root"
}
reset_destination() { rm -rf "$destination"; }

# --- installer safety -------------------------------------------------------

# Declining at the summary changes nothing at all.
: >"$logfile"
run_install 'n\n' >/dev/null
! grep -q '^git clone ' "$logfile" || { printf '%s\n' 'bootstrap test: decline reached clone' >&2; exit 1; }

# A failed Nix-installer download is reported directly and never piped to sh.
mv "$mockbin/nix" "$workdir/nix.stub"
printf '#!/usr/bin/env bash\nprintf "curl %%s\\n" "$*" >>"$MOCK_LOG"\nexit 22\n' >"$mockbin/curl"
chmod +x "$mockbin/curl"
: >"$logfile"
status=0
output=$(run_install 'y\ny\n' 2>&1) || status=$?
[ "$status" -ne 0 ] || { printf '%s\n' 'bootstrap test: failed installer download succeeded' >&2; exit 1; }
grep -Fq 'could not download the official Nix installer' <<<"$output" || {
  printf '%s\n' 'bootstrap test: failed download produced the wrong error' >&2; exit 1; }
! grep -q '^git clone ' "$logfile" || { printf '%s\n' 'bootstrap test: failed download reached clone' >&2; exit 1; }
rm -f "$mockbin/curl"

# The pinned checksum is verified before the downloaded installer is executed.
installer_fixture="$workdir/nix-installer.fixture"
printf '#!/usr/bin/env bash\nprintf "installer %%s\\n" "$*" >>"$MOCK_LOG"\nexit 1\n' >"$installer_fixture"
chmod +x "$installer_fixture"
if command -v sha256sum >/dev/null 2>&1; then
  installer_hash=$(sha256sum "$installer_fixture" | awk '{print $1}')
else
  installer_hash=$(shasum -a 256 "$installer_fixture" | awk '{print $1}')
fi
export MOCK_INSTALLER_FIXTURE="$installer_fixture"
command cat >"$mockbin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output=$2; break; fi
  shift
done
cp "$MOCK_INSTALLER_FIXTURE" "$output"
EOF_CURL
chmod +x "$mockbin/curl"

# The pin is a constant in the script, so a mismatch is tested on a patched copy
# rather than by exposing an override nobody should ever set.
mismatch_script="$workdir/install-mismatch.sh"
sed "s/^NIX_INSTALLER_SHA256=.*/NIX_INSTALLER_SHA256='0000000000000000000000000000000000000000000000000000000000000000'/" \
  "$install_script" >"$mismatch_script"
chmod +x "$mismatch_script"
: >"$logfile"
status=0
output=$(run_install 'y\ny\n' "$mismatch_script" 2>&1) || status=$?
[ "$status" -ne 0 ] || { printf '%s\n' 'bootstrap test: mismatched installer checksum succeeded' >&2; exit 1; }
grep -Fq 'Nix installer checksum mismatch' <<<"$output" || {
  printf '%s\n' 'bootstrap test: checksum mismatch produced the wrong error' >&2; exit 1; }
! grep -q '^installer ' "$logfile" || { printf '%s\n' 'bootstrap test: mismatched installer was executed' >&2; exit 1; }

# A matching checksum runs the official installer in unattended daemon mode.
matching_script="$workdir/install-matching.sh"
sed "s/^NIX_INSTALLER_SHA256=.*/NIX_INSTALLER_SHA256='$installer_hash'/" \
  "$install_script" >"$matching_script"
chmod +x "$matching_script"
: >"$logfile"
status=0
output=$(run_install 'y\ny\n' "$matching_script" 2>&1) || status=$?
[ "$status" -ne 0 ] || { printf '%s\n' 'bootstrap test: mocked daemon installer unexpectedly succeeded' >&2; exit 1; }
grep -Fq 'official multi-user Nix installer failed' <<<"$output" || {
  printf '%s\n' 'bootstrap test: daemon installer failure was not reported' >&2; exit 1; }
grep -Fq 'installer --daemon --yes' "$logfile" || {
  printf '%s\n' 'bootstrap test: verified installer was not invoked in daemon mode' >&2; exit 1; }
rm -f "$mockbin/curl"
unset MOCK_INSTALLER_FIXTURE
mv "$workdir/nix.stub" "$mockbin/nix"

# A single-user installation is discovered even when the invoking shell never
# sourced its profile, so no installer download is attempted.
profile_bin="$workdir/profile-bin"
mkdir -p "$profile_bin" "$home/.nix-profile/etc/profile.d"
mv "$mockbin/nix" "$profile_bin/nix"
printf 'PATH="%s:$PATH"\nexport PATH\n' "$profile_bin" >"$home/.nix-profile/etc/profile.d/nix.sh"
: >"$logfile"
reset_destination
output=$(run_install 'y\n')
grep -Fq 'Using the existing Nix installation' <<<"$output" || {
  printf '%s\n' 'bootstrap test: hidden single-user Nix was not reused' >&2; exit 1; }
! grep -q '^curl ' "$logfile" || { printf '%s\n' 'bootstrap test: hidden Nix reached installer download' >&2; exit 1; }
rm -f "$home/.nix-profile/etc/profile.d/nix.sh"
mv "$profile_bin/nix" "$mockbin/nix"

# --- stage zero hand-off ----------------------------------------------------

: >"$logfile"
reset_destination
run_install 'y\n' >/dev/null
grep -Fq "git clone https://github.com/hattajr/nix-config.git $destination.nix-config-install." "$logfile" || {
  printf '%s\n' 'bootstrap test: public HTTPS clone was not staged before finalizing' >&2; exit 1; }
grep -Fq "checkout-bootstrap args=$destination" "$logfile" || {
  printf '%s\n' 'bootstrap test: stage zero did not hand off the destination' >&2; exit 1; }
! grep -q '^gh ' "$logfile" || { printf '%s\n' 'bootstrap test: public clone invoked gh' >&2; exit 1; }

# Rerunning reuses a clean checkout rather than cloning again.
: >"$logfile"
run_install 'y\n' >/dev/null
! grep -q '^git clone ' "$logfile" || { printf '%s\n' 'bootstrap test: rerun recloned repository' >&2; exit 1; }
grep -Fq "git -C $destination remote get-url origin" "$logfile" || {
  printf '%s\n' 'bootstrap test: rerun did not verify repository origin' >&2; exit 1; }

# Missing Git uses an ephemeral nix shell; it never mutates a Nix profile.
rm -f "$mockbin/git"
: >"$logfile"
reset_destination
run_install 'y\n' >/dev/null
grep -Fq 'nix shell --accept-flake-config nixpkgs#git --command git clone' "$logfile" || {
  printf '%s\n' 'bootstrap test: missing Git did not use an ephemeral nix shell' >&2; exit 1; }
! grep -Fq 'nix profile' "$logfile" || { printf '%s\n' 'bootstrap test: stage zero mutated the Nix profile' >&2; exit 1; }
install_mock_git

# Platform comes from the machine alone; there is no override to type.
: >"$logfile"
reset_destination
output=$(MOCK_UNAME_M=aarch64 run_install 'y\n')
grep -Fq 'aarch64-linux' <<<"$output" || {
  printf '%s\n' 'bootstrap test: Linux ARM64 platform was not auto-detected' >&2; exit 1; }
: >"$logfile"
reset_destination
output=$(MOCK_UNAME_S=Darwin MOCK_UNAME_M=arm64 run_install 'y\n')
grep -Fq 'aarch64-darwin' <<<"$output" || {
  printf '%s\n' 'bootstrap test: Apple Silicon platform was not auto-detected' >&2; exit 1; }
status=0
MOCK_UNAME_M=mips run_install 'y\n' >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || { printf '%s\n' 'bootstrap test: unsupported platform unexpectedly succeeded' >&2; exit 1; }

# --- bootstrap activation ---------------------------------------------------

# Declining validates the checkout but never invokes Nix or activates.
: >"$logfile"
run_bootstrap 'n\n' >/dev/null
! grep -q '^nix build' "$logfile" || { printf '%s\n' 'bootstrap test: decline reached a Nix build' >&2; exit 1; }
! grep -q '^activation$' "$logfile" || { printf '%s\n' 'bootstrap test: decline still activated Home Manager' >&2; exit 1; }
[ ! -r "$home/.local/state/bro/checkout" ] || {
  printf '%s\n' 'bootstrap test: decline recorded a checkout' >&2; exit 1; }

# Approving builds, activates, and records the checkout; declining the shell
# prompt leaves the caller where they were.
: >"$logfile"
shell_log="$workdir/managed-shell.log"
: >"$shell_log"
export MOCK_SHELL_LOG="$shell_log"
run_bootstrap 'y\nn\n' >/dev/null
grep -q '^nix build ' "$logfile" || { printf '%s\n' 'bootstrap test: approval did not build activation' >&2; exit 1; }
grep -q '^activation$' "$logfile" || { printf '%s\n' 'bootstrap test: approval did not activate Home Manager' >&2; exit 1; }
[ -r "$home/.local/state/bro/checkout" ] || { printf '%s\n' 'bootstrap test: checkout state was not written' >&2; exit 1; }
[ ! -s "$shell_log" ] || { printf '%s\n' 'bootstrap test: declining the shell prompt still launched it' >&2; exit 1; }

# Accepting hands managed zsh the concrete terminal device, never the /dev/tty
# alias that leaves an attached tmux client unable to redraw.
command cat >"$home/.nix-profile/bin/zsh" <<'EOF_ZSH'
#!/usr/bin/env bash
[ "${1:-}" = -lic ] && exit 0
if printf '\r' >&0 2>/dev/null; then stdin_mode=read-write; else stdin_mode=read-only; fi
printf 'managed-tty=%s stdin-mode=%s\n' "$(tty)" "$stdin_mode" >>"$MOCK_SHELL_LOG"
EOF_ZSH
chmod +x "$home/.nix-profile/bin/zsh"
: >"$shell_log"
run_bootstrap 'y\ny\n' >/dev/null
grep -Eq '^managed-tty=/dev/.+ stdin-mode=read-write$' "$shell_log" || {
  printf '%s\n' 'bootstrap test: managed shell did not receive a read-write concrete terminal' >&2; exit 1; }
! grep -Eq '^managed-tty=/dev/tty ' "$shell_log" || {
  printf '%s\n' 'bootstrap test: managed shell received the /dev/tty alias' >&2; exit 1; }

# Both entry points refuse to run unattended rather than guessing an answer.
status=0
env PATH="$mockbin" NIX_CONFIG_TEST_NO_TTY=1 "$bootstrap" "$repo_root" >/dev/null 2>&1 </dev/null || status=$?
[ "$status" -ne 0 ] || { printf '%s\n' 'bootstrap test: headless bootstrap did not fail closed' >&2; exit 1; }

printf '%s\n' 'bootstrap test: PASSED (guided install, verified installer, platform detection, activation, managed shell, fail-closed)'
