#!/usr/bin/env bash
# Focused safety checks for the bro menu without a real Nix activation or network.
#
# bro is menu-only, so every case drives the real menu through a pseudo-terminal.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bro="$repo_root/scripts/bro"
pty_run="$repo_root/tests/lib/pty-run"
# bro records the checkout by its physical path, and on macOS mktemp's /var is
# a symlink to /private/var, so resolve it for the paths asserted below.
work=$(CDPATH='' cd -- "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT
checkout="$work/checkout"
mockbin="$work/bin"
log="$work/log"
mkdir -p "$checkout/scripts" "$mockbin"
: >"$log"
ln -s /bin/bash "$mockbin/bash"
git init -q "$checkout"
git -C "$checkout" remote add origin https://github.com/hattajr/nix-config.git
printf '{}\n' >"$checkout/flake.nix"

real_git=$(command -v git)
command cat >"$mockbin/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\\n' "\$*" >>"$log"
if [ "\${MOCK_GIT_MODE:-}" = sync ]; then
  case "\${3:-}" in
    status|fetch|push) exit 0 ;;
    rev-parse) printf '%s\\n' origin/main; exit 0 ;;
    rev-list)
      case "\${5:-}" in *..HEAD) printf '%s\\n' "\${MOCK_GIT_AHEAD:-1}" ;; *) printf '%s\\n' 0 ;; esac
      exit 0
      ;;
  esac
fi
exec "$real_git" "\$@"
EOF
command cat >"$mockbin/nix" <<'EOF'
#!/usr/bin/env bash
printf 'nix %s\n' "$*" >>"$MOCK_LOG"
if [ -n "${MOCK_NIX_DNS_FAILURES:-}" ]; then
  attempt=0
  [ ! -r "$MOCK_NIX_RETRY_STATE" ] || attempt=$(cat "$MOCK_NIX_RETRY_STATE")
  if [ "$attempt" -lt "$MOCK_NIX_DNS_FAILURES" ]; then
    printf '%s\n' "$((attempt + 1))" >"$MOCK_NIX_RETRY_STATE"
    printf '%s\n' "warning: unable to download input: Could not resolve host: github.com" >&2
    exit 1
  fi
fi
[ "${1:-}" != --impure ] || shift
case "$1" in
  flake|eval) exit 0 ;;
  build) mkdir -p "$MOCK_ACTIVATION"; cat >"$MOCK_ACTIVATION/activate" <<'ACTIVATE'
#!/bin/sh
printf 'activation\n' >>"$MOCK_LOG"
ACTIVATE
    chmod +x "$MOCK_ACTIVATION/activate"; printf '%s\n' "$MOCK_ACTIVATION" ;;
  *) exit 1 ;;
esac
EOF
command cat >"$mockbin/sleep" <<'EOF'
#!/bin/sh
printf 'sleep %s\n' "$*" >>"$MOCK_LOG"
EOF
# Platform-specific paths are asserted on every host, so the kernel name and
# architecture can be overridden together; macOS is only supported on arm64, so
# faking Darwin alone on an x86_64 host is an unsupported platform.
real_uname=$(command -v uname)
command cat >"$mockbin/uname" <<EOF
#!/bin/sh
if [ "\$*" = -s ] && [ -n "\${MOCK_UNAME_S:-}" ]; then
  printf '%s\\n' "\$MOCK_UNAME_S"
  exit 0
fi
if [ "\$*" = -m ] && [ -n "\${MOCK_UNAME_M:-}" ]; then
  printf '%s\\n' "\$MOCK_UNAME_M"
  exit 0
fi
exec "$real_uname" "\$@"
EOF
chmod +x "$mockbin/git" "$mockbin/nix" "$mockbin/sleep" "$mockbin/uname"
export MOCK_LOG="$log" MOCK_ACTIVATION="$work/activation"

