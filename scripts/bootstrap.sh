#!/usr/bin/env bash
# Build and activate the detected platform from an existing public checkout.
set -euo pipefail

readonly PLATFORMS=(aarch64-darwin aarch64-linux x86_64-linux)
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
DEFAULT_DESTINATION=$(dirname "$SCRIPT_DIR")
readonly DEFAULT_DESTINATION

log() {
  printf 'nix-bootstrap: %s\n' "$1"
}

fail() {
  printf 'nix-bootstrap: ERROR: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap.sh [checkout]

The platform is detected from the operating system and CPU architecture.
Supported platforms: aarch64-darwin, aarch64-linux, x86_64-linux.
The checkout defaults to the repository containing this script.

NIX_CONFIG_PLATFORM may override detection. NIX_CONFIG_APPLY=yes|no and
NIX_CONFIG_SETUP=yes|no can answer prompts in non-interactive automation.
Otherwise confirmation prompts read from /dev/tty.
EOF
}

contains_platform() {
  local candidate=$1
  local platform
  for platform in "${PLATFORMS[@]}"; do
    [ "$platform" = "$candidate" ] && return 0
  done
  return 1
}

detect_platform() {
  local selected=${NIX_CONFIG_PLATFORM:-}
  local os arch
  if [ -z "$selected" ]; then
    os=$(uname -s)
    arch=$(uname -m)
    case "$os:$arch" in
      Darwin:arm64|Darwin:aarch64) selected=aarch64-darwin ;;
      Linux:arm64|Linux:aarch64) selected=aarch64-linux ;;
      Linux:x86_64|Linux:amd64) selected=x86_64-linux ;;
      *) fail "unsupported platform: $os/$arch" ;;
    esac
  fi
  contains_platform "$selected" || fail "unsupported platform override: $selected"
  printf '%s' "$selected"
}

answer_is_yes() {
  case "$1" in
    y|Y|yes|YES|true|TRUE|1) return 0 ;;
    *) return 1 ;;
  esac
}

answer_is_no() {
  case "$1" in
    n|N|no|NO|false|FALSE|0) return 0 ;;
    *) return 1 ;;
  esac
}

confirm() {
  local prompt=$1
  local default_answer=$2
  local preset=${3:-}
  local answer

  if [ -n "$preset" ]; then
    answer=$preset
  elif [ -r /dev/tty ]; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty || true
  else
    return 2
  fi

  [ -n "$answer" ] || answer=$default_answer
  answer_is_yes "$answer" && return 0
  answer_is_no "$answer" && return 1
  fail "invalid yes/no answer: $answer"
}

enable_nix_features() {
  if [ -n "${NIX_CONFIG:-}" ]; then
    export NIX_CONFIG="${NIX_CONFIG}
experimental-features = nix-command flakes"
  else
    export NIX_CONFIG='experimental-features = nix-command flakes'
  fi
}

apply_home() {
  local destination=$1
  local platform=$2
  local flake_ref="$destination#homeConfigurations.${platform}.activationPackage"
  local activation_package

  command -v nix >/dev/null 2>&1 || fail 'Nix is required; run scripts/install.sh first'
  [ -f "$destination/flake.nix" ] || fail "checkout has no flake.nix: $destination"

  nix flake metadata "$destination" >/dev/null \
    || fail 'flake metadata validation failed'
  nix eval --raw "$flake_ref.drvPath" >/dev/null \
    || fail "platform output is unavailable or invalid: $platform"

  if ! confirm "Apply Home Manager configuration for ${platform} now? [y/N] " no "${NIX_CONFIG_APPLY:-}"; then
    log 'Activation skipped; rerun this command when ready'
    return 1
  fi

  activation_package=$(nix build --no-link --print-out-paths "$flake_ref") \
    || fail 'Home Manager activation package build failed'
  [ -x "$activation_package/activate" ] \
    || fail 'built activation package has no executable activate script'

  log "Activating Home Manager platform ${platform}"
  "$activation_package/activate" || fail 'Home Manager activation failed'
  return 0
}

run_account_setup() {
  local setup="$HOME/.local/bin/nix-config-setup"

  if [ ! -x "$setup" ]; then
    log "Account setup is available after opening a new shell: $setup"
    return 0
  fi

  if confirm 'Home Manager activation complete. Configure application accounts now? [Y/n] ' yes "${NIX_CONFIG_SETUP:-}"; then
    if [ "$(uname -s)" = Linux ] && [ -x "$HOME/.local/bin/proton-pass-session" ]; then
      "$HOME/.local/bin/proton-pass-session" "$setup"
    else
      "$setup"
    fi
    return 0
  fi

  log 'Account setup skipped; resume later with nix-config-setup'
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local platform
  platform=$(detect_platform)
  local destination=${1:-${NIX_CONFIG_REPOSITORY:-$DEFAULT_DESTINATION}}

  enable_nix_features
  if apply_home "$destination" "$platform"; then
    run_account_setup
  fi
  log "Bootstrap complete for ${platform}"
}

main "$@"
