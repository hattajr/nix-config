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

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if docker container inspect "$container_name" >/dev/null 2>&1; then
    printf 'test-interactive: removing %s\n' "$container_name"
    docker container rm -f "$container_name" >/dev/null 2>&1 || true
  fi

  # Closing an interactive TTY can be reported as SIGINT (130) even when the
  # user is simply leaving the shell. Treat that as a graceful disposable-shell
  # exit; real setup/application failures still return their original status.
  if [ "$status" -eq 130 ]; then
    printf '%s\n' 'test-interactive: shell stopped gracefully (container removed)'
    status=0
  fi
  if [ "$status" -eq 0 ] && [ "${INTERACTIVE_SMOKE:-0}" = 1 ]; then
    printf '%s\n' 'test-interactive: smoke passed (container removed)'
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A previous interrupted run must never block the next fully automated run.
if docker container inspect "$container_name" >/dev/null 2>&1; then
  printf 'test-interactive: removing previous %s\n' "$container_name"
  docker container rm -f "$container_name" >/dev/null 2>&1 || {
    printf 'test-interactive: could not remove previous %s\n' "$container_name" >&2
    exit 1
  }
fi

printf 'test-interactive: starting %s\n' "$container_name"
printf '%s\n' 'test-interactive: type exit or press Ctrl-D to stop zsh; cleanup is automatic'

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
exit "$docker_status"
