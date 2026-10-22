#!/usr/bin/env bash
# Health reports the last Board sync run from systemd on a machine that enabled
# the job, warns without failing when that run failed or cannot be read, and
# says nothing about it on a machine that did not enable it.
#
# systemctl is a stub fed the property output systemd prints for each state, so
# the suite never reads or changes the developer's real user manager. The real
# systemctl is filtered off PATH entirely, which also covers a host without it.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'board sync health test: %s\n' "$1" >&2
  exit 1
}

health_home=$work/home
health_repo=$work/repo
mockbin=$work/mock
systemctl_bin=$work/systemctl
host_bin=$work/host
jobs_file=$health_home/.local/state/bro/background-jobs
systemctl_log=$work/systemctl.log
mkdir -p "$health_home/.nix-profile/bin" "$health_home/.local/bin" "$health_home/.config/tmux" \
  "$mockbin" "$systemctl_bin" "$host_bin" "$health_repo"

# Every other Health check passes, so any change in the result is board sync's.
: >"$health_home/.config/tmux/tmux.conf"
for stub in zsh tmux; do
  printf '#!/bin/sh\nexit 0\n' >"$health_home/.nix-profile/bin/$stub"
done
printf '#!/bin/sh\nexit 0\n' >"$health_home/.local/bin/nix-config-setup"
printf '#!/bin/sh\nexit 0\n' >"$mockbin/nix"
command cat >"$systemctl_bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_SYSTEMCTL_LOG"
cat "$MOCK_SYSTEMCTL_OUTPUT"
exit "${MOCK_SYSTEMCTL_STATUS:-0}"
STUB
chmod +x "$health_home/.nix-profile/bin/zsh" "$health_home/.nix-profile/bin/tmux" \
  "$health_home/.local/bin/nix-config-setup" "$mockbin/nix" "$systemctl_bin/systemctl"

# The host's tools without systemctl, earliest PATH entry first as a shell would.
IFS=: read -ra path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
  for tool in "$dir"/*; do
    name=${tool##*/}
    [ "$name" != systemctl ] && [ -f "$tool" ] && [ -x "$tool" ] && [ ! -e "$host_bin/$name" ] || continue
    ln -s "$tool" "$host_bin/$name"
  done
done
[ ! -e "$host_bin/systemctl" ] || fail 'the real systemctl is still reachable'

# Prints the property lines systemd 245 prints for gh-board-sync.service. The
# order is systemd's own, not the order the properties were asked for.
unit_state() {
  local load=$1 active=$2 result=$3 exited=$4 changed=$5
  printf '%s\n' "Result=$result" "ExecMainExitTimestamp=$exited" "LoadState=$load" \
    "ActiveState=$active" "StateChangeTimestamp=$changed"
}

# Runs Health with the given jobs file ("missing" for none) and systemctl reply.
run_health() {
  local jobs=$1 target=$2 path=$mockbin:$systemctl_bin:$host_bin
  [ "${MOCK_NO_SYSTEMCTL:-}" != 1 ] || path=$mockbin:$host_bin
  rm -f "$jobs_file"
  if [ "$jobs" != missing ]; then
    mkdir -p "${jobs_file%/*}"
    printf '%s' "$jobs" >"$jobs_file"
  fi
  : >"$systemctl_log"
  env -u XDG_STATE_HOME HOME="$health_home" USER=health-user PATH="$path" \
    MOCK_SYSTEMCTL_LOG="$systemctl_log" \
    MOCK_SYSTEMCTL_OUTPUT="$work/systemctl-output" \
    MOCK_SYSTEMCTL_STATUS="${MOCK_SYSTEMCTL_STATUS:-0}" \
    NIX_CONFIG_TEST_NO_TTY=1 \
    bash -c '
      set -euo pipefail
      . "$1/scripts/lib/core.sh"
      . "$1/scripts/lib/nix.sh"
      . "$1/scripts/lib/actions.sh"
      resolve_identity
      health "$2" "$3"
    ' _ "$repo_root" "$health_repo" "$target" </dev/null 2>&1
}

expect_passing_health() {
  [ "$status" = 0 ] || fail "$1 changed Health's result: $output"
}

failed_at='Thu 2026-10-22 09:00:04 KST'
finished_at='Thu 2026-10-22 10:00:03 KST'

# --- job not enabled ----------------------------------------------------------

unit_state loaded failed exit-code "$failed_at" "$failed_at" >"$work/systemctl-output"
for jobs in missing ''; do
  status=0
  output=$(run_health "$jobs" x86_64-linux) || status=$?
  expect_passing_health 'a machine without the job'
  ! grep -Fiq 'board sync' <<<"$output" || fail "Health mentioned board sync without the job (jobs file: ${jobs:-empty})"
  [ ! -s "$systemctl_log" ] || fail 'Health asked systemd about a job that is not enabled'
done

# macOS cannot enable jobs, so Health never asks there, whatever the file says.
status=0
output=$(run_health board-sync aarch64-darwin) || status=$?
! grep -Fiq 'board sync' <<<"$output" || fail 'Health reported board sync on macOS'
[ ! -s "$systemctl_log" ] || fail 'Health asked for systemd on macOS'

