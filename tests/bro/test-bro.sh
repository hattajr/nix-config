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
printf 'activation\n' >>"$BRO_LOG"
ACTIVATE
    chmod +x "$BRO_ACTIVATION/activate"; printf '%s\n' "$BRO_ACTIVATION" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$mockbin/git" "$mockbin/nix"
export BRO_LOG="$log" BRO_ACTIVATION="$work/activation" BRO_REPOSITORY="$checkout"
apply_home="$work/apply-home"
mkdir -p "$apply_home/.nix-profile/bin" "$apply_home/.config/tmux"
printf '%s\n' '# test configuration' >"$apply_home/.config/tmux/tmux.conf"
cat >"$apply_home/.nix-profile/bin/tmux" <<'EOF'
#!/bin/sh
printf 'tmux %s\n' "$*" >>"$BRO_LOG"
EOF
chmod +x "$apply_home/.nix-profile/bin/tmux"
HOME="$apply_home" PATH="$mockbin:$PATH" "$bro" apply >/dev/null
grep -q '^activation$' "$log"
grep -Fq "tmux source-file $apply_home/.config/tmux/tmux.conf" "$log" || {
  echo 'bro test: apply did not reload an active managed tmux server' >&2
  exit 1
}
grep -q 'reloaded active tmux configuration' <(HOME="$apply_home" PATH="$mockbin:$PATH" "$bro" apply) || {
  echo 'bro test: apply did not report tmux configuration reload' >&2
  exit 1
}
! grep -Eq '^git .* (fetch|push)($| )' "$log" || { echo 'bro test: apply used Git network operation' >&2; exit 1; }
: >"$log"
printf dirty >"$checkout/dirty"
if PATH="$mockbin:$PATH" "$bro" sync >/dev/null 2>&1; then echo 'bro test: dirty sync succeeded' >&2; exit 1; fi
! grep -q '^git .* fetch' "$log" || { echo 'bro test: dirty sync fetched' >&2; exit 1; }
if PATH="$mockbin:$PATH" "$bro" health >/dev/null 2>&1; then
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
echo 'bro test: PASSED (apply safety, sync push boundary, auth wrapper, dirty refusal, health)'
