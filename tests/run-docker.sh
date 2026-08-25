#!/usr/bin/env bash
set -euo pipefail

repo_root=$(
  CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
  pwd
)

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' 'docker-validation: SKIP: Docker is required' >&2
  exit 77
fi

image_tag="nix-config-validation:${USER:-unknown}-$$"
cleanup() {
  docker image rm --force "$image_tag" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%s\n' 'docker-validation: building disposable validation image'
docker build --quiet --file "$repo_root/tests/Dockerfile" --tag "$image_tag" "$repo_root/tests" >/dev/null

printf '%s\n' 'docker-validation: running isolated validation container'
exec docker run --rm \
  --init \
  --user root \
  --volume "$repo_root:/source:ro" \
  --tmpfs /tmp:exec,mode=1777 \
  "$image_tag"
