#!/bin/sh
# Public stage-zero installer. It holds no credentials and performs no account
# login: it makes Nix available, clones the public repository, and hands over to
# the interactive bootstrap. It takes no arguments and reads no configuration.
set -eu

REPOSITORY_URL='https://github.com/hattajr/nix-config.git'
REPOSITORY_SSH='git@github.com:hattajr/nix-config.git'
DESTINATION="${HOME}/nix-config"
NIX_INSTALLER_URL='https://nixos.org/nix/install'
# Reviewed 2026-09-02. Updating the installer is an explicit checksum change.
NIX_INSTALLER_SHA256='9adda97297d9e8ab360df95c729eabff4f4f93d6db091953c3a68f29e3fb130c'

log() { printf 'nix-install: %s\n' "$1"; }
fail() {
  printf 'nix-install: ERROR: %s\n' "$1" >&2
  exit 1
}

# "curl | sh" leaves the script on stdin, so every prompt uses the terminal.
has_tty() { [ -r /dev/tty ] && [ -w /dev/tty ]; }

confirm() {
  answer=''
  printf '%s [Y/n] ' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  case "${answer:-yes}" in
  y | Y | yes | YES) return 0 ;;
  *) return 1 ;;
  esac
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

detect_platform() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os:$arch" in
  Darwin:arm64 | Darwin:aarch64) printf 'aarch64-darwin' ;;
  Linux:arm64 | Linux:aarch64) printf 'aarch64-linux' ;;
  Linux:x86_64 | Linux:amd64) printf 'x86_64-linux' ;;
  *) fail "unsupported platform: $os/$arch" ;;
  esac
}

load_nix_environment() {
  for hook in \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
    "${HOME}/.nix-profile/etc/profile.d/nix.sh"; do
    if [ -f "$hook" ]; then
      # shellcheck disable=SC1090
      . "$hook"
    fi
  done
}

nix_is_usable() { command -v nix >/dev/null 2>&1 && nix --version >/dev/null 2>&1; }

ensure_nix() {
  # A shell that has not sourced nix.sh is not a fresh installation. Always try
  # the known profile hooks before deciding that Nix is absent.
  load_nix_environment
  if nix_is_usable; then
    log 'Using the existing Nix installation'
    return 0
  fi

  confirm 'Nix is not installed. Install it now? (needs sudo)' ||
    fail 'Nix is required; nothing was changed'

  command -v curl >/dev/null 2>&1 || fail 'Nix is missing and curl is unavailable'
  installer=$(mktemp "${TMPDIR:-/tmp}/nix-install.XXXXXX") ||
    fail 'could not create a temporary installer file'
  trap 'rm -f "$installer"' 0 1 2 15

  curl --proto '=https' --tlsv1.2 -fsSL \
    --retry 5 --retry-all-errors --retry-delay 1 \
    --output "$installer" "$NIX_INSTALLER_URL" ||
    fail 'could not download the official Nix installer'
  installer_sha256=$(sha256_file "$installer")
  [ "$installer_sha256" = "$NIX_INSTALLER_SHA256" ] ||
    fail "Nix installer checksum mismatch: expected $NIX_INSTALLER_SHA256, got $installer_sha256"
  sh "$installer" --daemon --yes || fail 'the official multi-user Nix installer failed'
  rm -f "$installer"
  trap - 0 1 2 15

  load_nix_environment
  nix_is_usable ||
    fail 'Nix was installed but is not available; open a new shell and rerun this command'
}

enable_nix_features() {
  NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}experimental-features = nix-command flakes"
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
  "$REPOSITORY_URL" | "$REPOSITORY_SSH") return 0 ;;
  *) return 1 ;;
  esac
}

clone_repository() {
  if [ -e "$DESTINATION" ]; then
    [ -d "$DESTINATION/.git" ] || fail "destination is not a Git checkout: $DESTINATION"
    origin=$(run_git -C "$DESTINATION" remote get-url origin 2>/dev/null) ||
      fail "destination has no readable Git origin: $DESTINATION"
    origin_is_trusted "$origin" || fail "destination origin is not trusted: $origin"
    [ -z "$(run_git -C "$DESTINATION" status --porcelain)" ] ||
      fail "checkout has local changes; commit or stash them first: $DESTINATION"
    [ -f "$DESTINATION/scripts/bootstrap.sh" ] ||
      fail 'destination is not a complete nix-config checkout'
    log "Using the existing checkout $DESTINATION"
    return 0
  fi

  mkdir -p "$(dirname "$DESTINATION")"
  staging="${DESTINATION}.nix-config-install.$$"
  [ ! -e "$staging" ] ||
    fail "an interrupted clone is present at $staging; inspect it before retrying"
  log "Cloning into $DESTINATION"
  run_git clone "$REPOSITORY_URL" "$staging" ||
    fail 'repository clone failed; rerun the same command after fixing connectivity'
  [ -f "$staging/scripts/bootstrap.sh" ] ||
    fail 'the clone is incomplete; it was left in place for inspection'
  mv "$staging" "$DESTINATION" || fail 'could not finalise the cloned checkout; retry'
}

main() {
  [ "$#" -eq 0 ] || fail 'install.sh takes no arguments'
  has_tty || fail 'installation is interactive; run it from a terminal'

  platform=$(detect_platform)
  printf '\n== nix-config ==\n\n'
  printf '  platform     %s\n' "$platform"
  printf '  checkout     %s\n' "$DESTINATION"
  printf '  repository   %s\n\n' "$REPOSITORY_URL"
  printf 'This clones the public repository and then asks before changing anything.\n'
  confirm 'Continue?' || {
    log 'Nothing was changed'
    exit 0
  }

  ensure_nix
  enable_nix_features
  clone_repository
  bootstrap="$DESTINATION/scripts/bootstrap.sh"
  [ -f "$bootstrap" ] || fail "bootstrap script is missing: $bootstrap"
  exec /usr/bin/env bash "$bootstrap" "$DESTINATION"
}

main "$@"
