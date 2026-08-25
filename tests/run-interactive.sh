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
printf '%s\n' 'test-interactive: type exit or press Ctrl-D to stop zsh and remove the disposable container'

set +e
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
docker_status=$?
set -e

# Docker normally removes the container itself via --rm. If the terminal sends
# an interrupt while the interactive TTY is closing, wait for that result and
# force-remove any leftover container before deciding what to return.
if docker container inspect "$container_name" >/dev/null 2>&1; then
  printf 'test-interactive: cleaning up %s\n' "$container_name"
  docker container rm -f "$container_name" >/dev/null 2>&1 || true
fi

# Closing an interactive TTY can be reported as SIGINT (130) even when the
# user is simply leaving the shell. Treat that as a graceful disposable-shell
# exit; real setup/application failures still return their original status.
if [ "$docker_status" -eq 130 ]; then
  printf '%s\n' 'test-interactive: shell stopped gracefully (container removed)'
  exit 0
fi
if [ "$docker_status" -ne 0 ]; then
  exit "$docker_status"
fi

if [ "${INTERACTIVE_SMOKE:-0}" = 1 ]; then
  printf '%s\n' 'test-interactive: smoke passed (container removed)'
fi