# The checkout is recorded state; there is no variable to point bro elsewhere.
record_checkout() {
  local target_home=$1
  mkdir -p "$target_home/.local/state/bro"
  printf '%s\n' "$checkout" >"$target_home/.local/state/bro/checkout"
}

apply_home="$work/apply-home"
mkdir -p "$apply_home/.nix-profile/bin" "$apply_home/.config/tmux"
record_checkout "$apply_home"
printf '%s\n' '# test configuration' >"$apply_home/.config/tmux/tmux.conf"
command cat >"$apply_home/.nix-profile/bin/tmux" <<'EOF'
#!/bin/sh
printf 'tmux %s\n' "$*" >>"$MOCK_LOG"
EOF
chmod +x "$apply_home/.nix-profile/bin/tmux"

# An inherited XDG_STATE_HOME would point bro at the developer's real state.
# Trailing end-of-file marks end every prompt, nested ones included, still
# waiting after the last answer, so a misnumbered answer fails an assertion
# instead of hanging the suite.
run_menu() {
  local target_home=$1 answers=$2 && shift 2
  printf '%b\004\004\004' "$answers" | "$pty_run" env -u XDG_STATE_HOME \
    HOME="$target_home" USER=apply-user PATH="$mockbin:$PATH" "$@" "$bro"
}

# Jobs appears only on Linux, just before Quit, so Quit moves with the host.
case "$(uname -s)" in
  Linux) quit=8 ;;
  *) quit=7 ;;
esac

# --- the menu is the only interface ----------------------------------------

status=0
output=$(run_menu "$apply_home" '' env NIX_CONFIG_TEST_NO_TTY=1 2>&1) || status=$?
[ "$status" -ne 0 ] || { echo 'bro test: headless bro did not fail closed' >&2; exit 1; }

status=0
output=$(printf '' | "$pty_run" env HOME="$apply_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" apply 2>&1) || status=$?
[ "$status" = 2 ] || { echo 'bro test: a typed verb was not rejected' >&2; exit 1; }
grep -Fq 'takes no arguments' <<<"$output" || { echo 'bro test: rejection did not explain the menu' >&2; exit 1; }

# Quit leaves immediately. Resolving the recorded checkout verifies the Git
# origin first, so that call is expected; nothing else may run.
: >"$log"
run_menu "$apply_home" "${quit}\n" >/dev/null
! grep -q '^nix ' "$log" || { echo 'bro test: quitting the menu invoked Nix' >&2; exit 1; }
! grep -q '^activation$' "$log" || { echo 'bro test: quitting the menu activated' >&2; exit 1; }
grep -Fq 'remote get-url origin' "$log" || {
  echo 'bro test: the menu did not verify the recorded checkout origin' >&2; exit 1; }

# --- Apply ------------------------------------------------------------------

: >"$log"
output=$(run_menu "$apply_home" "1\n${quit}\n")
grep -q '^activation$' "$log" || { echo 'bro test: Apply did not activate' >&2; exit 1; }
grep -Fq 'nix build --impure --no-link' "$log" || {
  echo 'bro test: Apply did not build with the active user identity' >&2; exit 1; }
grep -Fq "path = \"$checkout\"" "$log" || {
  echo 'bro test: Apply did not snapshot the active checkout' >&2; exit 1; }
grep -Fq 'filter = path: type: builtins.baseNameOf path != ".git"' "$log" || {
  echo 'bro test: Apply allowed Nix to traverse mutable Git object storage' >&2; exit 1; }
grep -Fq 'builtins.unsafeDiscardStringContext "path:${source}"' "$log" || {
  echo 'bro test: Apply did not load the filtered working-tree snapshot' >&2; exit 1; }
grep -Fq 'username = "apply-user"' "$log" || {
  echo 'bro test: Apply did not pass the active identity explicitly' >&2; exit 1; }
grep -Eq '^tmux source-file .*/\.config/tmux/tmux\.conf$' "$log" || {
  echo 'bro test: Apply did not reload an active managed tmux server' >&2; exit 1; }
