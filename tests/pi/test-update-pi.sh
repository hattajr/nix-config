#!/usr/bin/env bash
# Exercise real tar/JSON/npm handling; registry and Nix are stubbed to keep
# failure/rollback cases offline and avoid repeated platform builds.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export FIXTURE_ROOT="$work"
mkdir -p "$work/bin" "$work/checkout/home/modules" "$work/checkout/scripts"
cp "$repo_root/scripts/patch-pi-package.sh" "$work/checkout/scripts/"
cp "$repo_root/home/modules/pi.nix" "$work/original.nix"

cat >"$work/bin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  *pi-coding-agent/latest*)
    printf '{"version":"9.0.0","dist":{"tarball":"https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-9.0.0.tgz"}}\n' ;;
  *--output*)
    while [ "$1" != --output ]; do shift; done
    cp "$FIXTURE_ROOT/pi.tgz" "$2" ;;
  *@earendil-works%2Fpi-ai/8.0.0*)
    printf '{"dist":{"integrity":"sha512-fixture-integrity"}}\n' ;;
  *) printf 'unexpected registry request: %s\n' "$*" >&2; exit 1 ;;
esac
SH
cat >"$work/bin/nix" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  store) printf '{"hash":"sha256-source-fixture="}\n' ;;
  eval)
    [ "${FAIL_STAGE:-}" != eval ] || { echo 'evaluation failed' >&2; exit 1; }
    case "$*" in
      *builtins.currentSystem*) printf 'aarch64-darwin' ;;
      *) printf '/nix/store/fixture-home.drv' ;;
    esac ;;
  build)
    [ "${FAIL_STAGE:-}" != hash ] || { echo 'dependency fetch failed' >&2; exit 1; }
    if grep -q 'npmDepsHash = "sha256-AAAAAAAA' "$FIXTURE_ROOT/checkout/home/modules/pi.nix"; then
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
printf '/nix/store/fixture-pi-coding-agent-9.0.0-npm-deps.drv\n'
SH
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

prepare() {
  cp "$work/original.nix" "$work/checkout/home/modules/pi.nix"
  rm -f "$work/checkout/home/modules/pi-package-lock.json"
  rm -rf "$work/package"
  mkdir "$work/package"
  cat >"$work/package/package.json" <<'JSON'
{
  "name": "@earendil-works/pi-coding-agent", "version": "9.0.0",
  "bin": {"pi": "dist/bundle/cli.js"},
  "devDependencies": {"nonexistent-test-only-fixture": "0.0.0"},
  "scripts": {"install": "exit 42"}
}
JSON
}
pack() { tar -czf "$work/pi.tgz" -C "$work" package; }
run_update() { "$repo_root/scripts/update-pi" "$work/checkout" >"$work/output" 2>&1; }
assert_pin() {
  grep -q 'version = "9.0.0";' "$work/checkout/home/modules/pi.nix"
  grep -Fq 'cp ${./pi-package-lock.json} npm-shrinkwrap.json' "$work/checkout/home/modules/pi.nix"
  grep -q 'npmDepsHash = "sha256-ZGVwZW5kZW5jeQ==";' "$work/checkout/home/modules/pi.nix"
}

# Regression: no upstream lockfile. Real npm must generate a runtime-only lock
# without running install scripts or resolving the deliberately invalid dev dep.
prepare
pack
run_update
assert_pin
jq -e '.version == "9.0.0" and (.packages | keys == [""]) and
  (.packages[""] | has("devDependencies") | not)' \
  "$work/checkout/home/modules/pi-package-lock.json" >/dev/null

# Legacy shrinkwrap repair uses the dependency version, not the application
# version, and locks with no missing integrities are valid too.
for format in npm-shrinkwrap.json package-lock.json; do
  for integrity in missing present; do
    prepare
    cat >"$work/package/$format" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","version":"9.0.0","lockfileVersion":3,
 "packages":{"":{"name":"@earendil-works/pi-coding-agent","version":"9.0.0"},
 "node_modules/@earendil-works/pi-ai":{"version":"8.0.0",
 "resolved":"https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-8.0.0.tgz"}}}
JSON
    if [ "$integrity" = present ]; then
      jq '.packages["node_modules/@earendil-works/pi-ai"].integrity = "sha512-existing"' \
        "$work/package/$format" >"$work/complete.json"
      mv "$work/complete.json" "$work/package/$format"
    fi
    pack
    run_update
    assert_pin
    expected=sha512-fixture-integrity
    [ "$integrity" != present ] || expected=sha512-existing
    jq -e --arg expected "$expected" \
      '.packages["node_modules/@earendil-works/pi-ai"].integrity == $expected' \
      "$work/checkout/home/modules/pi-package-lock.json" >/dev/null
  done
done
cp "$work/checkout/home/modules/pi-package-lock.json" "$work/complete.json"

# A malformed lockfile must fail, rather than masquerade as an empty repair set.
prepare
printf '{invalid json\n' >"$work/package/npm-shrinkwrap.json"
pack
if run_update; then echo 'malformed lockfile was accepted' >&2; exit 1; fi
cmp "$work/original.nix" "$work/checkout/home/modules/pi.nix"
test ! -e "$work/checkout/home/modules/pi-package-lock.json"

# Failures after mutation restore both pins, including the absence of an old
# lockfile. Missing hash diagnostics must expose the actual Nix failure.
for previous in absent present; do
  for stage in eval hash verify; do
    prepare
    cp "$work/complete.json" "$work/package/npm-shrinkwrap.json"
    if [ "$previous" = present ]; then
      printf 'previous lockfile\n' >"$work/checkout/home/modules/pi-package-lock.json"
      cp "$work/checkout/home/modules/pi-package-lock.json" "$work/previous-lock"
    fi
    pack
    if FAIL_STAGE="$stage" run_update; then echo "accepted failed $stage" >&2; exit 1; fi
    cmp "$work/original.nix" "$work/checkout/home/modules/pi.nix"
    if [ "$previous" = present ]; then
      cmp "$work/previous-lock" "$work/checkout/home/modules/pi-package-lock.json"
    else
      test ! -e "$work/checkout/home/modules/pi-package-lock.json"
    fi
    [ "$stage" != hash ] || grep -q 'dependency fetch failed' "$work/output"
  done
done

# Re-running a successful update does not resolve or rewrite the dependency pin.
prepare
cp "$work/complete.json" "$work/package/npm-shrinkwrap.json"
pack
run_update
cp "$work/checkout/home/modules/pi-package-lock.json" "$work/success-lock"
run_update
grep -q 'already pinned to 9.0.0' "$work/output"
cmp "$work/success-lock" "$work/checkout/home/modules/pi-package-lock.json"

printf 'Pi updater tests: PASSED (missing/published locks, integrity repair, rollback, no-op)\n'
