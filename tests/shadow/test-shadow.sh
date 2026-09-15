#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fake_home=$workdir/home
profile=$workdir/store-profile
store=$workdir/nix/store/aaaa-home-manager-files/.local/bin
mkdir -p "$fake_home/.local/bin" "$fake_home/bin" "$profile/bin" "$store"

# The profile offers four binaries; the fixtures below shadow three of them.
for name in uv claude pi gh; do
  printf '#!/bin/sh\n' >"$profile/bin/$name"
  chmod +x "$profile/bin/$name"
done

printf '#!/bin/sh\n' >"$fake_home/.local/bin/uv"          # stale, unmanaged
chmod +x "$fake_home/.local/bin/uv"
printf '#!/bin/sh\n' >"$fake_home/.local/bin/claude"      # deliberate, allowed
chmod +x "$fake_home/.local/bin/claude"
printf '#!/bin/sh\n' >"$store/pi"                         # managed wrapper
chmod +x "$store/pi"
ln -s "$store/pi" "$fake_home/.local/bin/pi"

run_shadow() {
  env HOME="$fake_home" \
    XDG_STATE_HOME="$fake_home/.local/state" \
    NIX_CONFIG_PROFILE_DIR="$profile" \
    NIX_CONFIG_SHADOW_DIRS="$fake_home/bin:$fake_home/.local/bin" \
    NIX_CONFIG_SHADOW_ALLOW='claude' \
    NIX_STORE_DIR="$workdir/nix/store" \
    "$repo_root/bin/shadow-scan" "$@"
}

# An unmanaged binary outranking the profile is reported and fails --check.
status=0
output=$(run_shadow --check 2>&1) || status=$?
[ "$status" = 1 ] || { printf '%s\n' 'shadow test: --check did not fail on a finding' >&2; exit 1; }
grep -Fq 'uv' <<<"$output" || { printf '%s\n' 'shadow test: stale uv was not reported' >&2; exit 1; }

# A store symlink is Home Manager's own wrapper, not a stale install.
! grep -Eq '^\s+pi\s' <<<"$output" || { printf '%s\n' 'shadow test: managed wrapper was reported' >&2; exit 1; }

# An allowlisted self-updating tool is acknowledged but left alone.
! grep -Eq '^\s+claude\s' <<<"$output" || { printf '%s\n' 'shadow test: allowlisted claude was reported as a finding' >&2; exit 1; }
grep -Fq 'Deliberate, left alone: claude' <<<"$output" || { printf '%s\n' 'shadow test: allowlisted claude was not acknowledged' >&2; exit 1; }

# Activation mode warns on stderr and never fails the switch.
status=0
output=$(run_shadow --warn 2>&1) || status=$?
[ "$status" = 0 ] || { printf '%s\n' 'shadow test: --warn failed activation' >&2; exit 1; }
grep -Fq 'warning: 1 unmanaged binary is shadowing' <<<"$output" || {
  printf '%s\n' 'shadow test: --warn did not describe the finding' >&2
  exit 1
}

# Quarantine moves the file out of PATH and preserves it for recovery.
run_shadow --all >/dev/null
[ ! -e "$fake_home/.local/bin/uv" ] || { printf '%s\n' 'shadow test: stale uv survived quarantine' >&2; exit 1; }
recovered=$(find "$fake_home/.local/state/home-manager/shadowed" -name uv -type f | head -n1)
[ -n "$recovered" ] || { printf '%s\n' 'shadow test: quarantined uv is unrecoverable' >&2; exit 1; }
[ -e "$fake_home/.local/bin/pi" ] || { printf '%s\n' 'shadow test: managed wrapper was quarantined' >&2; exit 1; }
[ -e "$fake_home/.local/bin/claude" ] || { printf '%s\n' 'shadow test: allowlisted binary was quarantined' >&2; exit 1; }

# A clean account reports success and exits zero.
status=0
run_shadow --check >/dev/null 2>&1 || status=$?
[ "$status" = 0 ] || { printf '%s\n' 'shadow test: clean account did not exit zero' >&2; exit 1; }

printf '%s\n' 'shadow test: PASSED (detection, managed and allowlisted exemptions, warn mode, quarantine)'

# --- health integration -----------------------------------------------------
# bootstrap and the menu both call health(). A shadowed binary must warn without
# prompting and without changing what health returns, or a first install on a
# machine that already has a hand-installed tool would fail.

health_home=$workdir/health-home
health_repo=$workdir/health-repo
mockbin=$workdir/mockbin
mkdir -p "$health_home/.nix-profile/bin" "$health_home/.local/bin" \
  "$health_home/.local/share/nix-config" "$health_home/.config/tmux" "$mockbin" "$health_repo"

: >"$health_home/.config/tmux/tmux.conf"
for stub in zsh tmux; do
  printf '#!/bin/sh\nexit 0\n' >"$health_home/.nix-profile/bin/$stub"
  chmod +x "$health_home/.nix-profile/bin/$stub"
done
printf '#!/bin/sh\nexit 0\n' >"$health_home/.local/bin/nix-config-setup"
chmod +x "$health_home/.local/bin/nix-config-setup"

# Exit status stands in for "findings exist", matching shadow-scan --check.
command cat >"$health_home/.local/share/nix-config/shadow-scan" <<'STUB'
#!/bin/sh
printf 'stub scanned\n' >>"$SHADOW_STUB_LOG"
exit "${SHADOW_STUB_STATUS:-0}"
STUB
chmod +x "$health_home/.local/share/nix-config/shadow-scan"

printf '#!/bin/sh\nexit 0\n' >"$mockbin/nix"
chmod +x "$mockbin/nix"
git init -q "$health_repo"
git -C "$health_repo" remote add origin https://github.com/hattajr/nix-config.git

run_health() {
  env HOME="$health_home" \
    USER=health-user \
    PATH="$mockbin:$PATH" \
    SHADOW_STUB_LOG="$workdir/stub.log" \
    SHADOW_STUB_STATUS="$1" \
    NIX_CONFIG_TEST_NO_TTY=1 \
    bash -c '
      set -euo pipefail
      . "$1/scripts/lib/core.sh"
      . "$1/scripts/lib/nix.sh"
      . "$1/scripts/lib/actions.sh"
      resolve_identity
      health "$2" x86_64-linux
    ' _ "$repo_root" "$health_repo"
}

# A clean account passes and says so.
: >"$workdir/stub.log"
status=0
output=$(run_health 0 </dev/null 2>&1) || status=$?
[ "$status" = 0 ] || { printf '%s\n' 'health test: clean account did not pass' >&2; exit 1; }
grep -Fq 'OK: no unmanaged binaries shadow the Nix profile' <<<"$output" || {
  printf '%s\n' 'health test: clean shadow check was not reported' >&2
  exit 1
}
grep -Fq 'stub scanned' "$workdir/stub.log" || {
  printf '%s\n' 'health test: the shadow checker was never invoked' >&2
  exit 1
}

# A finding warns but must not fail health.
status=0
output=$(run_health 1 </dev/null 2>&1) || status=$?
[ "$status" = 0 ] || { printf '%s\n' 'health test: a shadowed binary failed health' >&2; exit 1; }
grep -Fq 'PATH WARN: unmanaged binaries shadow the Nix profile' <<<"$output" || {
  printf '%s\n' 'health test: the finding was not reported' >&2
  exit 1
}
! grep -Fq 'Review the shadowed binaries' <<<"$output" || {
  printf '%s\n' 'health test: health prompted without a terminal' >&2
  exit 1
}

printf '%s\n' 'health test: PASSED (checker invoked, finding warns, no headless prompt, status preserved)'