grep -Fq 'reloaded active tmux configuration' <<<"$output" || {
  echo 'bro test: Apply did not report the tmux reload' >&2; exit 1; }

# A single build replaces the former metadata and drvPath pre-flight.
[ "$(grep -c '^nix ' "$log")" -eq 1 ] || {
  echo 'bro test: Apply made more than one Nix call' >&2; exit 1; }

# --- transient DNS handling -------------------------------------------------

: >"$log"
retry_state="$work/retry-state"
output=$(run_menu "$apply_home" "1\n${quit}\n" env MOCK_NIX_DNS_FAILURES=2 MOCK_NIX_RETRY_STATE="$retry_state" 2>&1)
[ "$(grep -c '^nix build ' "$log")" -eq 3 ] || {
  echo 'bro test: Apply did not retry transient DNS failures' >&2; exit 1; }
if ! grep -Fxq 'sleep 1' "$log" || ! grep -Fxq 'sleep 2' "$log"; then
  echo 'bro test: DNS retries did not use exponential backoff' >&2
  exit 1
fi
grep -Fq 'retrying in 1s (attempt 2/5)' <<<"$output" || {
  echo 'bro test: Apply did not report DNS retry progress' >&2; exit 1; }

: >"$log"
rm -f "$retry_state"
output=$(run_menu "$apply_home" "1\n${quit}\n" env MOCK_NIX_DNS_FAILURES=9 MOCK_NIX_RETRY_STATE="$retry_state" 2>&1)
[ "$(grep -c '^nix build ' "$log")" -eq 5 ] || {
  echo 'bro test: Apply did not stop after five DNS attempts' >&2; exit 1; }
[ "$(grep -c '^sleep ' "$log")" -eq 4 ] || {
  echo 'bro test: Apply slept after the final DNS attempt' >&2; exit 1; }
# A failed step returns to the menu rather than ending the session.
grep -Fq 'returning to the menu' <<<"$output" || {
  echo 'bro test: an exhausted retry ended the session' >&2; exit 1; }

# --- Sync -------------------------------------------------------------------

# A dirty working tree is refused before any network operation, and the refusal
# names the offending files so it is a next step rather than a dead end.
: >"$log"
printf dirty >"$checkout/dirty"
output=$(run_menu "$apply_home" "2\n${quit}\n" 2>&1)
! grep -Eq '^git .* fetch' "$log" || { echo 'bro test: dirty sync fetched' >&2; exit 1; }
grep -Fq 'Sync needs a clean checkout' <<<"$output" || {
  echo 'bro test: dirty sync was not explained' >&2; exit 1; }
grep -Fq 'dirty' <<<"$output" || {
  echo 'bro test: dirty sync did not name the uncommitted file' >&2; exit 1; }
grep -Fq 'choose Sync again' <<<"$output" || {
  echo 'bro test: dirty sync did not say what to do next' >&2; exit 1; }
rm "$checkout/dirty"

# Local commits are published only after an explicit yes.
: >"$log"
run_menu "$apply_home" "2\nn\n${quit}\n" env MOCK_GIT_MODE=sync >/dev/null
! grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: declining the prompt still pushed' >&2; exit 1; }
: >"$log"
run_menu "$apply_home" "2\ny\n${quit}\n" env MOCK_GIT_MODE=sync >/dev/null
grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: accepting the prompt did not push' >&2; exit 1; }

# A bare Return is the likeliest accidental answer, so it must not publish.
: >"$log"
run_menu "$apply_home" "2\n\n${quit}\n" env MOCK_GIT_MODE=sync >/dev/null
! grep -Eq '^git .* push($| )' "$log" || {
  echo 'bro test: an empty answer at the push prompt published commits' >&2; exit 1; }

# With nothing ahead of upstream there is no push prompt at all.
: >"$log"
run_menu "$apply_home" "2\n${quit}\n" env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 >/dev/null
! grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: sync pushed with nothing ahead' >&2; exit 1; }

