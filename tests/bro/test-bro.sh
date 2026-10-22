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
# The log box ticks with fractional sleeps, which really sleep; only the whole
# seconds of the DNS backoff are recorded and skipped.
real_sleep=$(command -v sleep)
command cat >"$mockbin/sleep" <<EOF
#!/bin/sh
case "\$1" in *.*) exec "$real_sleep" "\$@" ;; esac
printf 'sleep %s\\n' "\$*" >>"\$MOCK_LOG"
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
# instead of hanging the suite. These answers are typed at the plain prompts,
# so the switch keeps them plain on a host that has gum installed.
run_menu() {
  local target_home=$1 answers=$2 && shift 2
  printf '%b\004\004\004' "$answers" | "$pty_run" env -u XDG_STATE_HOME \
    HOME="$target_home" USER=apply-user PATH="$mockbin:$PATH" NIX_CONFIG_TEST_PLAIN=1 "$@" "$bro"
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

# --- styled prompts -----------------------------------------------------------

# The mock gum records every call and replays the next scripted answer, one per
# line of MOCK_GUM_ANSWERS: esc and ctrl-c leave the prompt with gum's own exit
# status, enter takes the default (the first row, the pre-ticked rows, or the
# confirm default), yes and no answer a confirm, and "pick A|B" chooses the
# rows whose text starts with A and B. It answers like real gum: a row is split
# into shown text and answered value only when --label-delimiter names the
# separator, the answer goes to stdout, and --selected is split on commas that
# are not escaped as "\,". Running out of answers is an Esc, so a miscounted
# script ends the menu instead of hanging the suite.
gumbin="$work/gum-bin"
gum_log="$work/gum-log"
gum_state="$work/gum-state"
mkdir -p "$gumbin"
command cat >"$gumbin/gum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{ printf 'gum'; printf ' [%s]' "$@"; printf '\n'; } >>"$MOCK_GUM_LOG"
[ -t 0 ] && [ -t 2 ] || { printf 'gum was not given the terminal\n' >>"$MOCK_GUM_LOG"; exit 2; }
call=$(( $(cat "$MOCK_GUM_STATE" 2>/dev/null || printf 0) + 1 ))
printf '%s\n' "$call" >"$MOCK_GUM_STATE"
answer=$(sed -n "${call}p" <<<"$MOCK_GUM_ANSWERS")
command=$1 && shift
rows=() ticked=() default=true many=no delimiter=''

# Splits a flag value on commas the way gum's flag parser does: "\," is a
# literal comma, and any other backslash stays as it is.
add_ticked() {
  local value=$1 token='' char escaped=no i
  for ((i = 0; i < ${#value}; i++)); do
    char=${value:i:1}
    if [ "$escaped" = yes ]; then
      [ "$char" = , ] || token+='\'
      token+=$char
      escaped=no
    elif [ "$char" = '\' ] && [ "$i" -lt $((${#value} - 1)) ]; then
      escaped=yes
    elif [ "$char" = , ]; then
      ticked+=("$token")
      token=''
    else
      token+=$char
    fi
  done
  ticked+=("$token")
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; rows=("$@"); break ;;
    --selected=*) add_ticked "${1#--selected=}" ;;
    --default=*) default=${1#--default=} ;;
    --label-delimiter=*) delimiter=${1#--label-delimiter=} ;;
    --no-limit) many=yes ;;
  esac
  shift
done

shown() { if [ -n "$delimiter" ]; then printf '%s' "${1%"$delimiter"*}"; else printf '%s' "$1"; fi; }
value() { if [ -n "$delimiter" ]; then printf '%s\n' "${1##*"$delimiter"}"; else printf '%s\n' "$1"; fi; }

print_rows_starting() {
  local wanted row
  for wanted in "$@"; do
    for row in "${rows[@]}"; do
      case "$(shown "$row")" in "$wanted"*) value "$row" ;; esac
    done
  done
}

case "$command:${answer:-esc}" in
  *:ctrl-c) exit 130 ;;
  choose:esc) printf 'nothing selected\n' >&2; exit 1 ;;
  confirm:esc | confirm:no) exit 1 ;;
  confirm:yes) exit 0 ;;
  confirm:enter) [ "$default" = true ] ;;
  choose:enter)
    if [ "$many" = yes ]; then
      for row in "${rows[@]}"; do
        for wanted in "${ticked[@]+"${ticked[@]}"}"; do
          [ "$(shown "$row")" != "$wanted" ] || value "$row"
        done
      done
    else
      value "${rows[0]}"
    fi
    ;;
  'choose:pick') ;;
  choose:pick\ *) IFS='|' read -r -a picks <<<"${answer#pick }"; print_rows_starting "${picks[@]}" ;;
  *) printf 'mock gum: no answer "%s" for %s\n' "$answer" "$command" >&2; exit 3 ;;
