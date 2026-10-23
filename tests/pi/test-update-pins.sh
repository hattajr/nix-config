#!/usr/bin/env bash
# Verify commit/discard behavior with real Git, without activation or network.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
source "$repo_root/scripts/lib/core.sh"
source "$repo_root/scripts/lib/actions.sh"
run_git() { git "$@"; }
log() { printf '%s\n' "$*" >>"$work/messages"; }
warn() { printf '%s\n' "$*" >&2; }
fail() { warn "$*"; exit 1; }
apply() { :; }
print_update_summary() { :; }
confirm() {
  case "$1" in
    'Commit these version-pin changes?') return 0 ;;
    *) return 1 ;;
  esac
}

# The review choice replays ANSWERS in order: an option number, or esc to
# leave the choice. Asking more often than scripted is a failure.
answers=()
choose() {
  [ "${#answers[@]}" -gt 0 ] || fail "unexpected choice: $1"
  local answer=${answers[0]}
  answers=("${answers[@]:1}")
  [ "$answer" != esc ] || return 1
  CHOICE_INDEX=$answer
}

readonly APPLY=1 SHOW_DIFF=2 DISCARD=3

# Runs update_pins with the review answers that follow ARGS, then checks every
# answer was used.
update_with_answers() {
  local checkout=$1 && shift
  local args=() && while [ "$1" != -- ]; do args+=("$1"); shift; done && shift
  answers=("$@")
  : >"$work/messages"
  update_pins "$checkout" "${args[@]}" >"$work/output"
  [ "${#answers[@]}" = 0 ] || fail "the review choice was not asked again for: ${answers[*]}"
}

new_checkout() {
  checkout="$work/$1"
  mkdir -p "$checkout/home/modules" "$checkout/scripts"
  git -C "$checkout" init -q
  git -C "$checkout" config user.name 'Updater Test'
  git -C "$checkout" config user.email 'updater@example.invalid'
  printf '{}\n' >"$checkout/flake.lock"
}

commit_fixture() {
  git -C "$checkout" add .
  git -C "$checkout" commit -qm 'Initial fixture'
}

write_pi_updater() {
  printf 'original module\n' >"$checkout/home/modules/pi.nix"
  cat >"$checkout/scripts/update-pi" <<'SH'
#!/bin/sh
printf 'updated module\n' >"$1/home/modules/pi.nix"
printf 'updated lock\n' >"$1/home/modules/pi-package-lock.json"
SH
  chmod +x "$checkout/scripts/update-pi"
}

# Show diff includes the generated lockfile and returns to the choice, which
# then discards or applies and commits.
for previous in absent present; do
  for decision in discard commit; do
    new_checkout "$previous-$decision"
    write_pi_updater
    if [ "$previous" = present ]; then
      printf 'original lock\n' >"$checkout/home/modules/pi-package-lock.json"
    fi
    commit_fixture

    final=$DISCARD
    [ "$decision" != commit ] || final=$APPLY
    update_with_answers "$checkout" aarch64-darwin no yes -- "$SHOW_DIFF" "$final"
    grep -q '^+updated lock$' "$work/output"
    test -z "$(git -C "$checkout" status --porcelain)"
    if [ "$decision" = commit ]; then
      test "$(git -C "$checkout" show HEAD:home/modules/pi-package-lock.json)" = 'updated lock'
      test "$(git -C "$checkout" show HEAD:home/modules/pi.nix)" = 'updated module'
      test "$(git -C "$checkout" log -1 --format=%s)" = 'Update managed package pins'
    else
      grep -Fxq 'update discarded' "$work/messages"
      test "$(git -C "$checkout" show HEAD:home/modules/pi.nix)" = 'original module'
      if [ "$previous" = present ]; then
        grep -qx 'original lock' "$checkout/home/modules/pi-package-lock.json"
      else
        test ! -e "$checkout/home/modules/pi-package-lock.json"
      fi
    fi
  done
done

# playwright-cli pins are tracked files; discard restores and commit records both.
for decision in discard commit; do
  new_checkout "playwright-$decision"
  printf 'original module\n' >"$checkout/home/modules/playwright-cli.nix"
  printf 'original lock\n' >"$checkout/home/modules/playwright-cli-package-lock.json"
  cat >"$checkout/scripts/update-playwright-cli" <<'SH'
#!/bin/sh
printf 'updated module\n' >"$1/home/modules/playwright-cli.nix"
printf 'updated lock\n' >"$1/home/modules/playwright-cli-package-lock.json"
SH
  chmod +x "$checkout/scripts/update-playwright-cli"
  commit_fixture

  final=$DISCARD
  [ "$decision" != commit ] || final=$APPLY
  update_with_answers "$checkout" x86_64-linux no no yes -- "$final"
  test -z "$(git -C "$checkout" status --porcelain)"
  expected=original
  [ "$decision" != commit ] || expected=updated
  test "$(git -C "$checkout" show HEAD:home/modules/playwright-cli.nix)" = "$expected module"
  test "$(git -C "$checkout" show HEAD:home/modules/playwright-cli-package-lock.json)" = "$expected lock"
done

# Leaving the choice discards, as declining to apply always has: the tracked
# pin is restored and the generated lockfile removed.
new_checkout leave
write_pi_updater
commit_fixture
head=$(git -C "$checkout" rev-parse HEAD)
update_with_answers "$checkout" aarch64-darwin no yes -- esc
grep -Fxq 'update discarded' "$work/messages"
test -z "$(git -C "$checkout" status --porcelain --untracked-files=all)"
test "$(git -C "$checkout" rev-parse HEAD)" = "$head"

# Pins that are already current are reported, and there is nothing to choose.
new_checkout current
printf 'original module\n' >"$checkout/home/modules/pi.nix"
printf '#!/bin/sh\n' >"$checkout/scripts/update-pi"
chmod +x "$checkout/scripts/update-pi"
commit_fixture
update_with_answers "$checkout" aarch64-darwin no yes --
grep -Fxq 'all selected pins are already current' "$work/messages"
test -z "$(git -C "$checkout" status --porcelain)"

printf 'Pi pin workflow tests: PASSED (show diff, then commit/discard new and tracked lockfiles, playwright-cli pins, leaving the choice, already current)\n'
