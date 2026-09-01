#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image=${INCUS_VALIDATION_IMAGE:-images:nixos/24.11}
base_name=${INCUS_VALIDATION_BASE:-nix-config-validation-base}
snapshot_name=${INCUS_VALIDATION_SNAPSHOT:-prepared}
run_name="nix-config-validation-${USER:-unknown}-$$"
run_name=${run_name//[^[:alnum:].-]/-}

if ! command -v incus >/dev/null 2>&1; then
  printf '%s\n' 'incus-validation: Incus is required; install and initialize it first' >&2
  exit 77
fi
if ! incus info >/dev/null 2>&1; then
  printf '%s\n' 'incus-validation: cannot connect to Incus; run incus admin init first' >&2
  exit 77
fi

cleanup() {
  incus delete --force "$run_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if ! incus info "$base_name" >/dev/null 2>&1; then
  printf 'incus-validation: creating base instance from %s\n' "$image"
  incus launch "$image" "$base_name"
  # Nix's build sandbox creates nested mount namespaces.
  incus config set "$base_name" security.nesting=true
  incus stop "$base_name"
fi

if ! incus info "$base_name/snapshots/$snapshot_name" >/dev/null 2>&1; then
  if incus info "$base_name" | grep -q '^Status: RUNNING'; then
    incus stop "$base_name"
  fi
  printf 'incus-validation: snapshotting reusable base as %s/%s\n' "$base_name" "$snapshot_name"
  incus snapshot create "$base_name" "$snapshot_name"
fi

printf '%s\n' 'incus-validation: launching disposable test instance from base snapshot'
incus copy "$base_name/snapshots/$snapshot_name" "$run_name"
incus config device add "$run_name" source disk source="$repo_root" path=/source readonly=true
incus start "$run_name"

printf '%s\n' 'incus-validation: running isolated validation'
incus exec "$run_name" -- /source/tests/validate-home.sh
