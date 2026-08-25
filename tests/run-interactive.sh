#!/usr/bin/env bash
set -euo pipefail

repo_root=$(
  CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
  pwd
)
container_name=${INTERACTIVE_CONTAINER_NAME:-nix-config-interactive}
image_tag=${INTERACTIVE_IMAGE:-nixos/nix:2.28.0}

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' 'test-interactive: Docker is required' >&2
  exit 1
fi

if docker container inspect "$container_name" >/dev/null 2>&1; then
  printf 'test-interactive: container already exists: %s\n' "$container_name" >&2
  printf 'test-interactive: remove it with: docker rm -f %s\n' "$container_name" >&2
  exit 1
fi

printf 'test-interactive: starting %s\n' "$container_name"
printf '%s\n' 'test-interactive: Ctrl-D exits zsh and removes the disposable container'

docker run --rm \
  --init \
  --user root \
  --name "$container_name" \
  --interactive \
  --tty \
  --volume "$repo_root:/source:ro" \
  --workdir /source \
  --env NIX_CONFIG='experimental-features = nix-command flakes' \
  --env INTERACTIVE_SMOKE="${INTERACTIVE_SMOKE:-0}" \
  "$image_tag" \
  bash -lc 'nix shell nixpkgs#coreutils nixpkgs#git nixpkgs#glibc.bin nixpkgs#glibcLocales nixpkgs#libiconv nixpkgs#util-linux nixpkgs#python3 nixpkgs#gcc nixpkgs#gnumake nixpkgs#gnused --command bash /source/tests/interactive-entrypoint.sh'

if [ "${INTERACTIVE_SMOKE:-0}" = 1 ]; then
  if docker container inspect "$container_name" >/dev/null 2>&1; then
    printf 'test-interactive: FAIL: --rm did not remove %s\n' "$container_name" >&2
    exit 1
  fi
  printf '%s\n' 'test-interactive: smoke passed (container removed)'
fi
