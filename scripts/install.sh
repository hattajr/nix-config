#!/bin/sh
# Public stage-zero installer. It contains no credentials and performs no
# account login. It clones the public repository and then runs its bootstrap.
set -eu

REPOSITORY_URL=${NIX_CONFIG_REPOSITORY_URL:-https://github.com/hattajr/nix-config.git}
DEFAULT_DESTINATION=${HOME}/src/nix-config
NIX_ROOT=${NIX_CONFIG_NIX_ROOT:-/nix}
NIX_INSTALLER_URL=${NIX_CONFIG_NIX_INSTALLER_URL:-https://nixos.org/nix/install}
# Reviewed 2026-09-02. Updating the installer is an explicit checksum change.
NIX_INSTALLER_SHA256=${NIX_CONFIG_NIX_INSTALLER_SHA256:-9adda97297d9e8ab360df95c729eabff4f4f93d6db091953c3a68f29e3fb130c}
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

The installer first reuses an existing working Nix installation, including one
whose profile is not loaded in the current shell. Home Manager is the sole owner
of its managed configuration paths and replaces legacy files during activation.
EOF
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail 'sha256sum or shasum is required to verify the Nix installer'
  fi
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
    Darwin:arm64 | Darwin:aarch64) selected=aarch64-darwin ;;
    Linux:arm64 | Linux:aarch64) selected=aarch64-linux ;;
    Linux:x86_64 | Linux:amd64) selected=x86_64-linux ;;
    *) fail "unsupported platform: $os/$arch" ;;
    esac
  fi
  contains_platform "$selected" || fail "unsupported platform override: $selected"
  printf '%s' "$selected"
}

load_nix_environment() {
  for hook in \
    "$NIX_ROOT/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" \
    "${HOME}/.nix-profile/etc/profile.d/nix.sh"; do
    if [ -f "$hook" ]; then
      # shellcheck disable=SC1090
      . "$hook"
    fi
  done
}

nix_is_usable() {
  command -v nix >/dev/null 2>&1 && nix --version >/dev/null 2>&1
}

ensure_nix() {
  # A shell that has not sourced nix.sh is not a fresh installation. Always try
  # known profile hooks before deciding that Nix is absent.
  load_nix_environment
  if nix_is_usable; then
    log 'Using existing Nix installation'
    return 0
  fi

  # The daemon installer owns /nix as root, so an existing root-owned /nix is
  # expected and must be left for the official installer to manage.
  log 'Nix is not installed; downloading the official multi-user installer (sudo is required)'

  command -v curl >/dev/null 2>&1 || fail 'Nix is missing and curl is unavailable'
  installer=$(mktemp "${TMPDIR:-/tmp}/nix-install.XXXXXX") ||
    fail 'could not create a temporary installer file'
  cleanup_installer() { rm -f "$installer"; }
  trap cleanup_installer 0 1 2 15

  curl --proto '=https' --tlsv1.2 -fsSL \
    --retry 5 --retry-all-errors --retry-delay 1 \
    --output "$installer" "$NIX_INSTALLER_URL" ||
    fail 'could not download the official Nix installer'
  installer_sha256=$(sha256_file "$installer")
  [ "$installer_sha256" = "$NIX_INSTALLER_SHA256" ] ||
    fail "Nix installer checksum mismatch: expected $NIX_INSTALLER_SHA256, got $installer_sha256"
  sh "$installer" --daemon --yes || fail 'official multi-user Nix installer failed'
  cleanup_installer
  trap - 0 1 2 15

  load_nix_environment
  nix_is_usable ||
    fail 'Nix was installed but is not available; open a new shell and rerun this command'
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

origin_is_trusted() {
  case "$1" in
  "$REPOSITORY_URL" | git@github.com:hattajr/nix-config.git) return 0 ;;
  *) return 1 ;;
  esac
}

validate_checkout() {
  checkout=$1
  [ -d "$checkout/.git" ] || return 1
  origin=$(run_git -C "$checkout" remote get-url origin 2>/dev/null) || return 1
  origin_is_trusted "$origin" || return 1
  [ -f "$checkout/scripts/bootstrap.sh" ] || return 1
}

verify_existing_checkout() {
  checkout=$1
  [ -z "$(run_git -C "$checkout" status --porcelain)" ] ||
    fail "checkout has local changes; commit or stash them before installing: $checkout"
  log "Using existing checkout $checkout"
}

clone_repository() {
  destination=$1
  if [ -e "$destination" ]; then
    [ -d "$destination/.git" ] ||
      fail "destination is not a Git checkout: $destination"
    origin=$(run_git -C "$destination" remote get-url origin 2>/dev/null) ||
      fail "destination has no readable Git origin: $destination"
    origin_is_trusted "$origin" ||
      fail "destination origin is not trusted: $origin"
    verify_existing_checkout "$destination"
    validate_checkout "$destination" ||
      fail 'destination is not a complete nix-config checkout'
    return 0
  fi

  mkdir -p "$(dirname "$destination")"
  staging="${destination}.nix-config-install.$$"
  [ ! -e "$staging" ] ||
    fail "an interrupted clone is present at $staging; inspect it before retrying"
  log "Cloning the public repository into $destination"
  run_git clone "$REPOSITORY_URL" "$staging" ||
    fail 'repository clone failed; rerun the same command after fixing connectivity'
  validate_checkout "$staging" ||
    fail 'repository clone is incomplete; it was left in place for inspection'
  mv "$staging" "$destination" ||
    fail "could not finalize cloned checkout; retry the same command"
  log 'Using the latest repository checkout'
}

main() {
  case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  esac

  platform=$(detect_platform)
  destination=${1:-${NIX_CONFIG_REPOSITORY:-$DEFAULT_DESTINATION}}

  ensure_nix
  enable_nix_features
  clone_repository "$destination"
  bootstrap="$destination/scripts/bootstrap.sh"
  [ -f "$bootstrap" ] || fail "bootstrap script is missing: $bootstrap"
  log "Continuing with the cloned checkout for platform $platform"
  NIX_CONFIG_PLATFORM=$platform \
    exec /usr/bin/env bash "$bootstrap" "$destination"
}

main "$@"
