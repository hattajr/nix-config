#!/usr/bin/env bash
# First-run activation for a freshly cloned checkout. It records the checkout,
# activates it, reports health, and hands over to the managed shell. Every
# decision is a prompt; nothing here is configurable by typing.
set -euo pipefail

LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd -P)
# shellcheck source=lib/core.sh
. "$LIB_DIR/core.sh"
# shellcheck source=lib/nix.sh
. "$LIB_DIR/nix.sh"
# shellcheck source=lib/actions.sh
. "$LIB_DIR/actions.sh"

validate_checkout() {
  local repo=$1 origin
  [ -d "$repo/.git" ] || fail "not a Git checkout: $repo"
  origin=$(run_git -C "$repo" remote get-url origin 2>/dev/null || true)
  origin_is_trusted "$origin" || fail "checkout origin is not $TRUSTED_ORIGIN_HTTPS"
}

# tmux rejects the /dev/tty alias, so the managed shell needs the concrete
# device behind it. Prompts may use the alias; an exec'd terminal may not.
resolve_terminal_device() {
  local tty_name device
  command -v ps >/dev/null 2>&1 || return 1
  tty_name=$(ps -o tty= -p "$$" 2>/dev/null) || return 1
  tty_name=${tty_name#"${tty_name%%[![:space:]]*}"}
  tty_name=${tty_name%"${tty_name##*[![:space:]]}"}
  case "$tty_name" in
    '' | '?' | '??' | tty | /* | '.' | '..' | ./* | ../* | */. | */.. | */./* | */../*) return 1 ;;
  esac
  [[ "$tty_name" =~ ^[[:alnum:]_.-]+(/[[:alnum:]_.-]+)*$ ]] || return 1
  device=/dev/$tty_name
  [ -c "$device" ] && [ -r "$device" ] && [ -w "$device" ] || return 1
  printf '%s\n' "$device"
}

start_managed_shell() {
  local managed_zsh="$HOME/.nix-profile/bin/zsh" terminal_device
  if [ ! -x "$managed_zsh" ]; then
    log "Managed shell ready; start it with: exec $managed_zsh -l"
    return
  fi
  if ! confirm 'Enter the managed zsh login shell now?' yes; then
    log "Start it later with: exec $managed_zsh -l"
    return
  fi
  terminal_device=$(resolve_terminal_device) || {
    log "Managed shell ready; start it with: exec $managed_zsh -l"
    return
  }
  log 'Entering the managed zsh login shell'
  # tmux uses its stdin terminal descriptor for both input and screen output,
  # so open that device read-write once and duplicate the descriptor.
  exec "$managed_zsh" -l <>"$terminal_device" 1>&0 2>&0
}

main() {
  local repo=${1:-}
  [ -n "$repo" ] || fail 'bootstrap needs the checkout it should activate'
  has_tty || fail 'installation is interactive; run it from a terminal'

  enable_nix_features
  resolve_identity
  validate_checkout "$repo"
  reject_nix_metacharacters "$repo" 'checkout path'

  local target
  target=$(detect_platform)

  section 'Ready to activate'
  printf '  checkout   %s\n' "$repo"
  printf '  platform   %s\n' "$target"
  printf '  account    %s (%s)\n' "$IDENTITY_USERNAME" "$IDENTITY_HOME"
  printf '\nHome Manager owns the files it manages. A colliding regular file is\n'
  printf 'moved under %s before replacement.\n' "${XDG_STATE_HOME:-$HOME/.local/state}/home-manager/takeover"

  if ! confirm 'Apply this configuration now?' yes; then
    log 'Nothing was changed; run bro when you are ready'
    return 0
  fi

  write_checkout_state "$repo"
  apply "$repo" "$target"
  health "$repo" "$target" || true
  log 'Bootstrap complete'

  if [ -x "$ACCOUNT_SETUP" ] && confirm 'Configure accounts and API keys now?' yes; then
    auth || warn 'account setup did not finish; choose Accounts from the bro menu later'
  fi
  if shadowed_binaries_present \
    && confirm 'Review binaries that shadow the Nix profile?' yes; then
    shadow_review || warn 'review did not finish; choose Clean up from the bro menu later'
  fi

  start_managed_shell
}

main "$@"
