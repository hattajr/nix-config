#!/usr/bin/env bash
# Disposable SOPS/age authorization test.
#
# All cryptographic operations run inside a removed Nix Docker container.
# Identities and fake plaintext are generated there and never written here.
set -euo pipefail

repo_root=$(
    CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
    pwd
)

if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' 'test-sops: SKIP: docker is required for ephemeral testing' >&2
    exit 77
fi

image=${NIX_IMAGE:-nixos/nix:2.28.0}

exec docker run --rm \
    --volume "$repo_root:/source:ro" \
    "$image" \
    nix --extra-experimental-features 'nix-command flakes' \
    shell nixpkgs#age nixpkgs#sops nixpkgs#git nixpkgs#gawk nixpkgs#gnused \
    --command sh /source/tests/sops/fixtures/run-in-container.sh
