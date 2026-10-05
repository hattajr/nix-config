#!/usr/bin/env bash
# Verify commit/discard behavior with real Git, without activation or network.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
source "$repo_root/scripts/lib/actions.sh"
run_git() { git "$@"; }
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
fail() { warn "$*"; exit 1; }
apply() { :; }
print_update_summary() { :; }
confirm() {
  case "$1" in
    'Show the complete generated diff?') return 0 ;;
    'Apply these changes on this machine?') [ "$decision" = commit ] ;;
    'Commit these version-pin changes?') return 0 ;;
    *) return 1 ;;
  esac
}

for previous in absent present; do
  for decision in discard commit; do
    checkout="$work/$previous-$decision"
    mkdir -p "$checkout/home/modules" "$checkout/scripts"
    git -C "$checkout" init -q
    git -C "$checkout" config user.name 'Updater Test'
    git -C "$checkout" config user.email 'updater@example.invalid'
    printf 'original module\n' >"$checkout/home/modules/pi.nix"
    printf '{}\n' >"$checkout/flake.lock"
    if [ "$previous" = present ]; then
      printf 'original lock\n' >"$checkout/home/modules/pi-package-lock.json"
    fi
    cat >"$checkout/scripts/update-pi" <<'SH'
#!/bin/sh
printf 'updated module\n' >"$1/home/modules/pi.nix"
printf 'updated lock\n' >"$1/home/modules/pi-package-lock.json"
SH
    chmod +x "$checkout/scripts/update-pi"
    git -C "$checkout" add .
    git -C "$checkout" commit -qm 'Initial fixture'

    update_pins "$checkout" aarch64-darwin no yes >"$work/output"
    grep -q '^+updated lock$' "$work/output"
    test -z "$(git -C "$checkout" status --porcelain)"
    if [ "$decision" = commit ]; then
      test "$(git -C "$checkout" show HEAD:home/modules/pi-package-lock.json)" = 'updated lock'
      test "$(git -C "$checkout" show HEAD:home/modules/pi.nix)" = 'updated module'
    else
      test "$(git -C "$checkout" show HEAD:home/modules/pi.nix)" = 'original module'
      if [ "$previous" = present ]; then
        grep -qx 'original lock' "$checkout/home/modules/pi-package-lock.json"
      else
        test ! -e "$checkout/home/modules/pi-package-lock.json"
      fi
    fi
  done
done
printf 'Pi pin workflow tests: PASSED (commit/discard new and tracked lockfiles)\n'
