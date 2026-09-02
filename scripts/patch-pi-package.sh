#!/usr/bin/env bash
# Remove development-only dependencies before Nix calculates Pi's npm closure.
set -euo pipefail

package_json=${1:?usage: patch-pi-package.sh PACKAGE_JSON}
jq_command=${JQ:-jq}
command -v "$jq_command" >/dev/null 2>&1 || {
  printf 'patch-pi-package: jq is required\n' >&2
  exit 127
}

temporary=$(mktemp "${package_json}.XXXXXX")
trap 'rm -f "$temporary"' EXIT
"$jq_command" 'del(.devDependencies)' "$package_json" >"$temporary"
mv -f "$temporary" "$package_json"
trap - EXIT
