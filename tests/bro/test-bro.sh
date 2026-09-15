#!/usr/bin/env bash
# Focused safety checks for the bro menu without a real Nix activation or network.
#
# bro is menu-only, so every case drives the real menu through a pseudo-terminal.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bro="$repo_root/scripts/bro"
pty_run="$repo_root/tests/lib/pty-run"
work=$(mktemp -d)
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
chmod +x "$mockbin/git" "$mockbin/nix" "$mockbin/sleep"
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

run_menu() {
  local target_home=$1 answers=$2 && shift 2
  printf '%b' "$answers" | "$pty_run" env \
    HOME="$target_home" USER=apply-user PATH="$mockbin:$PATH" "$@" "$bro"
}

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
run_menu "$apply_home" '7\n' >/dev/null
! grep -q '^nix ' "$log" || { echo 'bro test: quitting the menu invoked Nix' >&2; exit 1; }
! grep -q '^activation$' "$log" || { echo 'bro test: quitting the menu activated' >&2; exit 1; }
grep -Fq 'remote get-url origin' "$log" || {
  echo 'bro test: the menu did not verify the recorded checkout origin' >&2; exit 1; }

# --- Apply ------------------------------------------------------------------

: >"$log"
output=$(run_menu "$apply_home" '1\n7\n')
grep -q '^activation$' "$log" || { echo 'bro test: Apply did not activate' >&2; exit 1; }
grep -Fq 'nix build --impure --no-link' "$log" || {
  echo 'bro test: Apply did not build with the active user identity' >&2; exit 1; }
grep -Fq "(builtins.getFlake \"path:$checkout\").lib.mkHome" "$log" || {
  echo 'bro test: Apply used a Git flake that hides untracked configuration' >&2; exit 1; }
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
output=$(run_menu "$apply_home" '1\n7\n' env MOCK_NIX_DNS_FAILURES=2 MOCK_NIX_RETRY_STATE="$retry_state" 2>&1)
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
output=$(run_menu "$apply_home" '1\n7\n' env MOCK_NIX_DNS_FAILURES=9 MOCK_NIX_RETRY_STATE="$retry_state" 2>&1)
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
output=$(run_menu "$apply_home" '2\n7\n' 2>&1)
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
run_menu "$apply_home" '2\nn\n7\n' env MOCK_GIT_MODE=sync >/dev/null
! grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: declining the prompt still pushed' >&2; exit 1; }
: >"$log"
run_menu "$apply_home" '2\ny\n7\n' env MOCK_GIT_MODE=sync >/dev/null
grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: accepting the prompt did not push' >&2; exit 1; }

# A bare Return is the likeliest accidental answer, so it must not publish.
: >"$log"
run_menu "$apply_home" '2\n\n7\n' env MOCK_GIT_MODE=sync >/dev/null
! grep -Eq '^git .* push($| )' "$log" || {
  echo 'bro test: an empty answer at the push prompt published commits' >&2; exit 1; }

# With nothing ahead of upstream there is no push prompt at all.
: >"$log"
run_menu "$apply_home" '2\n7\n' env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 >/dev/null
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
run_menu "$auth_home" '4\n7\n' >/dev/null
grep -Fq "proton $auth_home/.local/bin/nix-config-setup" "$log" || {
  echo 'bro test: Linux Accounts did not use the Proton Pass session' >&2; exit 1; }
rm "$auth_home/.local/bin/proton-pass-session"
: >"$log"
run_menu "$auth_home" '4\n7\n' >/dev/null
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
run_menu "$extensions_home" '3\n3\n7\n' env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 >/dev/null
grep -Fq 'pi update --extensions (skip=1)' "$log" || {
  echo 'bro test: Update did not offer a working Pi extension update' >&2; exit 1; }
! grep -Eq '^git .* (add|commit)($| )' "$log" || {
  echo 'bro test: updating Pi extensions touched the pinned files' >&2; exit 1; }
! grep -Fq 'nix flake update' "$log" || {
  echo 'bro test: updating Pi extensions also moved the nixpkgs pin' >&2; exit 1; }

# Without Pi installed the step explains itself rather than failing silently.
rm "$extensions_home/.local/bin/pi"
: >"$log"
output=$(run_menu "$extensions_home" '3\n3\n7\n' env MOCK_GIT_MODE=sync MOCK_GIT_AHEAD=0 2>&1)
grep -Fq 'Pi is not installed for this account yet' <<<"$output" || {
  echo 'bro test: a missing Pi did not explain the extension update failure' >&2; exit 1; }

echo 'bro test: PASSED (menu-only entry, apply identity, DNS retry, sync push boundary, accounts wrapper, Pi extensions)'