# --- Accounts ---------------------------------------------------------------

auth_home="$work/auth-home"
mkdir -p "$auth_home/.local/bin"
record_checkout "$auth_home"
command cat >"$auth_home/.local/bin/nix-config-setup" <<'EOF'
#!/bin/sh
printf 'setup %s\n' "$*" >>"$MOCK_LOG"
EOF
command cat >"$auth_home/.local/bin/proton-pass-session" <<'EOF'
#!/bin/sh
printf 'proton %s\n' "$*" >>"$MOCK_LOG"
EOF
chmod +x "$auth_home/.local/bin/nix-config-setup" "$auth_home/.local/bin/proton-pass-session"
: >"$log"
run_menu "$auth_home" '4\n8\n' env MOCK_UNAME_S=Linux >/dev/null
grep -Fq "proton $auth_home/.local/bin/nix-config-setup" "$log" || {
  echo 'bro test: Linux Accounts did not use the Proton Pass session' >&2; exit 1; }
: >"$log"
run_menu "$auth_home" '4\n7\n' env MOCK_UNAME_S=Darwin MOCK_UNAME_M=arm64 >/dev/null
grep -q '^setup ' "$log" && ! grep -q '^proton ' "$log" || {
  echo 'bro test: macOS Accounts did not run setup directly' >&2; exit 1; }
rm "$auth_home/.local/bin/proton-pass-session"
: >"$log"
run_menu "$auth_home" "4\n${quit}\n" >/dev/null
grep -q '^setup ' "$log" || { echo 'bro test: Accounts fallback did not run setup' >&2; exit 1; }

# --- Update: Pi extensions --------------------------------------------------

# Extensions are Pi's own npm packages, so choosing them must reach Pi and must
# not touch the pinned files or their review, apply, and commit flow.
extensions_home="$work/extensions-home"
mkdir -p "$extensions_home/.local/bin"
record_checkout "$extensions_home"
command cat >"$extensions_home/.local/bin/pi" <<'EOF'
#!/bin/sh
printf 'pi %s (skip=%s)\n' "$*" "${PI_SKIP_PROTON_PASS:-}" >>"$MOCK_LOG"
EOF
chmod +x "$extensions_home/.local/bin/pi"

: >"$log"
run_menu "$extensions_home" "3\n3\n${quit}\n" env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 >/dev/null
grep -Fq 'pi update --extensions (skip=1)' "$log" || {
  echo 'bro test: Update did not offer a working Pi extension update' >&2; exit 1; }
! grep -Eq '^git .* (add|commit)($| )' "$log" || {
  echo 'bro test: updating Pi extensions touched the pinned files' >&2; exit 1; }
! grep -Fq 'nix flake update' "$log" || {
  echo 'bro test: updating Pi extensions also moved the nixpkgs pin' >&2; exit 1; }

# Pi + ext moves the Pi pin first, then updates extensions against it, and
# leaves the nixpkgs pin alone.
command cat >"$checkout/scripts/update-pi" <<'EOF'
#!/bin/sh
printf 'update-pi %s\n' "$*" >>"$MOCK_LOG"
[ -z "${MOCK_UPDATE_PI_FAIL:-}" ] || exit 1
EOF
chmod +x "$checkout/scripts/update-pi"
: >"$log"
run_menu "$extensions_home" "3\n4\n${quit}\n" env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 >/dev/null
grep -Fq "update-pi $checkout" "$log" || {
  echo 'bro test: Pi + ext did not update the Pi pin' >&2; exit 1; }
grep -Fq 'pi update --extensions (skip=1)' "$log" || {
  echo 'bro test: Pi + ext did not update Pi extensions' >&2; exit 1; }
[ "$(grep -n '^update-pi ' "$log" | cut -d: -f1)" -lt "$(grep -n '^pi update ' "$log" | cut -d: -f1)" ] || {
  echo 'bro test: Pi + ext updated extensions before the Pi pin' >&2; exit 1; }
