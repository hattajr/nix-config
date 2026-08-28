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

# Keep the image and /nix store between runs. The source remains a read-only
# bind mount, so cached packages cannot hide repository changes. Set
# DOCKER_VALIDATION_CLEAN=1 to discard the cache after this run.
cache_key=${USER:-unknown}
cache_key=${cache_key//[^[:alnum:]_.-]/-}
image_tag="nix-config-validation:$cache_key"
nix_volume="nix-config-validation-nix-$cache_key"
docker volume create "$nix_volume" >/dev/null

cleanup() {
  if [ "${DOCKER_VALIDATION_CLEAN:-0}" = 1 ]; then
    docker image rm --force "$image_tag" >/dev/null 2>&1 || true
    docker volume rm --force "$nix_volume" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

printf '%s\n' 'docker-validation: building cached validation image'
docker build --quiet --file "$repo_root/tests/Dockerfile" --tag "$image_tag" "$repo_root/tests" >/dev/null

printf '%s\n' 'docker-validation: running isolated validation container'
docker run --rm \
  --init \
  --user root \
  --volume "$nix_volume:/nix" \
  --volume "$repo_root:/source:ro" \
  --tmpfs /tmp:exec,mode=1777 \
  "$image_tag"
