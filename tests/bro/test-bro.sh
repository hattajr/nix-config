#!/usr/bin/env bash
# Focused safety checks for bro without a real Nix activation or network.
set -euo pipefail
repo_root=${BRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
bro="$repo_root/scripts/bro"
unset NIX_CONFIG_USERNAME NIX_CONFIG_HOME
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
checkout="$work/checkout"
mockbin="$work/bin"
log="$work/log"
mkdir -p "$checkout" "$mockbin"
: >"$log"
mkdir -p "$checkout/scripts"
ln -s /bin/bash "$mockbin/bash"
ln -s "$(command -v python3)" "$mockbin/python3"
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
if [ -n "${BRO_NIX_DNS_FAILURES:-}" ]; then
  attempt=0
  [ ! -r "$BRO_NIX_RETRY_STATE" ] || attempt=$(cat "$BRO_NIX_RETRY_STATE")
  if [ "$attempt" -lt "$BRO_NIX_DNS_FAILURES" ]; then
    printf '%s\n' "$((attempt + 1))" >"$BRO_NIX_RETRY_STATE"
    printf '%s\n' "warning: unable to download input: Could not resolve hostname (6) Could not resolve host: github.com" >&2
    exit 1
  fi
fi
[ "${1:-}" != --impure ] || shift
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
cat >"$mockbin/sleep" <<'EOF'
#!/bin/sh
printf 'sleep %s\n' "$*" >>"$BRO_LOG"
EOF
chmod +x "$mockbin/git" "$mockbin/nix" "$mockbin/sleep"
export BRO_LOG="$log" BRO_ACTIVATION="$work/activation" BRO_REPOSITORY="$checkout"
apply_home="$work/apply-home"
mkdir -p "$apply_home/.nix-profile/bin" "$apply_home/.config/tmux"
printf '%s\n' '# test configuration' >"$apply_home/.config/tmux/tmux.conf"
cat >"$apply_home/.nix-profile/bin/tmux" <<'EOF'
#!/bin/sh
printf 'tmux %s\n' "$*" >>"$BRO_LOG"
EOF
chmod +x "$apply_home/.nix-profile/bin/tmux"
env -u NIX_CONFIG_USERNAME -u NIX_CONFIG_HOME \
  HOME="$apply_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" apply >/dev/null
grep -q '^activation$' "$log"
grep -Fq 'nix eval --impure --raw' "$log" || {
  echo 'bro test: apply did not evaluate the active user identity impurely' >&2
  exit 1
}
grep -Fq 'nix build --impure --no-link' "$log" || {
  echo 'bro test: apply did not build with the active user identity' >&2
  exit 1
}
grep -Fq "nix flake metadata path:$checkout" "$log" || {
  echo 'bro test: apply used a Git flake that hides untracked configuration' >&2
  exit 1
}
grep -Fq "path:$checkout#homeConfigurations.x86_64-linux.activationPackage" "$log" || {
  echo 'bro test: activation build did not include the complete working tree' >&2
  exit 1
}
grep -Eq '^tmux source-file .*/\.config/tmux/tmux\.conf$' "$log" || {
  echo 'bro test: apply did not reload an active managed tmux server' >&2
  exit 1
}
grep -q 'reloaded active tmux configuration' <(env -u NIX_CONFIG_USERNAME -u NIX_CONFIG_HOME \
  HOME="$apply_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" apply) || {
  echo 'bro test: apply did not report tmux configuration reload' >&2
  exit 1
}

: >"$log"
retry_state="$work/retry-state"
retry_error="$work/retry-error"
BRO_NIX_DNS_FAILURES=2 BRO_NIX_RETRY_STATE="$retry_state" \
  HOME="$apply_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" apply \
  >/dev/null 2>"$retry_error"
[ "$(grep -c '^nix flake metadata ' "$log")" -eq 3 ] || {
  echo 'bro test: apply did not retry transient DNS failures' >&2
  exit 1
}
if ! grep -Fxq 'sleep 1' "$log" || ! grep -Fxq 'sleep 2' "$log"; then
  echo 'bro test: DNS retries did not use exponential backoff' >&2
  exit 1
fi
grep -Fq 'retrying in 1s (attempt 2/5)' "$retry_error" || {
  echo 'bro test: apply did not report DNS retry progress' >&2
  exit 1
}

: >"$log"
rm -f "$retry_state"
if BRO_NIX_DNS_FAILURES=9 BRO_NIX_RETRY_STATE="$retry_state" \
  HOME="$apply_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" apply \
  >/dev/null 2>"$retry_error"; then
  echo 'bro test: apply accepted DNS failure after the retry limit' >&2
  exit 1
fi
[ "$(grep -c '^nix flake metadata ' "$log")" -eq 5 ] || {
  echo 'bro test: apply did not stop after five DNS attempts' >&2
  exit 1
}
[ "$(grep -c '^sleep ' "$log")" -eq 4 ] || {
  echo 'bro test: apply slept after the final DNS attempt' >&2
  exit 1
}
grep -Fq 'DNS resolution failed after 5 attempts' "$retry_error" || {
  echo 'bro test: apply did not report exhausted DNS retries' >&2
  exit 1
}

! grep -Eq '^git .* (fetch|push)($| )' "$log" || {
  echo 'bro test: apply used Git network operation' >&2
  exit 1
}
: >"$log"
printf dirty >"$checkout/dirty"
if PATH="$mockbin:$PATH" "$bro" sync >/dev/null 2>&1; then
  echo 'bro test: dirty sync succeeded' >&2
  exit 1
fi
! grep -q '^git .* fetch' "$log" || {
  echo 'bro test: dirty sync fetched' >&2
  exit 1
}
if PATH="$mockbin:$PATH" "$bro" health >/dev/null 2>&1; then
  echo 'bro test: health accepted missing managed tmux/configuration' >&2
  exit 1
fi
rm "$checkout/dirty"
: >"$log"
if PATH="$mockbin:$PATH" "$bro" update </dev/null >/dev/null 2>&1; then
  echo 'bro test: non-interactive update succeeded' >&2
  exit 1
fi
! grep -Fq 'nix flake update nixpkgs' "$log" || {
  echo 'bro test: non-interactive update changed a pin' >&2
  exit 1
}
grep -q 'bro update' <(PATH="$mockbin:$PATH" "$bro" --help) || {
  echo 'bro test: help did not document update' >&2
  exit 1
}
if PATH="$mockbin:$PATH" "$bro" update --verbose </dev/null >/dev/null 2>&1; then
  echo 'bro test: non-interactive verbose update succeeded' >&2
  exit 1
fi
: >"$log"
BRO_GIT_MODE=sync PATH="$mockbin:$PATH" "$bro" sync >/dev/null
! grep -Eq '^git .* push($| )' "$log" || {
  echo 'bro test: ordinary sync pushed' >&2
  exit 1
}
grep -q 'use bro sync --push' <(BRO_GIT_MODE=sync PATH="$mockbin:$PATH" "$bro" sync) || {
  echo 'bro test: ahead sync did not explain explicit push' >&2
  exit 1
}
: >"$log"
BRO_GIT_MODE=sync PATH="$mockbin:$PATH" "$bro" sync --push >/dev/null
grep -Eq '^git .* push($| )' "$log" || {
  echo 'bro test: sync --push did not push' >&2
  exit 1
}

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
grep -q '^setup ' "$log" || {
  echo 'bro test: auth fallback did not run setup' >&2
  exit 1
}
echo 'bro test: PASSED (apply safety, sync push boundary, update safety, auth wrapper, dirty refusal, health)'
