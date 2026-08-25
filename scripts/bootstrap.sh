#!/usr/bin/env bash
# Bootstrap a fresh host without importing credentials from the repository.
#
# Usage:
#   ./scripts/bootstrap.sh [host] [destination]
#
# A missing age identity is generated locally during bootstrap.
# The script never prints, copies, or commits the identity contents.
set -euo pipefail

readonly REPOSITORY_URL="git@github.com:hattajr/nix-config.git"
readonly DEFAULT_DESTINATION="${HOME}/src/nix-config"
readonly AGE_IDENTITY_DEFAULT="${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt}"
readonly HOSTS=(macbook latte legion espresso)

log() {
  printf 'nix-bootstrap: %s\n' "$1"
}

fail() {
  printf 'nix-bootstrap: ERROR: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap.sh [host] [destination]

Host must be one of: macbook, latte, legion, espresso.
The destination defaults to ~/src/nix-config.

Before running:
  1. Have an SSH key or other GitHub method ready for `gh auth login`.
  2. If no age identity exists, bootstrap generates one locally and pauses
     so its public recipient can be added to the SOPS policy.
EOF
}

contains_host() {
  local candidate=$1
  local host
  for host in "${HOSTS[@]}"; do
    [ "$host" = "$candidate" ] && return 0
  done
  return 1
}

select_host() {
  local selected=${1:-${NIX_CONFIG_HOST:-}}
  if [ -z "$selected" ]; then
    printf 'Select host [macbook/latte/legion/espresso]: ' >&2
    IFS= read -r selected || true
  fi
  contains_host "$selected" || fail "unknown or missing host: ${selected:-<empty>}"
  printf '%s' "$selected"
}

ensure_nix() {
  if command -v nix >/dev/null 2>&1; then
    return
  fi

  command -v curl >/dev/null 2>&1 || fail 'Nix is missing and curl is unavailable'
  log 'Nix is not installed; starting the official multi-user installer'
  sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon \
    || fail 'official Nix installer failed'

  # The daemon installer normally creates this profile hook. Source whichever
  # hook exists so this invocation can continue without opening a new shell.
  if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi
  if [ -f "${HOME}/.nix-profile/etc/profile.d/nix.sh" ]; then
    # shellcheck disable=SC1091
    . "${HOME}/.nix-profile/etc/profile.d/nix.sh"
  fi
  command -v nix >/dev/null 2>&1 || fail 'Nix was installed but is not available in this shell'
}

ensure_flakes() {
  # Keep flakes enabled for every Nix command in this bootstrap invocation.
  export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"
}

ensure_tools() {
  local packages=()
  command -v git >/dev/null 2>&1 || packages+=(nixpkgs#git)
  command -v gh >/dev/null 2>&1 || packages+=(nixpkgs#gh)
  if ((${#packages[@]} == 0)); then
    return 0
  fi

  log "Installing missing tools into the user Nix profile: ${packages[*]}"
  nix profile install --accept-flake-config "${packages[@]}" \
    || fail 'could not install required Git/GitHub tools through Nix'
  export PATH="${HOME}/.nix-profile/bin:${PATH}"
  command -v git >/dev/null 2>&1 || fail 'Git is unavailable after Nix installation'
  command -v gh >/dev/null 2>&1 || fail 'GitHub CLI is unavailable after Nix installation'
}

verify_age_identity() {
  local identity=${SOPS_AGE_KEY_FILE:-$AGE_IDENTITY_DEFAULT}
  [ ! -d "$identity" ] || fail 'age identity path is a directory'

  if [ ! -f "$identity" ]; then
    local identity_dir
    local recipient
    identity_dir=$(dirname "$identity")
    mkdir -p "$identity_dir"
    chmod 700 "$identity_dir"
    log "No age identity found; generating one at ${identity}"
    nix shell --accept-flake-config nixpkgs#age --command age-keygen -o "$identity" >/dev/null 2>&1 \
      || fail 'could not generate the age identity'
    chmod 600 "$identity"
    recipient=$(nix shell --accept-flake-config nixpkgs#age --command age-keygen -y "$identity") \
      || fail 'generated age identity could not be read'
    printf 'nix-bootstrap: public age recipient: %s\n' "$recipient"
    printf 'nix-bootstrap: ACTION REQUIRED: add this recipient to the SOPS policy, re-encrypt required files, push them, then rerun bootstrap\n' >&2
    exit 2
  fi

  [ -r "$identity" ] || fail 'age identity is not readable'
  nix shell --accept-flake-config nixpkgs#age --command age-keygen -y "$identity" >/dev/null \
    || fail 'age identity could not be validated'
  chmod 600 "$identity"
  export SOPS_AGE_KEY_FILE="$identity"
}

verify_github_auth() {
  log 'GitHub authentication is required before cloning the private repository'
  if ! gh auth status >/dev/null 2>&1; then
    gh auth login </dev/tty >/dev/tty 2>/dev/tty \
      || fail 'gh auth login failed or was cancelled'
  fi
  gh auth status >/dev/null 2>&1 || fail 'GitHub CLI is not authenticated'
}

clone_repository() {
  local destination=$1
  if [ -e "$destination" ]; then
    [ -d "$destination/.git" ] || fail "destination exists but is not a Git repository: $destination"
    local origin
    origin=$(git -C "$destination" remote get-url origin 2>/dev/null) \
      || fail "existing repository has no origin remote: $destination"
    [ "$origin" = "$REPOSITORY_URL" ] \
      || fail "existing repository origin is not $REPOSITORY_URL"
    log "Using existing checkout at $destination"
    return
  fi

  mkdir -p "$(dirname "$destination")"
  log "Cloning the private repository into $destination"
  git clone "$REPOSITORY_URL" "$destination" \
    || fail 'repository clone failed'
}

apply_home() {
  local destination=$1
  local host=$2
  local flake_ref="$destination#homeConfigurations.${host}.activationPackage"
  local activation_package

  nix flake metadata "$destination" >/dev/null \
    || fail 'flake metadata validation failed'
  nix eval --raw "$flake_ref.drvPath" >/dev/null \
    || fail "host output is unavailable or invalid: $host"

  printf 'Apply Home Manager configuration for %s now? [y/N] ' "$host" >&2
  local answer
  IFS= read -r answer || true
  case "$answer" in
    y|Y|yes|YES) ;;
    *) log 'Activation skipped; checkout and identity setup are complete'; return 0 ;;
  esac

  activation_package=$(nix build --no-link --print-out-paths "$flake_ref") \
    || fail 'Home Manager activation package build failed'
  [ -x "$activation_package/activate" ] \
    || fail 'built activation package has no executable activate script'
  log "Activating Home Manager host ${host}"
  "$activation_package/activate" || fail 'Home Manager activation failed'
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local host
  host=$(select_host "${1:-}")
  local destination=${2:-${NIX_CONFIG_REPOSITORY:-$DEFAULT_DESTINATION}}
  local identity=${SOPS_AGE_KEY_FILE:-$AGE_IDENTITY_DEFAULT}
  case "$identity" in
    "$destination"|"$destination"/*)
      fail 'the age identity must be provisioned outside the repository checkout'
      ;;
  esac

  ensure_nix
  ensure_flakes
  ensure_tools
  verify_age_identity
  verify_github_auth
  clone_repository "$destination"
  apply_home "$destination" "$host"
  log "Bootstrap complete for ${host}"
}

main "$@"