esac
EOF
chmod +x "$gumbin/gum"

# Styled mode needs no test switch, a terminal, and gum on PATH. Esc after the
# scripted answers ends the menu, and plain-prompt end-of-file marks stop a
# wrong fallback to the numbered menu from hanging the suite.
run_styled() {
  local target_home=$1 answers=$2 && shift 2
  : >"$gum_log"
  rm -f "$gum_state"
  printf '\004\004\004' | "$pty_run" env -u XDG_STATE_HOME -u NIX_CONFIG_TEST_PLAIN \
    HOME="$target_home" USER=apply-user PATH="$gumbin:$mockbin:$PATH" \
    MOCK_GUM_LOG="$gum_log" MOCK_GUM_STATE="$gum_state" MOCK_GUM_ANSWERS="$answers" \
    "$@" "$bro"
}

gum_calls() {
  grep -c '^gum ' "$gum_log" || true
}

# The text gum showed for the first row starting with LABEL, without its colour
# codes or answer value.
gum_row() {
  grep -o "\[$1 [^]]*\]" "$gum_log" | head -n 1 \
    | sed -e $'s/\e\\[[0-9;]*m//g' -e 's/^\[//' -e $'s/\t[0-9]*]$//'
}

# Asserts a gum row fits 60 columns after MARKS columns of gum's own cursor and
# tick marks, and that its description is DESCRIPTION, either whole or cut to
# the full width with an ellipsis that marks the cut.
expect_gum_row() {
  local label=$1 marks=$2 description=$3 row shown measured
  row=$(gum_row "$label")
  shown=${row#"$label"}
  shown=${shown#"${shown%%[! ]*}"}
  # A one-byte stand-in for the ellipsis keeps the width count right in any locale.
  measured=${row/…/.}
  [ $((marks + ${#measured})) -le 60 ] || {
    echo "bro test: the styled $label row is wider than 60 columns: $row" >&2; exit 1; }
  case "$shown" in
    "$description") ;;
    *…)
      [ "${description#"${shown%…}"}" != "$description" ] || {
        echo "bro test: the styled $label row cut its description to something else: $row" >&2; exit 1; }
      # A cut description uses all the room there is.
      [ $((marks + ${#measured})) -eq 60 ] || {
        echo "bro test: the styled $label row was cut shorter than 60 columns: $row" >&2; exit 1; } ;;
    *) echo "bro test: the styled $label row cut its description without marking it: $row" >&2; exit 1 ;;
  esac
}

# The main menu goes through gum, keeps each description beside its label, and
# the chosen item runs; Esc then quits with success.
: >"$log"
status=0
output=$(run_styled "$apply_home" $'pick Apply\nesc' 2>&1) || status=$?
[ "$status" = 0 ] || { echo "bro test: Esc at the styled main menu exited $status" >&2; exit 1; }
grep -q '^activation$' "$log" || { echo 'bro test: Apply chosen through gum did not activate' >&2; exit 1; }
! grep -Fq 'not given the terminal' "$gum_log" || {
  echo 'bro test: gum did not read and draw on the terminal' >&2; exit 1; }
grep -Fq '[choose]' "$gum_log" && grep -Fq '[--header=nix-config  (' "$gum_log" || {
  echo 'bro test: the main menu did not go through gum choose' >&2; exit 1; }
grep -Eq '\[Apply +.*activate this checkout' "$gum_log" || {
  echo 'bro test: the styled main menu lost its descriptions' >&2; exit 1; }
# A description that fits stays whole; one that does not ends in an ellipsis.
expect_gum_row Apply 2 'activate this checkout'
expect_gum_row Update 2 'change pinned versions or update Pi extensions'
case "$(gum_row Update)" in *…) ;; *)
  echo "bro test: the long Update description was not visibly cut at 60 columns: $(gum_row Update)" >&2; exit 1 ;;
esac
! grep -Fq 'choose [1-' <<<"$output" || { echo 'bro test: styled mode also drew the plain menu' >&2; exit 1; }
[ "$(gum_calls)" = 2 ] || { echo 'bro test: the styled menu did not return after Apply' >&2; exit 1; }

# Esc straight away runs nothing and still exits 0, as end-of-input does.
: >"$log"
status=0
run_styled "$apply_home" esc >/dev/null 2>&1 || status=$?
[ "$status" = 0 ] || { echo "bro test: Esc at the first styled menu exited $status" >&2; exit 1; }
! grep -Eq '^nix |^activation$' "$log" || { echo 'bro test: Esc at the styled menu ran a step' >&2; exit 1; }

# A submenu goes through gum and its answer runs; Esc there cancels back to the
# main menu, which is asked again.
mkdir -p "$extensions_home/.local/bin"
command cat >"$extensions_home/.local/bin/pi" <<'EOF'
#!/bin/sh
printf 'pi %s (skip=%s)\n' "$*" "${PI_SKIP_PROTON_PASS:-}" >>"$MOCK_LOG"
EOF
chmod +x "$extensions_home/.local/bin/pi"
: >"$log"
run_styled "$extensions_home" $'pick Update\npick Extensions\nesc' env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 >/dev/null 2>&1
grep -Fq '[--header=What should be updated?]' "$gum_log" || {
  echo 'bro test: the Update submenu did not go through gum' >&2; exit 1; }
grep -Fq 'pi update --extensions (skip=1)' "$log" || {
  echo 'bro test: the Update choice made through gum did not run' >&2; exit 1; }
: >"$log"
run_styled "$extensions_home" $'pick Update\nesc\nesc' env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 >/dev/null 2>&1
! grep -Eq '^(pi update|update-pi|update-playwright-cli) ' "$log" && ! grep -Fq 'nix flake update' "$log" || {
  echo 'bro test: Esc in the Update submenu still updated something' >&2; exit 1; }
[ "$(gum_calls)" = 3 ] || { echo 'bro test: Esc in a submenu did not return to the main menu' >&2; exit 1; }

# confirm goes through gum with today's default, and Esc there is a cancel.
: >"$log"
run_styled "$apply_home" $'pick Sync\nyes\nesc' env MOCK_GIT_MODE=sync >/dev/null 2>&1
grep -Fq '[confirm]' "$gum_log" && grep -Fq '[--default=false]' "$gum_log" || {
  echo 'bro test: the push question did not go through gum confirm defaulting to No' >&2; exit 1; }
grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: Yes in gum confirm did not push' >&2; exit 1; }
for answer in enter esc no; do
  : >"$log"
  run_styled "$apply_home" "pick Sync"$'\n'"$answer"$'\nesc' env MOCK_GIT_MODE=sync >/dev/null 2>&1
  ! grep -Eq '^git .* push($| )' "$log" || { echo "bro test: $answer in gum confirm pushed" >&2; exit 1; }
  [ "$(gum_calls)" = 3 ] || { echo "bro test: $answer in gum confirm did not return to the menu" >&2; exit 1; }
done

# Styled Jobs is one multi-select with the saved jobs already ticked. Enter
# saves exactly what is ticked and applies it; Esc saves and applies nothing.
rm -f "$jobs_file"
: >"$log"
run_styled "$jobs_home" $'pick Jobs\nesc' "${linux[@]}" >/dev/null 2>&1
grep -Fq '[--no-limit]' "$gum_log" && grep -Fq "[--header=Background jobs on $host" "$gum_log" || {
  echo 'bro test: styled Jobs was not a gum multi-select naming this machine' >&2; exit 1; }
grep -Eq '\[Board sync +.*hourly: add your open GitHub issues' "$gum_log" || {
  echo 'bro test: styled Jobs did not list Board sync with its description' >&2; exit 1; }
expect_gum_row 'Board sync' 4 'hourly: add your open GitHub issues to your boards'
! grep -Fq -e '[--selected=' -e '[x]' -e '[ ]' -e '[Done' "$gum_log" || {
  echo 'bro test: styled Jobs ticked a job no file asked for, or kept the plain toggle rows' >&2; exit 1; }
[ ! -e "$jobs_file" ] && ! grep -Eq '^nix |^activation$' "$log" || {
  echo 'bro test: Esc in styled Jobs saved or applied' >&2; exit 1; }
[ "$(gum_calls)" = 3 ] || { echo 'bro test: Esc in styled Jobs did not return to the menu' >&2; exit 1; }

: >"$log"
run_styled "$jobs_home" $'pick Jobs\npick Board sync' "${linux[@]}" >/dev/null 2>&1
[ "$(cat "$jobs_file")" = board-sync ] || { echo 'bro test: ticking Board sync did not save it' >&2; exit 1; }
grep -Fq 'jobs = [ "board-sync" ]; })' "$log" && grep -q '^activation$' "$log" || {
  echo 'bro test: ticking Board sync did not apply it' >&2; exit 1; }

: >"$log"
run_styled "$jobs_home" $'pick Jobs\nesc' "${linux[@]}" >/dev/null 2>&1
grep -Eq '\[--selected=Board sync +.*hourly' "$gum_log" || {
  echo 'bro test: styled Jobs did not show the saved job ticked' >&2; exit 1; }
[ "$(cat "$jobs_file")" = board-sync ] && ! grep -Eq '^nix |^activation$' "$log" || {
  echo 'bro test: Esc in styled Jobs changed the saved jobs' >&2; exit 1; }

: >"$log"
run_styled "$jobs_home" $'pick Jobs\nenter' "${linux[@]}" >/dev/null 2>&1
[ "$(cat "$jobs_file")" = board-sync ] && grep -Fq 'jobs = [ "board-sync" ]; })' "$log" \
  && grep -q '^activation$' "$log" || {
  echo 'bro test: Enter on the ticked jobs did not keep and apply them' >&2; exit 1; }

: >"$log"
run_styled "$jobs_home" $'pick Jobs\npick' "${linux[@]}" >/dev/null 2>&1
[ -e "$jobs_file" ] && [ ! -s "$jobs_file" ] && grep -Fq 'jobs = [ ]; })' "$log" \
  && grep -q '^activation$' "$log" || {
  echo 'bro test: unticking every job did not save and apply an empty list' >&2; exit 1; }

# An unknown name is refused before the multi-select opens.
printf '%s\n' weekly-backup >"$jobs_file"
: >"$log"
output=$(run_styled "$jobs_home" $'pick Jobs\nesc' "${linux[@]}" 2>&1)
grep -Fq "unknown background job \"weekly-backup\" in $jobs_file" <<<"$output" \
  && [ "$(gum_calls)" = 2 ] && [ "$(cat "$jobs_file")" = weekly-backup ] || {
  echo 'bro test: styled Jobs did not refuse an unknown job before asking' >&2; exit 1; }

# A pre-ticked label with a comma still starts ticked: gum splits --selected on
# commas, so the comma has to reach it escaped. No job label has one yet, so
# the prompt is driven directly.
: >"$gum_log"
rm -f "$gum_state"
output=$(printf '\004' | "$pty_run" env -u NIX_CONFIG_TEST_PLAIN PATH="$gumbin:$PATH" \
  MOCK_GUM_LOG="$gum_log" MOCK_GUM_STATE="$gum_state" MOCK_GUM_ANSWERS=enter \
  bash -c '
    set -euo pipefail
    . "$1/scripts/lib/core.sh"
    shift
    CHOSEN_INDEXES=(2)
    choose_many Title "apply and return" "$@"
    printf "chosen=%s\n" "${CHOSEN_INDEXES[*]:-none}"
  ' _ "$repo_root" $'Plain\tone job' $'Comma\tthis, that, and c:\\path' 2>&1)
grep -Fq 'chosen=2' <<<"$output" || {
  echo "bro test: a pre-ticked label with a comma did not start ticked: $output" >&2; exit 1; }

# The switch and a missing gum both keep the plain numbered prompts, which
# then work as usual.
: >"$log"
output=$(run_styled "$apply_home" '' NIX_CONFIG_TEST_PLAIN=1 2>&1)
[ ! -s "$gum_log" ] && grep -Fq 'choose [1-' <<<"$output" || {
  echo 'bro test: the plain switch did not keep the plain prompts' >&2; exit 1; }
# gum shares a directory with tools bro needs, such as ~/.nix-profile/bin, so
# the host's tools are linked one by one, first on PATH winning, all but gum.
no_gum_bin="$work/no-gum-bin"
mkdir -p "$no_gum_bin"
IFS=: read -r -a path_entries <<<"$PATH"
for entry in "${path_entries[@]}"; do
  for tool in "$entry"/*; do
    name=${tool##*/}
    [ "$name" != gum ] && [ -x "$tool" ] && [ ! -e "$no_gum_bin/$name" ] || continue
    ln -s "$tool" "$no_gum_bin/$name"
  done
done
: >"$log"
status=0
output=$(printf '1\n%s\n' "$quit" | "$pty_run" env -u XDG_STATE_HOME -u NIX_CONFIG_TEST_PLAIN \
  HOME="$apply_home" USER=apply-user PATH="$mockbin:$no_gum_bin" "$bro" 2>&1) || status=$?
[ "$status" = 0 ] && grep -Fq 'choose [1-' <<<"$output" && grep -q '^activation$' "$log" || {
  echo 'bro test: without gum, bro did not fall back to working plain prompts' >&2; exit 1; }

# --- log box ------------------------------------------------------------------

# This nix prints MOCK_BOX_LINES numbered progress lines on stderr, then is
# silent for MOCK_BOX_SILENCE seconds, then fails when MOCK_BOX_FAIL is set.
# The activation it builds prints MOCK_BOX_ACTIVATE_LINES numbered lines.
boxbin="$work/box-bin"
mkdir -p "$boxbin"
command cat >"$boxbin/nix" <<EOF
#!/usr/bin/env bash
printf 'nix %s\\n' "\$*" >>"\$MOCK_LOG"
[ "\$1" = build ] || exit 1
for ((line = 1; line <= \${MOCK_BOX_LINES:-0}; line++)); do
  printf "copying path '/nix/store/box-%d' from 'https://cache.nixos.org'...\\n" "\$line" >&2
done
"$real_sleep" "\${MOCK_BOX_SILENCE:-0}"
[ -z "\${MOCK_BOX_FAIL:-}" ] || { printf 'error: builder for box failed\\n' >&2; exit 1; }
mkdir -p "\$MOCK_ACTIVATION"
{
  printf '#!/bin/sh\\n'
  printf 'printf "activation\\\\n" >>"\$MOCK_LOG"\\n'
  printf 'for line in \$(seq 1 %d); do printf "activation step %%s\\\\n" "\$line"; done\\n' "\${MOCK_BOX_ACTIVATE_LINES:-0}"
} >"\$MOCK_ACTIVATION/activate"
chmod +x "\$MOCK_ACTIVATION/activate"
printf '%s\\n' "\$MOCK_ACTIVATION"
EOF
chmod +x "$boxbin/nix"

# Each case gets a home of its own, so it sees only its own logs.
box_case=0
new_box_home() {
  box_case=$((box_case + 1))
  box_home="$work/box-home-$box_case"
  box_logs="$box_home/.local/state/bro/logs"
  mkdir -p "$box_home/.nix-profile/bin" "$box_home/.config/tmux"
  record_checkout "$box_home"
  cp "$apply_home/.nix-profile/bin/tmux" "$box_home/.nix-profile/bin/tmux"
  cp "$apply_home/.config/tmux/tmux.conf" "$box_home/.config/tmux/tmux.conf"
}

# Styled Apply with the box nix, then Esc at the menu it returns to.
run_box_apply() {
  local target_home=$1 && shift
  run_styled "$target_home" $'pick Apply\nesc' env PATH="$boxbin:$gumbin:$mockbin:$PATH" "$@"
}

# What the terminal was sent, with colours, cursor moves and carriage returns
# dropped, so frames read as plain lines.
plain_screen() {
  sed -e $'s/\e\\[[0-9;?]*[A-Za-z]//g' -e $'s/\r//g'
}

box_log_file() {
  local logs=("$box_logs"/apply-*.log)
  [ "${#logs[@]}" = 1 ] && [ -f "${logs[0]}" ] || {
    echo "bro test: expected exactly one Apply log in $box_logs" >&2; exit 1; }
  printf '%s\n' "${logs[0]}"
}

# Many lines: the box shows the last six, cut to fit, and counts them all.
# Both steps then shrink to ✓ lines, followed by the finish line and the log.
new_box_home
: >"$log"
raw=$(run_box_apply "$box_home" MOCK_BOX_LINES=40 MOCK_BOX_SILENCE=1 MOCK_BOX_ACTIVATE_LINES=8 2>&1)
screen=$(plain_screen <<<"$raw")
grep -q '^activation$' "$log" || { echo 'bro test: boxed Apply did not activate' >&2; exit 1; }
grep -Eq '^╭─ . build ─+ 0:0[0-9] ─╮$' <<<"$screen" || {
  echo 'bro test: the build box had no spinner, step name, and elapsed time in its title' >&2; exit 1; }
grep -Eq '^╰─+ last 6 of 40 ─╯$' <<<"$screen" || {
  echo 'bro test: the build box did not count every line it was sent' >&2; exit 1; }
grep -Fq "│ copying path '/nix/store/box-40' from 'https://cache.ni… │" <<<"$screen" || {
  echo 'bro test: the build box did not show the newest line cut to fit with an ellipsis' >&2; exit 1; }
! grep -Fq "box-34'" <<<"$screen" || {
  echo 'bro test: the build box showed more than the last six lines' >&2; exit 1; }
while IFS= read -r row; do
  measured=${row//…/.}
  [ "${#measured}" -le 60 ] || { echo "bro test: a box row is wider than 60 columns: $row" >&2; exit 1; }
done < <(grep -E '^[╭│╰]' <<<"$screen")
grep -Fq 'nix build --impure --no-link --print-out-paths --print-build-logs' "$log" || {
  echo 'bro test: the boxed build did not ask Nix for its build logs' >&2; exit 1; }
# Durations are whole seconds, so which one a second boundary lands in varies.
summary=$(grep -E '^ (✓|✗) |^   log: ' <<<"$screen" | sed -E 's/ [0-9]+s$/ Ns/')
expected_summary=$(printf '%s\n' ' ✓ build  Ns' ' ✓ activate  Ns' ' ✓ reloaded active tmux configuration' \
  ' ✓ Apply finished in Ns' "   log: ~/.local/state/bro/logs/$(basename "$(box_log_file)")")
[ "$summary" = "$expected_summary" ] || {
  printf 'bro test: styled Apply did not end in its step and finish lines:\n%s\n' "$summary" >&2; exit 1; }
! grep -Fq 'nix-config: building' <<<"$screen" || {
  echo 'bro test: styled Apply still printed the plain progress lines' >&2; exit 1; }
[ "$(gum_calls)" = 2 ] || { echo 'bro test: the menu did not return after a boxed Apply' >&2; exit 1; }
# The cursor is hidden while a box is drawn and always shown again.
[ "$(grep -o $'\e\\[?25[lh]' <<<"$raw" | tail -n 1)" = $'\e[?25h' ] || {
  echo 'bro test: a box left the cursor hidden' >&2; exit 1; }

# The log holds every line of both steps, the build's result included.
box_log=$(box_log_file)
for line in $(seq 1 40); do
  grep -Fxq "copying path '/nix/store/box-$line' from 'https://cache.nixos.org'..." "$box_log" || {
    echo "bro test: the Apply log lost build line $line" >&2; exit 1; }
done
for line in $(seq 1 8); do
  grep -Fxq "activation step $line" "$box_log" || {
    echo "bro test: the Apply log lost activation line $line" >&2; exit 1; }
done
grep -Fxq "$work/activation" "$box_log" || { echo 'bro test: the Apply log lost the build result' >&2; exit 1; }

# A silent step still moves: the spinner turns and the timer counts.
new_box_home
raw=$(run_box_apply "$box_home" MOCK_BOX_SILENCE=3 2>&1)
screen=$(plain_screen <<<"$raw")
spinners=$(grep -E '^╭─ . build ' <<<"$screen" | sed 's/ build .*//' | sort -u | wc -l | tr -d ' ')
[ "$spinners" -ge 5 ] || {
  echo "bro test: the spinner showed only $spinners frames through three silent seconds" >&2; exit 1; }
for clock in 0:00 0:01 0:02; do
  grep -Eq "^╭─ . build ─+ $clock ─╮\$" <<<"$screen" || {
    echo "bro test: the timer never showed $clock while the step was silent" >&2; exit 1; }
done
grep -Eq '^╰─+╯$' <<<"$screen" || { echo 'bro test: an empty box did not close cleanly' >&2; exit 1; }

# A failing build shows its last 30 lines and why, Apply fails with today's
# message, and the menu is offered again.
new_box_home
: >"$log"
status=0
raw=$(run_box_apply "$box_home" MOCK_BOX_LINES=40 MOCK_BOX_FAIL=1 2>&1) || status=$?
[ "$status" = 0 ] || { echo "bro test: a failed boxed build ended bro with $status" >&2; exit 1; }
# What stays on screen starts where the box was last cleared.
tail_screen=$(plain_screen <<<"${raw##*$'\e[J'}")
expected_tail=$(for line in $(seq 12 40); do
    printf "copying path '/nix/store/box-%d' from 'https://cache.nixos.org'...\n" "$line"
  done
  printf '%s\n' 'error: builder for box failed' ' ✗ build failed')
[ "$(head -n 31 <<<"$tail_screen")" = "$expected_tail" ] || {
  printf 'bro test: a failed build did not show exactly its last 30 lines and the failed step:\n%s\n' "$tail_screen" >&2; exit 1; }
for expected in 'nix-config: ERROR: Home Manager activation package build failed for' ' ✗ Apply failed' \
  '   log: ~/.local/state/bro/logs/apply-' 'nix-config: returning to the menu'; do
  grep -Fq -- "$expected" <<<"$tail_screen" || {
    echo "bro test: a failed boxed build did not report: $expected" >&2; exit 1; }
done
! grep -q '^activation$' "$log" || { echo 'bro test: Apply activated after a failed build' >&2; exit 1; }
[ "$(gum_calls)" = 2 ] || { echo 'bro test: the menu did not return after a failed boxed build' >&2; exit 1; }
grep -Fxq 'error: builder for box failed' "$(box_log_file)" || {
  echo 'bro test: the Apply log lost the build error' >&2; exit 1; }

# Plain Apply prints exactly what it always has, and still writes the log. The
# answers were typed ahead and echoed then, so the first line of Apply's output
# follows the menu prompt, and the menu's blank line ends it.
new_box_home
output=$(run_menu "$box_home" "1\n${quit}\n" env PATH="$boxbin:$mockbin:$PATH" MOCK_BOX_LINES=3 MOCK_BOX_ACTIVATE_LINES=2 2>&1)
apply_output=$(printf '%s\n' "${output//$'\r'/}" | sed -n '/^  choose \[1-[0-9]*\]: ./,/^$/p' \
  | sed -e '1s/^  choose \[1-[0-9]*\]: //')
platform_name=$(sed -n 's/^nix-config  (\([^)]*\)).*/\1/p' <<<"$output" | head -n 1)
expected_output=$(printf 'nix-config: building %s\n' "$platform_name"
  for line in 1 2 3; do printf "copying path '/nix/store/box-%d' from 'https://cache.nixos.org'...\n" "$line"; done
  printf 'nix-config: activating %s\n' "$platform_name"
  printf 'activation step %d\n' 1 2
  printf '%s\n' 'nix-config: reloaded active tmux configuration')
[ "$apply_output" = "$expected_output" ] || {
  printf 'bro test: plain Apply output changed:\n%s\n' "$apply_output" >&2; exit 1; }
# A captured result is logged once its step ends, after the step's progress.
expected_log=$(sed -n '2,4p' <<<"$expected_output"; printf '%s\n' "$work/activation"; sed -n '6,7p' <<<"$expected_output")
[ "$(cat "$(box_log_file)")" = "$expected_log" ] || {
  echo 'bro test: plain Apply did not write every line to the log' >&2; exit 1; }

# Only the 20 newest logs are kept: the 21st deletes the oldest.
new_box_home
mkdir -p "$box_logs"
for index in $(seq -w 1 20); do
  touch -t "2020010100$index" "$box_logs/apply-old-$index.log"
done
run_menu "$box_home" "1\n${quit}\n" >/dev/null
[ "$(find "$box_logs" -name '*.log' | wc -l | tr -d ' ')" = 20 ] || {
  echo 'bro test: a 21st log did not leave exactly 20' >&2; exit 1; }
[ ! -e "$box_logs/apply-old-01.log" ] && [ -e "$box_logs/apply-old-02.log" ] || {
  echo 'bro test: a 21st log did not delete exactly the oldest' >&2; exit 1; }

echo 'bro test: PASSED (menu-only entry, apply identity, DNS retry, sync push boundary, accounts wrapper, Pi extensions, Pi + ext, Playwright, Jobs, styled prompts, log box)'
