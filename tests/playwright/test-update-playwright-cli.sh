#!/usr/bin/env bash
# Exercise real tar/JSON/npm/sed handling; registry and Nix are stubbed to keep
# failure/rollback cases offline and avoid repeated platform builds.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export FIXTURE_ROOT="$work"
module="$work/checkout/home/modules/playwright-cli.nix"
module_lock="$work/checkout/home/modules/playwright-cli-package-lock.json"
mkdir -p "$work/bin" "$work/checkout/home/modules"
cp "$repo_root/home/modules/playwright-cli.nix" "$work/original.nix"
cp "$repo_root/home/modules/playwright-cli-package-lock.json" "$work/original-lock.json"
current_version=$(sed -n 's/^[[:space:]]*version = "\([^"]*\)";.*/\1/p' "$work/original.nix")

cat >"$work/bin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  *@playwright%2Fcli/latest*)
    printf '{"version":"%s","dist":{"tarball":"https://registry.npmjs.org/@playwright/cli/-/cli-9.0.0.tgz"}}\n' \
      "${FIXTURE_VERSION:-9.0.0}" ;;
  *--output*)
    while [ "$1" != --output ]; do shift; done
    cp "$FIXTURE_ROOT/cli.tgz" "$2" ;;
  *) printf 'unexpected registry request: %s\n' "$*" >&2; exit 1 ;;
esac
SH
cat >"$work/bin/nix" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  store) printf '{"hash":"sha256-c291cmNlLWZpeHR1cmU="}\n' ;;
  eval)
    [ "${FAIL_STAGE:-}" != eval ] || { echo 'evaluation failed' >&2; exit 1; }
    case "$*" in
      *builtins.currentSystem*) printf 'x86_64-linux' ;;
      *) printf '/nix/store/fixture-home.drv' ;;
    esac ;;
  build)
    [ "${FAIL_STAGE:-}" != hash ] || { echo 'dependency fetch failed' >&2; exit 1; }
    if grep -q 'npmDepsHash = "sha256-AAAAAAAA' "$FIXTURE_ROOT/checkout/home/modules/playwright-cli.nix"; then
      printf 'error: hash mismatch\n  got: sha256-ZGVwZW5kZW5jeQ==\n' >&2
      exit 1
    fi
    [ "${FAIL_STAGE:-}" != verify ] || { echo 'verification failed' >&2; exit 1; }
    ;;
  *) exit 1 ;;
esac
SH
cat >"$work/bin/nix-store" <<'SH'
#!/bin/sh
printf '/nix/store/fixture-playwright-cli-9.0.0-npm-deps.drv\n'
SH
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

prepare() {
  cp "$work/original.nix" "$module"
  cp "$work/original-lock.json" "$module_lock"
  rm -rf "$work/package"
  mkdir "$work/package"
  cat >"$work/package/package.json" <<'JSON'
{
  "name": "@playwright/cli", "version": "9.0.0",
  "bin": {"playwright-cli": "playwright-cli.js"},
  "scripts": {"install": "exit 42"}
}
JSON
  tar -czf "$work/cli.tgz" -C "$work" package
}
run_update() { "$repo_root/scripts/update-playwright-cli" "$work/checkout" >"$work/output" 2>&1; }

# No upstream lockfile: real npm generates one without running the package's
# install script, and every pinned field is rewritten while the npmDepsHash
# line stays distinct from the source hash.
prepare
run_update
grep -q 'version = "9.0.0";' "$module"
grep -q '^      hash = "sha256-c291cmNlLWZpeHR1cmU=";' "$module"
grep -q 'npmDepsHash = "sha256-ZGVwZW5kZW5jeQ==";' "$module"
grep -Fq 'url = "https://registry.npmjs.org/@playwright/cli/-/cli-${version}.tgz";' "$module"
jq -e '.version == "9.0.0" and (.packages | keys == [""])' "$module_lock" >/dev/null

# Failures after mutation restore both the module and its lockfile.
for stage in eval hash verify; do
  prepare
  if FAIL_STAGE="$stage" run_update; then echo "accepted failed $stage" >&2; exit 1; fi
  cmp "$work/original.nix" "$module"
  cmp "$work/original-lock.json" "$module_lock"
  [ "$stage" != hash ] || grep -q 'dependency fetch failed' "$work/output"
done

# The current version is a no-op that touches nothing.
prepare
FIXTURE_VERSION="$current_version" run_update
grep -q "already pinned to $current_version" "$work/output"
cmp "$work/original.nix" "$module"
cmp "$work/original-lock.json" "$module_lock"

printf 'playwright-cli updater tests: PASSED (generated lock, field rewrite, rollback, no-op)\n'
