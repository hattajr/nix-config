#!/usr/bin/env bash
set -euo pipefail

repo_root=${BOOTSTRAP_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
package_json="$work/package with spaces.json"

cat >"$package_json" <<'JSON'
{
  "name": "fixture",
  "dependencies": {"runtime": "1.0.0"},
  "devDependencies": {"test-only": "2.0.0"},
  "scripts": {"start": "fixture"}
}
JSON

"$repo_root/scripts/patch-pi-package.sh" "$package_json"
jq -e '.name == "fixture" and .dependencies.runtime == "1.0.0" and .scripts.start == "fixture"' \
  "$package_json" >/dev/null
jq -e 'has("devDependencies") | not' "$package_json" >/dev/null

# Reapplying the structural patch is harmless and must retain runtime fields.
"$repo_root/scripts/patch-pi-package.sh" "$package_json"
jq -e '.dependencies.runtime == "1.0.0" and (has("devDependencies") | not)' \
  "$package_json" >/dev/null

printf 'Pi package patch test: PASSED (portable structural dependency removal)\n'
