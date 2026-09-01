#!/usr/bin/env bash
# Create a reusable, user-owned Nix fixture. Run through make incus-alice-validation.
set -euo pipefail

instance=$1
incus exec "$instance" -- bash -euxc '
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git sudo xz-utils
  id alice >/dev/null 2>&1 || useradd --create-home --shell /bin/bash alice
  install -d -o alice -g alice /home/alice/.cache
'
# This is intentionally the official single-user installer, not NixOS/system Nix.
incus exec "$instance" -- su - alice -s /bin/bash -c '
  export HOME=/home/alice
  curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
  test -r "$HOME/.nix-profile/etc/profile.d/nix.sh"
  "$HOME/.nix-profile/bin/nix" --version
  printf "single-user-nix-v1\n" > "$HOME/.nix-config-incus-fixture"
'
