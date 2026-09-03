#!/usr/bin/env bash
# Ensure Home Manager uses the invoking account rather than repository-owner defaults.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}experimental-features = nix-command flakes"

# Mirrors how bro and the installer activate an account that is not committed
# in this repository.
eval_home() {
  nix eval --impure --raw --expr \
    "((builtins.getFlake \"path:$repo_root\").lib.mkHome {
        system = \"x86_64-linux\";
        username = \"alice\";
        homeDirectory = \"/home/alice\";
      }).config.home.$1"
}

[ "$(eval_home username)" = alice ] || { echo 'identity test: explicit username was ignored' >&2; exit 1; }
[ "$(eval_home homeDirectory)" = /home/alice ] || { echo 'identity test: explicit home directory was ignored' >&2; exit 1; }

# A committed configuration must never absorb the ambient account.
committed=$(NIX_CONFIG_USERNAME=alice NIX_CONFIG_HOME=/home/alice USER=alice \
  nix eval --raw "path:$repo_root#homeConfigurations.\"hattajr@latte\".config.home.username")
[ "$committed" = hattajr ] || {
  echo "identity test: committed configuration was altered by the environment ($committed)" >&2
  exit 1
}

# An unusable identity must fail at the call site, not deep in the module system.
if nix eval --impure --raw --expr \
  "((builtins.getFlake \"path:$repo_root\").lib.mkHome {
      system = \"x86_64-linux\"; username = \"\"; homeDirectory = \"/home/alice\";
    }).config.home.username" >/dev/null 2>&1; then
  echo 'identity test: an empty username was accepted' >&2
  exit 1
fi

printf '%s\n' 'identity test: PASSED (non-hattajr Home Manager identity)'
