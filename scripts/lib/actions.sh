# The operations the menu offers. Each takes an already-resolved checkout and
# platform, prompts for anything it needs, and never reads configuration from
# the environment.

readonly SHADOW_SCANNER="$HOME/.local/share/nix-config/shadow-scan"
readonly ACCOUNT_SETUP="$HOME/.local/bin/nix-config-setup"
readonly PROTON_PASS_SESSION="$HOME/.local/bin/proton-pass-session"
readonly PI_WRAPPER="$HOME/.local/bin/pi"

# Sync and Update rewrite tracked files, so both refuse to run over uncommitted
# work. Naming that work is the difference between a dead end and a next step.
require_clean_tree() {
  local repo=$1 step=$2 changed count
  changed=$(run_git -C "$repo" status --porcelain)
  [ -n "$changed" ] || return 0
  count=$(printf '%s\n' "$changed" | wc -l | tr -d ' ')
  warn "$step needs a clean checkout, but $repo has $count uncommitted change(s):"
  printf '%s\n' "$changed" | head -n 10 | sed 's/^/      /' >&2
  [ "$count" -le 10 ] || printf '      ... and %d more\n' "$((count - 10))" >&2
  warn "Commit or stash them yourself, then choose $step again."
  return 1
}

apply() {
  local repo=$1 target=$2 expr package
  command -v nix >/dev/null 2>&1 || fail 'Nix is required'
  # A bad background jobs file stops here, before Nix runs, rather than
  # reaching the build as an empty expression.
  expr=$(home_expr "$repo" "$target" activationPackage) || return 1

  # One build replaces a separate metadata check and drvPath evaluation: an
  # unusable flake or platform fails here with the same diagnosis, two Nix
  # round-trips sooner.
  log "building $target"
  package=$(run_nix_with_dns_retry nix build --impure --no-link --print-out-paths --expr "$expr") \
    || fail "Home Manager activation package build failed for $target"
  [ -x "$package/activate" ] || fail 'built activation package has no executable activate script'

  log "activating $target"
  "$package/activate"

  # Home Manager updates the configuration link, but an already-running tmux
  # server keeps its previous state until reloaded. Do not start a server
  # merely to reload it.
  local tmux_binary="$HOME/.nix-profile/bin/tmux"
  local tmux_config="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
  if [ -x "$tmux_binary" ] && [ -r "$tmux_config" ] \
    && "$tmux_binary" source-file "$tmux_config" >/dev/null 2>&1; then
    log 'reloaded active tmux configuration'
  fi
}

sync() {
  local repo=$1 target=$2 upstream ahead behind
  require_clean_tree "$repo" Sync || return 1
  upstream=$(run_git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
    || fail 'this branch has no upstream, so there is nothing to sync from'
  run_git -C "$repo" fetch --prune || fail 'could not reach the remote'
  ahead=$(run_git -C "$repo" rev-list --count "$upstream..HEAD")
  behind=$(run_git -C "$repo" rev-list --count "HEAD..$upstream")
  [ "$ahead" = 0 ] || [ "$behind" = 0 ] \
    || fail "this branch is $ahead ahead and $behind behind $upstream; merge or rebase it yourself first"
  if [ "$behind" != 0 ]; then
    run_git -C "$repo" merge --ff-only "$upstream" || fail 'fast-forward failed'
  fi
  apply "$repo" "$target"
  if [ "$ahead" != 0 ] && confirm 'Push your local commits so other machines receive them?' no; then
    run_git -C "$repo" push || fail 'push failed'
  fi
}

# Every tracked file a pin update may rewrite. Pi's lockfile may not exist yet
# when the first update generates it.
readonly PIN_FILES=(
  flake.lock
  home/modules/pi.nix
  home/modules/pi-package-lock.json
  home/modules/playwright-cli.nix
  home/modules/playwright-cli-package-lock.json
)

is_tracked() {
  run_git -C "$1" ls-files --error-unmatch "$2" >/dev/null 2>&1
}

pinned_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)";.*/\1/p' | head -n 1
}

