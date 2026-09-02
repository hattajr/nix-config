#!/usr/bin/env bash
# Fast host validation: evaluate every advertised platform and build the native one.
set -euo pipefail

repo_root=${SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
flake_source="path:$repo_root"

case "$(uname -s):$(uname -m)" in
Darwin:arm64 | Darwin:aarch64) native=aarch64-darwin ;;
Linux:arm64 | Linux:aarch64) native=aarch64-linux ;;
Linux:x86_64 | Linux:amd64) native=x86_64-linux ;;
*)
  printf 'flake validation: unsupported host %s/%s\n' "$(uname -s)" "$(uname -m)" >&2
  exit 1
  ;;
esac

export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}experimental-features = nix-command flakes"
for platform in aarch64-darwin aarch64-linux x86_64-linux; do
  nix eval --impure --raw \
    "$flake_source#homeConfigurations.$platform.activationPackage.drvPath" >/dev/null
done
nix build --impure --no-link "$flake_source#homeConfigurations.$native.activationPackage"
printf 'flake validation: PASSED (all outputs evaluated; %s activation built)\n' "$native"
