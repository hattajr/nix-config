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
# separator, and the answer goes to stdout. Running out of answers is an Esc,
# so a miscounted script ends the menu instead of hanging the suite.
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; rows=("$@"); break ;;
    --selected=*) ticked+=("${1#--selected=}") ;;
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

# The switch and a missing gum both keep the plain numbered prompts, which
# then work as usual.
: >"$log"
output=$(run_styled "$apply_home" '' NIX_CONFIG_TEST_PLAIN=1 2>&1)
[ ! -s "$gum_log" ] && grep -Fq 'choose [1-' <<<"$output" || {
  echo 'bro test: the plain switch did not keep the plain prompts' >&2; exit 1; }
path_without_gum=''
IFS=: read -r -a path_entries <<<"$PATH"
for entry in "${path_entries[@]}"; do
  [ -x "$entry/gum" ] || path_without_gum="${path_without_gum:+$path_without_gum:}$entry"
done
: >"$log"
status=0
output=$(printf '1\n%s\n' "$quit" | "$pty_run" env -u XDG_STATE_HOME -u NIX_CONFIG_TEST_PLAIN \
  HOME="$apply_home" USER=apply-user PATH="$mockbin:$path_without_gum" "$bro" 2>&1) || status=$?
[ "$status" = 0 ] && grep -Fq 'choose [1-' <<<"$output" && grep -q '^activation$' "$log" || {
  echo 'bro test: without gum, bro did not fall back to working plain prompts' >&2; exit 1; }

echo 'bro test: PASSED (menu-only entry, apply identity, DNS retry, sync push boundary, accounts wrapper, Pi extensions, Pi + ext, Playwright, Jobs, styled prompts)'