print_module_update() {
  local repo=$1 module=$2 label=$3
  run_git -C "$repo" diff --quiet -- "$module" && return 0
  printf '  %-10s%s -> %s\n' "$label:" \
    "$(run_git -C "$repo" show "HEAD:$module" | pinned_version)" \
    "$(pinned_version <"$repo/$module")"
}

print_update_summary() {
  local repo=$1 old_nixpkgs new_nixpkgs
  printf '\nProposed version updates:\n'
  print_module_update "$repo" home/modules/pi.nix Pi
  print_module_update "$repo" home/modules/playwright-cli.nix Playwright
  if ! run_git -C "$repo" diff --quiet -- flake.lock; then
    old_nixpkgs=$(run_git -C "$repo" show HEAD:flake.lock | jq -r '.nodes.nixpkgs.locked.rev // "unknown"')
    new_nixpkgs=$(jq -r '.nodes.nixpkgs.locked.rev // "unknown"' "$repo/flake.lock")
    printf '  Nixpkgs:  %s -> %s\n' "${old_nixpkgs:0:12}" "${new_nixpkgs:0:12}"
  fi
}

# Pi's extensions are npm packages that Pi installs into its own writable
# state, so they are updated through Pi rather than pinned in this repository.
# Skip the Proton Pass injection: extension updates reach npm, not a model
# provider, and must not fail on a locked keyring.
update_pi_extensions() {
  [ -x "$PI_WRAPPER" ] || {
    warn 'Pi is not installed for this account yet; apply the configuration first'
    return 1
  }
  log 'updating Pi extensions'
  PI_SKIP_PROTON_PASS=1 "$PI_WRAPPER" update --extensions
}

# The pins live in tracked files and go through review, apply, and commit. Pi's
# extensions are runtime state, so they are updated separately and afterwards,
# against whichever Pi this machine ends up running.
update_pins() {
  local repo=$1 target=$2 update_nixpkgs=$3 update_pi=$4 update_playwright=${5:-no} file

  if [ "$update_nixpkgs" = yes ]; then
    log 'updating the nixpkgs pin'
    run_nix_with_dns_retry nix flake update nixpkgs || {
      warn 'nixpkgs pin update failed'
      return 1
    }
  fi
  if [ "$update_pi" = yes ]; then
    log 'updating the Pi pin'
    "$repo/scripts/update-pi" "$repo" || {
      warn 'Pi pin update failed'
      return 1
    }
  fi
  if [ "$update_playwright" = yes ]; then
    log 'updating the playwright-cli pin'
    "$repo/scripts/update-playwright-cli" "$repo" || {
      warn 'playwright-cli pin update failed'
      return 1
    }
  fi

  if run_git -C "$repo" diff --quiet; then
    log 'all selected pins are already current'
    return 0
  fi
  run_git -C "$repo" diff --check || fail 'update produced invalid whitespace'
  print_update_summary "$repo"

  if confirm 'Show the complete generated diff?' no; then
    run_git -C "$repo" diff
    # A newly generated lockfile is not tracked until the user approves commit.
    for file in "${PIN_FILES[@]}"; do
      [ -f "$repo/$file" ] && ! is_tracked "$repo" "$file" || continue
      run_git -C "$repo" diff --no-index -- /dev/null "$repo/$file" || {
        [ "$?" -eq 1 ] || fail "could not show the generated $file diff"
      }
    done
  fi
  if ! confirm 'Apply these changes on this machine?' no; then
    for file in "${PIN_FILES[@]}"; do
      if is_tracked "$repo" "$file"; then
        run_git -C "$repo" restore --source=HEAD -- "$file"
      else
        rm -f "$repo/$file"
      fi
    done
    log 'update discarded'
    return 0
  fi

  apply "$repo" "$target"
  if ! confirm 'Commit these version-pin changes?' no; then
    log 'changes applied locally but left uncommitted'
    return 0
  fi
  for file in "${PIN_FILES[@]}"; do
    [ ! -f "$repo/$file" ] || run_git -C "$repo" add "$file"
  done
  run_git -C "$repo" commit -m 'Update managed package pins'
  if confirm 'Push the commit so other machines can sync it?' no; then
    run_git -C "$repo" push
  fi
}

