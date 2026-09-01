#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
container_name=${INTERACTIVE_CONTAINER_NAME:-nix-config-interactive}
base_name=${INCUS_VALIDATION_BASE:-nix-config-validation-base}
snapshot_name=${INCUS_VALIDATION_SNAPSHOT:-prepared}

if ! command -v incus >/dev/null 2>&1; then
  printf '%s\n' 'test-interactive: Incus is required; install and initialize it first' >&2
  exit 1
fi
if ! incus info >/dev/null 2>&1; then
  printf '%s\n' 'test-interactive: cannot connect to Incus; run incus admin init first' >&2
  exit 1
fi
if ! incus info "$base_name/snapshots/$snapshot_name" >/dev/null 2>&1; then
  printf '%s\n' "test-interactive: base snapshot is missing; run make incus-validation first" >&2
  exit 1
fi

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  incus delete --force "$container_name" >/dev/null 2>&1 || true
  if [ "$status" -eq 130 ]; then
    printf '%s\n' 'test-interactive: shell stopped gracefully (instance removed)'
    status=0
  fi
  if [ "$status" -eq 0 ] && [ "${INTERACTIVE_SMOKE:-0}" = 1 ]; then
    printf '%s\n' 'test-interactive: smoke passed (instance removed)'
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

incus delete --force "$container_name" >/dev/null 2>&1 || true
incus copy "$base_name/snapshots/$snapshot_name" "$container_name"
incus config device add "$container_name" source disk source="$repo_root" path=/source readonly=true
incus start "$container_name"

printf '%s\n' 'test-interactive: type exit or press Ctrl-D to stop zsh; cleanup is automatic'
set +e
incus exec --mode interactive \
  --cwd /source \
  --env 'NIX_CONFIG=experimental-features = nix-command flakes' \
  --env INTERACTIVE_SMOKE="${INTERACTIVE_SMOKE:-0}" \
  "$container_name" -- \
  bash -lc 'nix shell nixpkgs#coreutils nixpkgs#git nixpkgs#glibc.bin nixpkgs#glibcLocales nixpkgs#libiconv nixpkgs#util-linux nixpkgs#python3 nixpkgs#gcc nixpkgs#gnumake nixpkgs#gnused --command bash /source/tests/interactive-entrypoint.sh'
status=$?
set -e
exit "$status"
