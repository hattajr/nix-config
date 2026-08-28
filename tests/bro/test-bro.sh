#!/usr/bin/env bash
# Focused safety checks for bro without a real Nix activation or network.
set -euo pipefail
repo_root=${BRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
bro="$repo_root/scripts/bro"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
checkout="$work/checkout"; mockbin="$work/bin"; log="$work/log"
mkdir -p "$checkout" "$mockbin"; : >"$log"
git init -q "$checkout"
git -C "$checkout" remote add origin https://github.com/hattajr/nix-config.git
printf '{}\n' >"$checkout/flake.nix"
real_git=$(command -v git)
cat >"$mockbin/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\\n' "\$*" >>"$log"
if [ "\${BRO_GIT_MODE:-}" = sync ]; then
  case "\${3:-}" in
    status|fetch|push) exit 0 ;;
    rev-parse) printf '%s\\n' origin/main; exit 0 ;;
    rev-list)
      case "\${5:-}" in *..HEAD) printf '%s\\n' 1 ;; *) printf '%s\\n' 0 ;; esac
      exit 0
      ;;
  esac
fi
exec "$real_git" "\$@"
EOF
cat >"$mockbin/nix" <<'EOF'
#!/usr/bin/env bash
printf 'nix %s
' "$*" >>"$BRO_LOG"
case "$1" in
  flake|eval) exit 0 ;;
  build) mkdir -p "$BRO_ACTIVATION"; cat >"$BRO_ACTIVATION/activate" <<'ACTIVATE'
#!/bin/sh
printf 'activation
' >>"$BRO_LOG"
ACTIVATE
    chmod +x "$BRO_ACTIVATION/activate"; printf '%s\n' "$BRO_ACTIVATION" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$mockbin/git" "$mockbin/nix"
export BRO_LOG="$log" BRO_ACTIVATION="$work/activation" BRO_REPOSITORY="$checkout"

# Noninteractive apply activates but deliberately does not start a shell.
apply_home="$work/apply-home"
mkdir -p "$apply_home/.nix-profile/bin"
cat >"$apply_home/.nix-profile/bin/zsh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$apply_home/.nix-profile/bin/zsh"
HOME="$apply_home" PATH="$mockbin:$PATH" "$bro" apply >/dev/null
grep -q '^activation$' "$log"
! grep -Eq '^git .* (fetch|push)($| )' "$log" || { echo 'bro test: apply used Git network operation' >&2; exit 1; }
: >"$log"
printf dirty >"$checkout/dirty"
if PATH="$mockbin:$PATH" "$bro" sync >/dev/null 2>&1; then echo 'bro test: dirty sync succeeded' >&2; exit 1; fi
! grep -q '^git .* fetch' "$log" || { echo 'bro test: dirty sync fetched' >&2; exit 1; }
if HOME="$apply_home" PATH="$mockbin:$PATH" "$bro" health >/dev/null 2>&1; then
  echo 'bro test: health accepted missing managed tmux/configuration' >&2
  exit 1
fi
rm "$checkout/dirty"
: >"$log"
BRO_GIT_MODE=sync PATH="$mockbin:$PATH" "$bro" sync >/dev/null
! grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: ordinary sync pushed' >&2; exit 1; }
grep -q 'use bro sync --push' <(BRO_GIT_MODE=sync PATH="$mockbin:$PATH" "$bro" sync) || {
  echo 'bro test: ahead sync did not explain explicit push' >&2
  exit 1
}
: >"$log"
BRO_GIT_MODE=sync PATH="$mockbin:$PATH" "$bro" sync --push >/dev/null
grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: sync --push did not push' >&2; exit 1; }

auth_home="$work/auth-home"
mkdir -p "$auth_home/.local/bin"
cat >"$auth_home/.local/bin/nix-config-setup" <<'EOF'
#!/bin/sh
printf 'setup %s\n' "$*" >>"$BRO_LOG"
EOF
cat >"$auth_home/.local/bin/proton-pass-session" <<'EOF'
#!/bin/sh
printf 'proton %s\n' "$*" >>"$BRO_LOG"
EOF
chmod +x "$auth_home/.local/bin/nix-config-setup" "$auth_home/.local/bin/proton-pass-session"
: >"$log"
HOME="$auth_home" PATH="$mockbin:$PATH" "$bro" auth
grep -Fq "proton $auth_home/.local/bin/nix-config-setup" "$log" || {
  echo 'bro test: Linux auth did not use Proton Pass session' >&2
  exit 1
}
rm "$auth_home/.local/bin/proton-pass-session"
: >"$log"
HOME="$auth_home" PATH="$mockbin:$PATH" "$bro" auth
grep -q '^setup ' "$log" || { echo 'bro test: auth fallback did not run setup' >&2; exit 1; }

# Interactive apply must clear inherited LC_ALL and attach managed zsh to the
# concrete /dev/pts/N device, never the /dev/tty alias rejected by tmux.
pty_home="$work/pty-home"; shell_log="$work/managed-shell.log"
mkdir -p "$pty_home/.nix-profile/bin"
cat >"$mockbin/ps" <<'EOF'
#!/usr/bin/env bash
device=$(readlink "/proc/$$/fd/0")
printf '%s\n' "${device#/dev/}"
EOF
cat >"$mockbin/tty" <<'EOF'
#!/usr/bin/env bash
readlink "/proc/$$/fd/0"
EOF
cat >"$pty_home/.nix-profile/bin/zsh" <<'EOF'
#!/usr/bin/env bash
printf 'LC_ALL=%s tty=%s\n' "${LC_ALL-<unset>}" "$(tty)" >>"$BRO_TEST_SHELL_LOG"
EOF
chmod +x "$mockbin/ps" "$mockbin/tty" "$pty_home/.nix-profile/bin/zsh"
if python3_path=$(PATH=/usr/local/bin:/usr/bin:/bin command -v python3 2>/dev/null); then
  python_command=("$python3_path")
else
  python_command=("$(nix build --no-link --print-out-paths nixpkgs#python3)/bin/python3")
fi
HOME="$pty_home" PATH="$mockbin:$PATH" LC_ALL=C.UTF-8 BRO_TEST_SHELL_LOG="$shell_log" \
  SYSTEM_BASH="$(command -v bash)" BRO_UNDER_TEST="$bro" "${python_command[@]}" <<'PY_PTY'
import os
import pty
import sys

pid, fd = pty.fork()
if pid == 0:
    os.execve(os.environ["SYSTEM_BASH"], ["bash", os.environ["BRO_UNDER_TEST"], "apply"], os.environ)
while True:
    try:
        if not os.read(fd, 4096):
            break
    except OSError:
        break
_, status = os.waitpid(pid, 0)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    sys.exit(1)
PY_PTY
grep -Eq '^LC_ALL=<unset> tty=/dev/pts/.+$' "$shell_log" || {
  echo 'bro test: managed shell did not receive a clean concrete terminal' >&2
  cat "$shell_log" >&2
  exit 1
}
echo 'bro test: PASSED (apply safety, terminal refresh, sync push boundary, auth wrapper, health)'
