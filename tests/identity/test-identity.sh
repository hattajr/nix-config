#!/usr/bin/env bash
# Ensure Home Manager uses the invoking account rather than repository-owner defaults.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
eval_home() {
  NIX_CONFIG='experimental-features = nix-command flakes' \
    NIX_CONFIG_USERNAME=alice NIX_CONFIG_HOME=/home/alice \
    nix eval --impure --raw "path:$repo_root#homeConfigurations.x86_64-linux.config.home.$1"
}

[ "$(eval_home username)" = alice ] || { echo 'identity test: explicit username was ignored' >&2; exit 1; }
[ "$(eval_home homeDirectory)" = /home/alice ] || { echo 'identity test: explicit home directory was ignored' >&2; exit 1; }
printf '%s\n' 'identity test: PASSED (non-hattajr Home Manager identity)'