# --- job enabled, last run succeeded ------------------------------------------

unit_state loaded inactive success "$finished_at" "$finished_at" >"$work/systemctl-output"
status=0
output=$(run_health board-sync x86_64-linux) || status=$?
expect_passing_health 'a successful run'
grep -Fq "OK: board sync (last run finished $finished_at)" <<<"$output" \
  || fail "a successful run was not reported as OK: $output"
! grep -Fq 'BOARD WARN' <<<"$output" || fail 'a successful run also warned'
grep -Fq -- '--user show gh-board-sync.service' "$systemctl_log" \
  || fail 'Health did not ask the user manager about gh-board-sync.service'

# --- job enabled, last run failed ---------------------------------------------

# A failed oneshot keeps the exit time of the failing run and enters the failed
# state as that run ends.
unit_state loaded failed exit-code "$failed_at" "$failed_at" >"$work/systemctl-output"
status=0
output=$(run_health board-sync x86_64-linux) || status=$?
expect_passing_health 'a failed run'
grep -Fq "BOARD WARN: board sync failed at $failed_at (exit-code); see journalctl --user -u gh-board-sync" <<<"$output" \
  || fail "a failed run was not reported with its time and the journal: $output"
! grep -Fq 'OK: board sync' <<<"$output" || fail 'a failed run was reported as OK'

# A run refused by the start limit never executes, so its exit time is an older
# run's; the failure time is when the unit entered the failed state.
unit_state loaded failed start-limit-hit "$failed_at" "$finished_at" >"$work/systemctl-output"
status=0
output=$(run_health board-sync x86_64-linux) || status=$?
expect_passing_health 'a run refused by the start limit'
grep -Fq "BOARD WARN: board sync failed at $finished_at (start-limit-hit)" <<<"$output" \
  || fail "a refused run did not report when it failed: $output"

# --- job enabled, no run yet --------------------------------------------------

unit_state loaded inactive success '' '' >"$work/systemctl-output"
status=0
output=$(run_health board-sync x86_64-linux) || status=$?
expect_passing_health 'a job that has not run'
grep -Fq 'BOARD WARN: board sync has not run yet' <<<"$output" \
  || fail "a job that has not run did not warn: $output"
! grep -Fq 'OK: board sync' <<<"$output" || fail 'a job that has not run was reported as OK'

# Each start clears the previous exit time, so a run in progress is not a
# run that never happened, and not yet a success either.
unit_state loaded activating success '' "$finished_at" >"$work/systemctl-output"
output=$(run_health board-sync x86_64-linux)
grep -Fq 'BOARD WARN: board sync is running now' <<<"$output" || fail "a running sync was not reported: $output"
! grep -Fq 'OK: board sync' <<<"$output" || fail 'a running sync was reported as OK'

# --- systemd cannot tell ------------------------------------------------------

# Enabled in the file but not applied yet: the unit does not exist.
unit_state not-found inactive success '' '' >"$work/systemctl-output"
status=0
output=$(run_health board-sync x86_64-linux) || status=$?
expect_passing_health 'a missing unit'
grep -Fq 'BOARD WARN: board sync is enabled, but gh-board-sync.service is not-found; choose Apply' <<<"$output" \
  || fail "a missing unit was not reported: $output"

# No user manager, as in a bare SSH session or a container.
printf '%s\n' 'Failed to connect to bus: No medium found' >"$work/systemctl-output"
status=0
output=$(MOCK_SYSTEMCTL_STATUS=1 run_health board-sync x86_64-linux) || status=$?
expect_passing_health 'an unreachable user manager'
grep -Fq 'BOARD WARN: board sync is enabled, but the systemd user manager did not answer: Failed to connect to bus: No medium found' <<<"$output" \
  || fail "an unreachable user manager was not reported: $output"

status=0
output=$(MOCK_NO_SYSTEMCTL=1 run_health board-sync x86_64-linux) || status=$?
expect_passing_health 'a host without systemctl'
grep -Fq 'BOARD WARN: board sync is enabled, but systemctl is unavailable' <<<"$output" \
  || fail "a host without systemctl was not reported: $output"

# An unknown job is the output check's CORE FAIL; board sync adds nothing to it.
unit_state loaded inactive success "$finished_at" "$finished_at" >"$work/systemctl-output"
status=0
output=$(run_health "$(printf '%s\n' board-sync weekly-backup)" x86_64-linux) || status=$?
[ "$status" != 0 ] || fail 'an unknown job did not fail Health'
grep -Fq 'CORE FAIL: platform output is unavailable' <<<"$output" || fail "an unknown job was not a CORE FAIL: $output"
! grep -Fiq 'board sync' <<<"$output" || fail "an unknown job also reported board sync: $output"

printf '%s\n' 'board sync health test: PASSED (not enabled, succeeded, failed, not run yet, running, unit missing, no user manager, no systemctl)'