! grep -Fq 'nix flake update' "$log" || {
  echo 'bro test: Pi + ext also moved the nixpkgs pin' >&2; exit 1; }

# Playwright moves only the playwright-cli pin: no Pi, extension, or nixpkgs work.
command cat >"$checkout/scripts/update-playwright-cli" <<'EOF'
#!/bin/sh
printf 'update-playwright-cli %s\n' "$*" >>"$MOCK_LOG"
EOF
chmod +x "$checkout/scripts/update-playwright-cli"
: >"$log"
run_menu "$extensions_home" "3\n5\n${quit}\n" env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 >/dev/null
grep -Fq "update-playwright-cli $checkout" "$log" || {
  echo 'bro test: Playwright did not update the playwright-cli pin' >&2; exit 1; }
! grep -Eq '^(update-pi|pi update) ' "$log" || {
  echo 'bro test: Playwright also updated Pi' >&2; exit 1; }
! grep -Fq 'nix flake update' "$log" || {
  echo 'bro test: Playwright also moved the nixpkgs pin' >&2; exit 1; }

# A failed pin update is reported as a failure, never as already current, and
# stops before extensions update against a Pi that did not move.
: >"$log"
output=$(run_menu "$extensions_home" "3\n4\n${quit}\n" env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 MOCK_UPDATE_PI_FAIL=1 2>&1)
grep -Fq 'Pi pin update failed' <<<"$output" || {
  echo 'bro test: a failed Pi pin update was not reported' >&2; exit 1; }
! grep -Fq 'already current' <<<"$output" || {
  echo 'bro test: a failed Pi pin update was reported as already current' >&2; exit 1; }
! grep -q '^pi update ' "$log" || {
  echo 'bro test: extensions updated after the Pi pin update failed' >&2; exit 1; }

# Without Pi installed the step explains itself rather than failing silently.
rm "$extensions_home/.local/bin/pi"
: >"$log"
output=$(run_menu "$extensions_home" "3\n3\n${quit}\n" env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 2>&1)
grep -Fq 'Pi is not installed for this account yet' <<<"$output" || {
  echo 'bro test: a missing Pi did not explain the extension update failure' >&2; exit 1; }

# --- Jobs -------------------------------------------------------------------

# Every Jobs case fakes Linux so it runs the same on a macOS host; Jobs is then
# item 7 and Quit item 8.
jobs_home="$work/jobs-home"
mkdir -p "$jobs_home"
record_checkout "$jobs_home"
jobs_file="$jobs_home/.local/state/bro/background-jobs"
linux=(env MOCK_UNAME_S=Linux MOCK_UNAME_M=x86_64)
host=$(uname -n)

output=$(run_menu "$jobs_home" '8\n' "${linux[@]}")
grep -Eq '7\) Jobs +choose background jobs for this machine' <<<"$output" || {
  echo 'bro test: the Linux menu did not offer Jobs' >&2; exit 1; }
output=$(run_menu "$jobs_home" '7\n' env MOCK_UNAME_S=Darwin MOCK_UNAME_M=arm64)
! grep -Fq 'Jobs' <<<"$output" || { echo 'bro test: the macOS menu offered Jobs' >&2; exit 1; }
grep -Eq '7\) Quit' <<<"$output" || { echo 'bro test: Quit moved on macOS' >&2; exit 1; }

# With no state file this machine has no jobs, and neither Apply nor Sync
# creates one or asks Home Manager for the timer.
: >"$log"
run_menu "$jobs_home" '1\n8\n' "${linux[@]}" >/dev/null
grep -Fq 'jobs = [ ]; })' "$log" || {
  echo 'bro test: Apply without a jobs file did not pass an empty job list' >&2; exit 1; }
: >"$log"
run_menu "$jobs_home" '2\n8\n' "${linux[@]}" MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 >/dev/null
grep -Fq 'jobs = [ ]; })' "$log" || {
  echo 'bro test: Sync without a jobs file did not pass an empty job list' >&2; exit 1; }