update() {
  local repo=$1 target=$2 update_nixpkgs=no update_pi=no update_extensions=no update_playwright=no
  require_clean_tree "$repo" Update || return 1

  # Start from the shared configuration before calculating new upstream pins.
  sync "$repo" "$target"

  choose 'What should be updated?' \
    $'Nixpkgs\tnormal Nix-managed apps' \
    $'Pi\tthe custom Nix package' \
    $'Extensions\tPi\'s own npm packages, not a repository pin' \
    $'Pi + ext\tthe Pi package, then its extensions' \
    $'Playwright\tthe playwright-cli package and its agent skill' \
    $'Everything\tNixpkgs, Pi, Pi extensions, and playwright-cli' \
    $'Cancel\tleave every version as it is' || return 0
  case "$CHOICE_INDEX" in
    1) update_nixpkgs=yes ;;
    2) update_pi=yes ;;
    3) update_extensions=yes ;;
    4) update_pi=yes; update_extensions=yes ;;
    5) update_playwright=yes ;;
    6) update_nixpkgs=yes; update_pi=yes; update_extensions=yes; update_playwright=yes ;;
    7) log 'update cancelled'; return 0 ;;
  esac

  if [ "$update_nixpkgs" = yes ] || [ "$update_pi" = yes ] || [ "$update_playwright" = yes ]; then
    update_pins "$repo" "$target" "$update_nixpkgs" "$update_pi" "$update_playwright" || return 1
  fi
  if [ "$update_extensions" = yes ]; then
    update_pi_extensions
  fi
}

auth() {
  [ -x "$ACCOUNT_SETUP" ] || fail 'account setup is unavailable; apply the configuration first'
  if [ "$(uname -s)" = Linux ] && [ -x "$PROTON_PASS_SESSION" ]; then
    "$PROTON_PASS_SESSION" "$ACCOUNT_SETUP"
  else
    "$ACCOUNT_SETUP"
  fi
}

background_job_label() {
  case "$1" in
    board-sync) printf '%s\t%s\n' 'Board sync' 'hourly: add your open GitHub issues to your boards' ;;
    *) fail "no menu label for background job \"$1\"" ;;
  esac
}

# Which jobs run is per-machine state, so it is chosen here rather than
# committed. Done always saves and applies, which starts or stops the timers
# right away; leaving the prompt any other way changes nothing.
background_jobs() {
  local repo=$1 target=$2 host saved job mark label description kept
  local enabled=() options=() remaining=()
  saved=$(read_background_jobs) || return 1
  for job in $saved; do
    enabled+=("$job")
  done
  host=$(uname -n)

  while true; do
    options=()
    for job in "${BACKGROUND_JOBS[@]}"; do
      if list_contains "$job" "${enabled[@]+"${enabled[@]}"}"; then mark='[x]'; else mark='[ ]'; fi
      IFS=$'\t' read -r label description <<<"$(background_job_label "$job")"
      options+=("$mark $label"$'\t'"$description")
    done
    options+=($'Done\tapply and return')
    choose "Background jobs on $host" "${options[@]}" || return 0
    [ "$CHOICE_INDEX" -le "${#BACKGROUND_JOBS[@]}" ] || break

    job=${BACKGROUND_JOBS[CHOICE_INDEX - 1]}
    if list_contains "$job" "${enabled[@]+"${enabled[@]}"}"; then
      remaining=()
      for kept in "${enabled[@]}"; do
        [ "$kept" = "$job" ] || remaining+=("$kept")
      done
      enabled=("${remaining[@]+"${remaining[@]}"}")
    else
      enabled+=("$job")
    fi
  done

  write_background_jobs "${enabled[@]+"${enabled[@]}"}"
  log "saved background jobs for $host: ${enabled[*]:-none}"
  apply "$repo" "$target"
}

