#!/usr/bin/env bash
# Background jobs reach Home Manager only through mkHome's jobs argument, and
# only an enabled job installs systemd user units. Nothing here activates.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}experimental-features = nix-command flakes"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'background jobs test: %s\n' "$1" >&2
  exit 1
}

# Evaluates an expression over `home`, an account built through mkHome.
eval_home() {
  local system=$1 jobs=$2 expression=$3
  nix eval --impure --json --expr \
    "let home = (builtins.getFlake \"path:$repo_root\").lib.mkHome {
        system = \"$system\";
        username = \"alice\";
        homeDirectory = \"/home/alice\";
        jobs = $jobs;
      }; in $expression"
}

# The unit files Home Manager would link under ~/.config/systemd/user.
board_sync_units='builtins.filter (name: builtins.match "systemd/user/gh-board-sync[.].*" name != null)
  (builtins.attrNames home.config.xdg.configFile)'

[ "$(eval_home x86_64-linux '[ ]' "$board_sync_units")" = '[]' ] \
  || fail 'a configuration with no jobs has a Board sync unit'
[ "$(eval_home x86_64-linux '[ "board-sync" ]' "$board_sync_units")" \
  = '["systemd/user/gh-board-sync.service","systemd/user/gh-board-sync.timer"]' ] \
  || fail 'enabling board-sync did not install both the service and the timer'

# Committed outputs never run a job, whoever evaluates them.
committed=$(nix eval --json "path:$repo_root#homeConfigurations.\"x86_64-linux\".config.xdg.configFile" \
  --apply 'files: builtins.filter (name: builtins.match "systemd/user/gh-board-sync[.].*" name != null) (builtins.attrNames files)')
[ "$committed" = '[]' ] || fail "the committed x86_64-linux configuration installs Board sync ($committed)"

unit_text() {
  eval_home x86_64-linux '[ "board-sync" ]' \
    "builtins.readFile home.config.xdg.configFile.\"systemd/user/gh-board-sync.$1\".source" | jq -r .
}
timer=$(unit_text timer)
for line in OnCalendar=hourly Persistent=true WantedBy=timers.target; do
  grep -Fxq "$line" <<<"$timer" || fail "the timer lacks $line"
done
service=$(unit_text service)
grep -Eq '^ExecStart=/nix/store/[^ ]+-gh-board/bin/gh-board sync$' <<<"$service" \
  || fail 'the service does not run the packaged gh-board sync'
grep -Fxq Type=oneshot <<<"$service" || fail 'the service is not a oneshot'

# An unknown job and a job on macOS are refused rather than silently dropped.
if output=$(eval_home x86_64-linux '[ "weekly-backup" ]' 'home.activationPackage.drvPath' 2>&1); then
  fail 'an unknown job was accepted'
fi
grep -Fq '"weekly-backup"' <<<"$output" || fail 'rejecting an unknown job did not name it'
if output=$(eval_home aarch64-darwin '[ "board-sync" ]' 'home.activationPackage.drvPath' 2>&1); then
  fail 'a background job was accepted on macOS'
fi
grep -Fq 'only supported on Linux' <<<"$output" || fail 'rejecting a macOS job did not explain why'

# bro's own expression carries the state file to mkHome: write the state the
# way the Jobs menu does, then evaluate exactly what Apply would build.
bro_jobs() {
  local expression
  expression=$(env -u XDG_STATE_HOME HOME="$work/home" USER=alice bash -c '
    set -euo pipefail
    . "$1/scripts/lib/core.sh"
    . "$1/scripts/lib/nix.sh"
    resolve_identity
    [ "$2" = missing ] || write_background_jobs $2
    home_expr "$1" x86_64-linux config.nixConfig.backgroundJobs' _ "$repo_root" "$1")
  nix eval --impure --json --expr "$expression"
}
mkdir -p "$work/home"
[ "$(bro_jobs missing)" = '[]' ] || fail 'a missing state file did not mean no jobs'
[ "$(bro_jobs board-sync)" = '["board-sync"]' ] || fail 'a saved job did not reach mkHome'
[ "$(cat "$work/home/.local/state/bro/background-jobs")" = board-sync ] \
  || fail 'the state file did not hold the saved job'
[ "$(bro_jobs '')" = '[]' ] || fail 'an emptied state file still enabled a job'

printf '%s\n' 'background jobs test: PASSED (units only when enabled, committed outputs clean, state file reaches mkHome)'
