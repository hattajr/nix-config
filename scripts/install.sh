#!/bin/sh
# Public stage-zero installer. It contains no credentials and performs no
# account login. Safe to invoke from a reviewed, preferably commit-pinned URL.
set -eu

REPOSITORY_URL=${NIX_CONFIG_REPOSITORY_URL:-https://github.com/hattajr/nix-config.git}
DEFAULT_DESTINATION=${HOME}/src/nix-config
PLATFORMS="aarch64-darwin aarch64-linux x86_64-linux"

log() {
  printf 'nix-install: %s\n' "$1"
}

fail() {
  printf 'nix-install: ERROR: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [destination]

The platform is detected from the operating system and CPU architecture.
Supported platforms: aarch64-darwin, aarch64-linux, x86_64-linux.
The destination defaults to ~/src/nix-config.

NIX_CONFIG_PLATFORM may override detection for automation. NIX_CONFIG_REPOSITORY
may set the destination. After cloning, bootstrap prompts once to apply the
configuration; set NIX_CONFIG_APPLY=yes to apply unattended or
NIX_CONFIG_APPLY=no to clone and validate only. Without a terminal, bootstrap
fails closed unless one of those values is set. After activation, run bro auth to
configure optional accounts and API keys.
EOF
}

contains_platform() {
  candidate=$1
  for platform in $PLATFORMS; do
    [ "$platform" = "$candidate" ] && return 0
  done
  return 1
}

detect_platform() {
  selected=${NIX_CONFIG_PLATFORM:-}
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

load_nix_environment() {
  for hook in \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
    "${HOME}/.nix-profile/etc/profile.d/nix.sh"
  do
    if [ -f "$hook" ]; then
      # shellcheck disable=SC1090
      . "$hook"
    fi
  done
}

ensure_nix() {
  command -v nix >/dev/null 2>&1 && return 0
  command -v curl >/dev/null 2>&1 || fail 'Nix is missing and curl is unavailable'

  log 'Nix is not installed; downloading the official multi-user installer'
  installer=$(mktemp "${TMPDIR:-/tmp}/nix-install.XXXXXX") \
    || fail 'could not create a temporary installer file'
  cleanup_installer() {
    rm -f "$installer"
  }
  trap cleanup_installer 0 1 2 15

  curl --proto '=https' --tlsv1.2 -fsSL \
    --output "$installer" https://nixos.org/nix/install \
    || fail 'could not download the official Nix installer'
  sh "$installer" --daemon || fail 'official Nix installer failed'
  cleanup_installer
  trap - 0 1 2 15

  load_nix_environment
  command -v nix >/dev/null 2>&1 \
    || fail 'Nix was installed but is not available; open a new shell and rerun this command'
}

enable_nix_features() {
  if [ -n "${NIX_CONFIG:-}" ]; then
    NIX_CONFIG="${NIX_CONFIG}
experimental-features = nix-command flakes"
  else
    NIX_CONFIG='experimental-features = nix-command flakes'
  fi
  export NIX_CONFIG
}

run_git() {
  if command -v git >/dev/null 2>&1; then
    git "$@"
  else
    nix shell --accept-flake-config nixpkgs#git --command git "$@"
  fi
}

clone_repository() {
  destination=$1
  if [ -e "$destination" ]; then
    [ -d "$destination/.git" ] \
      || fail "destination exists but is not a Git repository: $destination"
    origin=$(run_git -C "$destination" remote get-url origin 2>/dev/null) \
      || fail "existing repository has no origin remote: $destination"
    [ "$origin" = "$REPOSITORY_URL" ] \
      || fail "existing repository origin is not $REPOSITORY_URL"
    log "Using existing checkout at $destination"
    return 0
  fi

  mkdir -p "$(dirname "$destination")"
  log "Cloning the public repository into $destination"
  run_git clone "$REPOSITORY_URL" "$destination" \
    || fail 'repository clone failed'
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  platform=$(detect_platform)
  destination=${1:-${NIX_CONFIG_REPOSITORY:-$DEFAULT_DESTINATION}}

  ensure_nix
  enable_nix_features
  clone_repository "$destination"

  bootstrap="$destination/scripts/bootstrap.sh"
  [ -f "$bootstrap" ] || fail "bootstrap script is missing: $bootstrap"
  log "Continuing with the reviewed checkout for platform $platform"
  NIX_CONFIG_PLATFORM=$platform \
    exec /usr/bin/env bash "$bootstrap" "$destination"
}

main "$@"
