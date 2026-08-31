#!/usr/bin/env bash
# Mocked stage-zero and activation tests. No network or real account is used.
set -euo pipefail

repo_root=${BOOTSTRAP_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
python3_path=$(command -v python3)
system_bash=$(command -v bash)
install_script="$repo_root/scripts/install.sh"
bootstrap="$repo_root/scripts/bootstrap.sh"
[ -x "$install_script" ] || { printf '%s\n' 'bootstrap test: install script is not executable' >&2; exit 1; }
[ -x "$bootstrap" ] || { printf '%s\n' 'bootstrap test: bootstrap script is not executable' >&2; exit 1; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
mockbin="$workdir/bin"
home="$workdir/home"
logfile="$workdir/commands.log"
activation="$workdir/activation"
mkdir -p "$mockbin" "$home/src"
: >"$logfile"
export HOME="$home"
export XDG_STATE_HOME="$home/.local/state"
export MOCK_LOG="$logfile"
export MOCK_BIN="$mockbin"
export MOCK_ACTIVATION="$activation"

# Isolate PATH so missing-tool cases are real within the test.
for command_name in bash env dirname mkdir cp chmod grep cat mktemp rm mv ps tty; do
  command_path=$(command -v "$command_name")
  ln -s "$command_path" "$mockbin/$command_name"
done

cat >"$mockbin/nix" <<'EOF_NIX'
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
if [ ! -x "$HOME/.nix-profile/bin/zsh" ]; then
  cat >"$HOME/.nix-profile/bin/zsh" <<'EOF_ZSH'
#!/usr/bin/env bash
exit 0
EOF_ZSH
  chmod +x "$HOME/.nix-profile/bin/zsh"
fi
if [ ! -x "$HOME/.nix-profile/bin/tmux" ]; then
  cat >"$HOME/.nix-profile/bin/tmux" <<'EOF_TMUX'
#!/usr/bin/env bash
exit 0
EOF_TMUX
  chmod +x "$HOME/.nix-profile/bin/tmux"
fi
: >"$HOME/.config/tmux/tmux.conf"
EOF_ACTIVATE
    chmod +x "$MOCK_ACTIVATION/activate"
    printf '%s\n' "$MOCK_ACTIVATION"
    ;;
  *) exit 0 ;;
esac
EOF_NIX

cat >"$mockbin/uname" <<'EOF_UNAME'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${MOCK_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${MOCK_UNAME_M:-x86_64}" ;;
  *) exit 2 ;;
esac
EOF_UNAME

cat >"$workdir/bootstrap.stub" <<'EOF_BOOTSTRAP'
#!/usr/bin/env bash
printf 'checkout-bootstrap platform=%s args=%s\n' "${NIX_CONFIG_PLATFORM:-}" "$*" >>"$MOCK_LOG"
EOF_BOOTSTRAP

cat >"$workdir/git.stub" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$MOCK_LOG"
if [ "${1:-}" = clone ]; then
  destination=${3:?missing clone destination}
  mkdir -p "$destination/.git" "$destination/scripts"
  cp "$MOCK_BOOTSTRAP_STUB" "$destination/scripts/bootstrap.sh"
  chmod +x "$destination/scripts/bootstrap.sh"
elif [ "${1:-}" = -C ] && [ "${3:-}" = remote ] && [ "${4:-}" = get-url ]; then
  printf '%s\n' 'https://github.com/hattajr/nix-config.git'
fi
EOF_GIT

cat >"$mockbin/locale" <<'EOF_LOCALE'
#!/usr/bin/env bash
printf '%s\n' 'LANG=C.UTF-8' 'LC_CTYPE="C.UTF-8"' 'LC_ALL='
EOF_LOCALE
chmod +x "$mockbin/nix" "$mockbin/uname" "$mockbin/locale" "$workdir/git.stub" "$workdir/bootstrap.stub"
export MOCK_GIT_STUB="$workdir/git.stub"
export MOCK_BOOTSTRAP_STUB="$workdir/bootstrap.stub"
# Bootstrap validates its own checkout before activation, so Git is available
# for these mocked bootstrap paths.
cp "$MOCK_GIT_STUB" "$mockbin/git"
chmod +x "$mockbin/git"

install_mock_git() {
  cp "$MOCK_GIT_STUB" "$mockbin/git"
  chmod +x "$mockbin/git"
}

run_install() {
  PATH="$mockbin" "$install_script" "$@"
}

run_bootstrap() {
  PATH="$mockbin" "$bootstrap" "$@"
}

# Invalid platform overrides fail before Nix or activation work.
if NIX_CONFIG_PLATFORM=unsupported NIX_CONFIG_APPLY=yes run_bootstrap "$repo_root" >/dev/null 2>&1; then
  printf '%s\n' 'bootstrap test: unsupported platform unexpectedly succeeded' >&2
  exit 1
fi
! grep -q '^nix ' "$logfile" || { printf '%s\n' 'bootstrap test: invalid platform reached Nix' >&2; exit 1; }
: >"$logfile"

# A failed Nix-installer download is reported directly and never piped to sh.
mv "$mockbin/nix" "$workdir/nix.stub"
cat >"$mockbin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$MOCK_LOG"
exit 22
EOF_CURL
chmod +x "$mockbin/curl"
set +e
download_output=$(run_install "$home/src/download-failure" 2>&1)
download_status=$?
set -e
[ "$download_status" -ne 0 ] || { printf '%s\n' 'bootstrap test: failed installer download succeeded' >&2; exit 1; }
grep -Fq 'could not download the official Nix installer' <<<"$download_output" || {
  printf '%s\n' 'bootstrap test: failed download produced the wrong error' >&2
  exit 1
}
! grep -q '^git clone ' "$logfile" || { printf '%s\n' 'bootstrap test: failed download reached clone' >&2; exit 1; }
mv "$workdir/nix.stub" "$mockbin/nix"
rm -f "$mockbin/curl"
: >"$logfile"

# Explicit no validates the checkout but does not invoke Nix or activate.
NIX_CONFIG_APPLY=no run_bootstrap "$repo_root" >/dev/null
! grep -q '^nix ' "$logfile" || { printf '%s\n' 'bootstrap test: decline reached Nix' >&2; exit 1; }
! grep -q '^activation$' "$logfile" || { printf '%s\n' 'bootstrap test: decline still activated Home Manager' >&2; exit 1; }
if NIX_CONFIG_APPLY=invalid run_bootstrap "$repo_root" >/dev/null 2>&1; then
  printf '%s\n' 'bootstrap test: invalid apply preset unexpectedly succeeded' >&2
  exit 1
fi
: >"$logfile"

# Checkout validation also uses ephemeral Git on a fresh machine.
rm -f "$mockbin/git"
NIX_CONFIG_APPLY=no run_bootstrap "$repo_root" >/dev/null
grep -Fq 'nix shell --accept-flake-config nixpkgs#git --command git -C' "$logfile" || {
  printf '%s\n' 'bootstrap test: checkout validation did not use ephemeral Git' >&2
  exit 1
}
install_mock_git
: >"$logfile"

# Explicit ARM64 override builds and activates, then runs noninteractive health.
NIX_CONFIG_PLATFORM=aarch64-linux NIX_CONFIG_APPLY=yes \
  run_bootstrap "$repo_root" >/dev/null
grep -Fq 'homeConfigurations.aarch64-linux.activationPackage' "$logfile" || {
  printf '%s\n' 'bootstrap test: ARM64 override did not select the ARM output' >&2
  exit 1
}
grep -q '^nix build ' "$logfile" || { printf '%s\n' 'bootstrap test: approval did not build activation' >&2; exit 1; }
grep -q '^activation$' "$logfile" || { printf '%s\n' 'bootstrap test: approval did not activate Home Manager' >&2; exit 1; }
[ -r "$home/.local/state/bro/checkout" ] || { printf '%s\n' 'bootstrap test: checkout state was not written' >&2; exit 1; }

# A piped installer with a controlling PTY hands managed zsh the concrete
# terminal device, never the /dev/tty alias rejected by tmux.
mkdir -p "$home/.nix-profile/bin"
shell_log="$workdir/managed-shell.log"
cat >"$home/.nix-profile/bin/zsh" <<'EOF_ZSH'
#!/usr/bin/env bash
[ "${1:-}" = -lic ] && exit 0
printf 'managed-tty=%s\n' "$(tty)" >>"$MOCK_SHELL_LOG"
EOF_ZSH
chmod +x "$home/.nix-profile/bin/zsh"
export BOOTSTRAP_UNDER_TEST="$bootstrap" BOOTSTRAP_CHECKOUT="$repo_root" MOCK_SHELL_LOG="$shell_log" SYSTEM_BASH="$system_bash"
"$python3_path" <<'PY_PTY'
import errno
import os
import pty
import sys

pid, fd = pty.fork()
if pid == 0:
    os.environ.pop("NIX_CONFIG_APPLY", None)
    os.environ["PATH"] = os.environ["MOCK_BIN"]
    shell = os.environ["SYSTEM_BASH"]
    os.execv(shell, ["bash", "-c", 'printf "" | "$BOOTSTRAP_UNDER_TEST" "$BOOTSTRAP_CHECKOUT"'])
os.write(fd, b"\n")
while True:
    try:
        if not os.read(fd, 4096):
            break
    except OSError as error:
        if error.errno == errno.EIO:
            break
        raise
_, status = os.waitpid(pid, 0)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    sys.exit(1)
PY_PTY
grep -Eq '^managed-tty=/dev/.+' "$shell_log" || { printf '%s\n' 'bootstrap test: managed shell did not receive a concrete terminal' >&2; exit 1; }
! grep -Fxq 'managed-tty=/dev/tty' "$shell_log" || { printf '%s\n' 'bootstrap test: managed shell received the /dev/tty alias' >&2; exit 1; }

# An explicit shell opt-out never launches managed zsh.
: >"$shell_log"
NIX_CONFIG_APPLY=yes NIX_CONFIG_START_SHELL=no run_bootstrap "$repo_root" >/dev/null
[ ! -s "$shell_log" ] || { printf '%s\n' 'bootstrap test: shell opt-out launched managed shell' >&2; exit 1; }

# With no controlling terminal, explicit activation succeeds without launching a shell.
: >"$shell_log"
"$python3_path" <<'PY_NO_TTY'
import os
import subprocess
import sys

environment = os.environ.copy()
environment["NIX_CONFIG_APPLY"] = "yes"
environment["PATH"] = environment["MOCK_BIN"]
result = subprocess.run(
    [environment["BOOTSTRAP_UNDER_TEST"], environment["BOOTSTRAP_CHECKOUT"]],
    env=environment,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
    text=True,
)
if result.returncode != 0 or "Managed shell ready" not in result.stdout:
    sys.exit(1)

environment.pop("NIX_CONFIG_APPLY", None)
result = subprocess.run(
    [environment["BOOTSTRAP_UNDER_TEST"], environment["BOOTSTRAP_CHECKOUT"]],
    env=environment,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
    text=True,
)
if result.returncode == 0 or "No terminal available" not in result.stdout:
    sys.exit(1)
PY_NO_TTY
[ ! -s "$shell_log" ] || { printf '%s\n' 'bootstrap test: no-TTY bootstrap launched managed shell' >&2; exit 1; }
: >"$logfile"

# Stage zero auto-detects Linux x86, clones over public HTTPS, and passes the destination.
install_mock_git
destination="$home/src/public-clone"
run_install "$destination" >/dev/null
grep -Fq "git clone https://github.com/hattajr/nix-config.git $destination" "$logfile" || {
  printf '%s\n' 'bootstrap test: public HTTPS clone was not used' >&2
  exit 1
}
grep -Fq "checkout-bootstrap platform=x86_64-linux args=$destination" "$logfile" || {
  printf '%s\n' 'bootstrap test: stage zero did not hand off platform and destination' >&2
  exit 1
}
! grep -q '^gh ' "$logfile" || { printf '%s\n' 'bootstrap test: public clone invoked gh' >&2; exit 1; }
: >"$logfile"

# Missing Git uses an ephemeral nix shell; it never mutates a Nix profile.
rm -f "$mockbin/git"
missing_git_destination="$home/src/missing-git"
run_install "$missing_git_destination" >/dev/null
grep -Fq 'nix shell --accept-flake-config nixpkgs#git --command git clone' "$logfile" || {
  printf '%s\n' 'bootstrap test: missing Git did not use an ephemeral nix shell' >&2
  exit 1
}
! grep -Fq 'nix profile' "$logfile" || { printf '%s\n' 'bootstrap test: stage zero mutated the Nix profile' >&2; exit 1; }
: >"$logfile"

# Native ARM64 detection supports an Ubuntu UTM VM without a machine-specific target.
install_mock_git
arm_destination="$home/src/arm-platform"
MOCK_UNAME_M=aarch64 run_install "$arm_destination" >/dev/null
grep -Fq "checkout-bootstrap platform=aarch64-linux args=$arm_destination" "$logfile" || {
  printf '%s\n' 'bootstrap test: Linux ARM64 platform was not auto-detected' >&2
  exit 1
}
: >"$logfile"

# Apple Silicon macOS maps directly to the Darwin ARM64 output.
darwin_destination="$home/src/darwin-platform"
MOCK_UNAME_S=Darwin MOCK_UNAME_M=arm64 run_install "$darwin_destination" >/dev/null
grep -Fq "checkout-bootstrap platform=aarch64-darwin args=$darwin_destination" "$logfile" || {
  printf '%s\n' 'bootstrap test: Apple Silicon platform was not auto-detected' >&2
  exit 1
}
: >"$logfile"

# Rerunning against an existing checkout verifies origin and does not clone again.
run_install "$destination" >/dev/null
! grep -q '^git clone ' "$logfile" || { printf '%s\n' 'bootstrap test: rerun recloned repository' >&2; exit 1; }
grep -Fq "git -C $destination remote get-url origin" "$logfile" || {
  printf '%s\n' 'bootstrap test: rerun did not verify repository origin' >&2
  exit 1
}

printf '%s\n' 'bootstrap test: PASSED (platform detection, public clone, ephemeral Git, activation, and rerun)'