# Callers run actions in a subshell so a failure returns to the menu, which
# means state cannot travel back in a variable. Ask the scanner directly.
shadowed_binaries_present() {
  [ -x "$SHADOW_SCANNER" ] || return 1
  ! "$SHADOW_SCANNER" --check >/dev/null 2>&1
}

shadow_review() {
  [ -x "$SHADOW_SCANNER" ] || fail 'the shadow scanner is unavailable; apply the configuration first'
  "$SHADOW_SCANNER"
}

health() {
  local repo=$1 target=$2
  local core_failed=0 auth_failed=0 locale_output startup_file tmux_socket expr

  command -v nix >/dev/null 2>&1 || { log 'CORE FAIL: Nix is unavailable'; core_failed=1; }
  if run_nix_with_dns_retry nix flake metadata "path:$repo" >/dev/null; then
    log 'OK: checkout metadata'
  else
    log 'CORE FAIL: flake metadata validation failed'; core_failed=1
  fi
  if expr=$(home_expr "$repo" "$target" 'activationPackage.drvPath') \
    && run_nix_with_dns_retry nix eval --impure --raw --expr "$expr" >/dev/null; then
    log "OK: $target flake output"
  else
    log "CORE FAIL: platform output is unavailable: $target"; core_failed=1
  fi

  locale_output=$(locale 2>&1) || {
    log "CORE FAIL: current locale is invalid: ${locale_output//$'\n'/ }"
    if env -u LC_ALL locale >/dev/null 2>&1; then
      log 'CORE FAIL: inherited LC_ALL is the cause; applying in a terminal refreshes it'
    fi
    core_failed=1
  }
  [ -z "${LC_ALL:-}" ] || log 'CORE WARN: LC_ALL is set; managed shells inherit the OS locale'

  for startup_file in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    if [ -f "$startup_file" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?LC_ALL=' "$startup_file"; then
      log "CORE FAIL: stale LC_ALL assignment in $startup_file"
      core_failed=1
    fi
  done

  if [ -x "$HOME/.nix-profile/bin/zsh" ] && env -u LC_ALL "$HOME/.nix-profile/bin/zsh" -lic 'exit' >/dev/null 2>&1; then
    log 'OK: managed zsh startup'
  else
    log 'CORE FAIL: managed zsh startup'; core_failed=1
  fi

  if [ -x "$HOME/.nix-profile/bin/tmux" ] && [ -r "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" ]; then
    tmux_socket="nix-config-health-$$"
    if "$HOME/.nix-profile/bin/tmux" -L "$tmux_socket" -f "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" new-session -d -s health \
      && "$HOME/.nix-profile/bin/tmux" -L "$tmux_socket" has-session -t health; then
      "$HOME/.nix-profile/bin/tmux" -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
      log 'OK: managed tmux server'
    else
      "$HOME/.nix-profile/bin/tmux" -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
      log 'CORE FAIL: managed tmux server'; core_failed=1
    fi
  else
    log 'CORE FAIL: managed tmux or configuration is unavailable'; core_failed=1
  fi

  if [ -x "$ACCOUNT_SETUP" ]; then
    if "$ACCOUNT_SETUP" --check; then
      log 'OK: optional account setup check'
    else
      log 'AUTH FAIL: configured account setup has errors; choose Accounts from the menu'
      auth_failed=1
    fi
  else
    log 'AUTH OPTIONAL: account setup is not installed yet; apply the configuration first'
  fi

  # A shadowed binary means an older tool runs instead of the managed one. That
  # is a hygiene problem rather than a broken account, so it never fails health.
  if [ -x "$SHADOW_SCANNER" ]; then
    if shadowed_binaries_present; then
      log 'PATH WARN: unmanaged binaries shadow the Nix profile; choose Clean up from the menu'
    else
      log 'OK: no unmanaged binaries shadow the Nix profile'
    fi
  fi

  [ "$core_failed" -eq 0 ] || return 1
  [ "$auth_failed" -eq 0 ] || return 1
}
