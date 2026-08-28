#!/usr/bin/env bash
# Activate a reviewed checkout and record it for the installed bro command.
set -euo pipefail

readonly EXPECTED_ORIGIN=${NIX_CONFIG_REPOSITORY_URL:-https://github.com/hattajr/nix-config.git}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly DEFAULT_DESTINATION=$(dirname "$SCRIPT_DIR")

log() { printf 'nix-bootstrap: %s\n' "$*"; }
fail() { printf 'nix-bootstrap: ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: scripts/bootstrap.sh [checkout]

Records a validated checkout, then runs bro apply followed by bro health.
With a terminal, applying is prompted once and defaults to yes.
Without a terminal set NIX_CONFIG_APPLY=yes to apply or NIX_CONFIG_APPLY=no to
validate only. NIX_CONFIG_PLATFORM overrides platform detection.
EOF
}
answer_is_yes() { case "$1" in y|Y|yes|YES|true|TRUE|1) return 0;; *) return 1;; esac; }
answer_is_no() { case "$1" in n|N|no|NO|false|FALSE|0) return 0;; *) return 1;; esac; }

run_git() {
  if command -v git >/dev/null 2>&1; then
    git "$@"
  else
    command -v nix >/dev/null 2>&1 || fail 'Git is missing and Nix is unavailable'
    nix shell --accept-flake-config nixpkgs#git --command git "$@"
  fi
}

validate_checkout() {
  local repo=$1 origin
  [ -d "$repo/.git" ] || fail "not a Git checkout: $repo"
  origin=$(run_git -C "$repo" remote get-url origin 2>/dev/null || true)
  case "$origin:$EXPECTED_ORIGIN" in
    "$EXPECTED_ORIGIN:$EXPECTED_ORIGIN"|git@github.com:hattajr/nix-config.git:https://github.com/hattajr/nix-config.git) ;;
    *) fail "checkout origin is not $EXPECTED_ORIGIN" ;;
  esac
}
write_checkout_state() {
  local repo=$1 state_dir state tmp
  state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/bro
  state=$state_dir/checkout
  mkdir -p "$state_dir" || fail 'could not create bro state directory'
  chmod 700 "$state_dir" || fail 'could not secure bro state directory'
  tmp=$(mktemp "$state_dir/.checkout.XXXXXX") || fail 'could not create bro state file'
  printf '%s\n' "$(CDPATH='' cd -- "$repo" && pwd -P)" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$state"
}
start_managed_shell() {
  local managed_zsh="$HOME/.nix-profile/bin/zsh"
  local start_shell=${NIX_CONFIG_START_SHELL:-yes}
  answer_is_no "$start_shell" && { log "Managed shell ready; start it with: exec $managed_zsh -l"; return; }
  answer_is_yes "$start_shell" || fail "invalid NIX_CONFIG_START_SHELL value: $start_shell"
  [ -x "$managed_zsh" ] || { log "Managed shell ready; start it with: exec $managed_zsh -l"; return; }
  [ -r /dev/tty ] && [ -w /dev/tty ] || { log "Managed shell ready; start it with: exec $managed_zsh -l"; return; }
  log 'Entering the managed zsh login shell'
  exec "$managed_zsh" -l </dev/tty >/dev/tty 2>&1
}
should_apply() {
  local preset=${NIX_CONFIG_APPLY:-} answer
  if [ -n "$preset" ]; then
    answer_is_yes "$preset" && return 0
    answer_is_no "$preset" && return 1
    fail "invalid NIX_CONFIG_APPLY value: $preset"
  fi
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    log 'No terminal available; set NIX_CONFIG_APPLY=yes to activate or NIX_CONFIG_APPLY=no to validate only'
    return 1
  fi
  printf 'Apply Home Manager configuration now? [Y/n] ' >/dev/tty
  IFS= read -r answer </dev/tty || true
  [ -z "$answer" ] && answer=yes
  answer_is_yes "$answer" && return 0
  answer_is_no "$answer" && return 1
  fail "invalid yes/no answer: $answer"
}
main() {
  case "${1:-}" in -h|--help) usage; exit 0;; esac
  local repo=${1:-${NIX_CONFIG_REPOSITORY:-$DEFAULT_DESTINATION}}
  validate_checkout "$repo"
  write_checkout_state "$repo"
  if ! should_apply; then log 'Bootstrap finished without activation'; return 0; fi
  NIX_CONFIG_REPOSITORY_URL="$EXPECTED_ORIGIN" "$repo/scripts/bro" apply
  NIX_CONFIG_REPOSITORY_URL="$EXPECTED_ORIGIN" "$repo/scripts/bro" health
  log 'Bootstrap complete'
  log 'Next: run bro auth to configure accounts and API keys'
  start_managed_shell
}
main "$@"