! grep -Fq 'board-sync' "$log" || { echo 'bro test: Apply or Sync enabled Board sync unasked' >&2; exit 1; }
[ ! -e "$jobs_file" ] || { echo 'bro test: Apply or Sync wrote the jobs file' >&2; exit 1; }

# Enabling: toggle Board sync, then Done saves the file and applies it.
: >"$log"
output=$(run_menu "$jobs_home" '7\n1\n2\n8\n' "${linux[@]}")
grep -Fq "Background jobs on $host" <<<"$output" || {
  echo 'bro test: Jobs did not name this machine' >&2; exit 1; }
grep -Eq '1\) \[ \] Board sync +hourly: add your open GitHub issues to your boards' <<<"$output" || {
  echo 'bro test: Jobs did not list Board sync as off' >&2; exit 1; }
grep -Eq '1\) \[x\] Board sync +hourly' <<<"$output" || {
  echo 'bro test: toggling Board sync did not mark it on' >&2; exit 1; }
grep -Eq '2\) Done +apply and return' <<<"$output" || {
  echo 'bro test: Jobs did not offer Done' >&2; exit 1; }
[ "$(cat "$jobs_file")" = board-sync ] || { echo 'bro test: Done did not save Board sync' >&2; exit 1; }
grep -Fq 'jobs = [ "board-sync" ]; })' "$log" && grep -q '^activation$' "$log" || {
  echo 'bro test: Done did not apply with Board sync enabled' >&2; exit 1; }

# The saved file is what later activations read back.
: >"$log"
run_menu "$jobs_home" '1\n8\n' "${linux[@]}" >/dev/null
grep -Fq 'jobs = [ "board-sync" ]; })' "$log" || {
  echo 'bro test: Apply did not read the saved jobs back' >&2; exit 1; }

# Disabling: toggle it off, Done saves an empty list and applies without it.
: >"$log"
run_menu "$jobs_home" '7\n1\n2\n8\n' "${linux[@]}" >/dev/null
[ -e "$jobs_file" ] && [ ! -s "$jobs_file" ] || {
  echo 'bro test: disabling Board sync did not save an empty job list' >&2; exit 1; }
grep -Fq 'jobs = [ ]; })' "$log" && grep -q '^activation$' "$log" || {
  echo 'bro test: disabling Board sync did not apply without it' >&2; exit 1; }

# Toggling twice is no change, but Done still saves and applies.
: >"$log"
run_menu "$jobs_home" '7\n1\n1\n2\n8\n' "${linux[@]}" >/dev/null
[ ! -s "$jobs_file" ] && grep -q '^activation$' "$log" || {
  echo 'bro test: toggling twice then Done did not leave Board sync off and apply' >&2; exit 1; }

# An unknown name is refused with the file and the name, never skipped: no
# build runs and the Jobs prompt leaves the file as it was.
printf '%s\n' board-sync weekly-backup >"$jobs_file"
: >"$log"
output=$(run_menu "$jobs_home" '1\n7\n8\n' "${linux[@]}" 2>&1)
[ "$(grep -c "unknown background job \"weekly-backup\" in $jobs_file" <<<"$output")" -eq 2 ] || {
  echo 'bro test: an unknown job was not rejected clearly by both Apply and Jobs' >&2; exit 1; }
! grep -Eq '^nix |^activation$' "$log" || {
  echo 'bro test: an unknown job still reached Nix' >&2; exit 1; }
[ "$(cat "$jobs_file")" = "$(printf '%s\n' board-sync weekly-backup)" ] || {
  echo 'bro test: rejecting an unknown job rewrote the file' >&2; exit 1; }

echo 'bro test: PASSED (menu-only entry, apply identity, DNS retry, sync push boundary, accounts wrapper, Pi extensions, Pi + ext, Playwright, Jobs)'
