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
  local repo=$1 target=$2 expr package build_logs=()
  command -v nix >/dev/null 2>&1 || fail 'Nix is required'
  # A bad background jobs file stops here, before Nix runs, rather than
  # reaching the build as an empty expression.
  expr=$(home_expr "$repo" "$target" activationPackage) || return 1

  # One build replaces a separate metadata check and drvPath evaluation: an
  # unusable flake or platform fails here with the same diagnosis, two Nix
  # round-trips sooner. In a box, a local build also shows its builder's own
  # output, so a long one visibly works; plain output stays as it always was.
  if step_boxes; then
    build_logs=(--print-build-logs)
  else
    log "building $target"
  fi
  package=$(run_logged build run_nix_with_dns_retry nix build --impure --no-link --print-out-paths \
    "${build_logs[@]+"${build_logs[@]}"}" --expr "$expr") \
    || fail "Home Manager activation package build failed for $target"
  [ -x "$package/activate" ] || fail 'built activation package has no executable activate script'

  step_boxes || log "activating $target"
  run_logged activate "$package/activate"

  # Home Manager updates the configuration link, but an already-running tmux
  # server keeps its previous state until reloaded. Do not start a server
  # merely to reload it.
  local tmux_binary="$HOME/.nix-profile/bin/tmux"
  local tmux_config="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
  if [ -x "$tmux_binary" ] && [ -r "$tmux_config" ] \
    && "$tmux_binary" source-file "$tmux_config" >/dev/null 2>&1; then
    log_step 'reloaded active tmux configuration'
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
# committed. Confirming the choice always saves and applies, which starts or
# stops the timers right away; leaving the prompt any other way changes nothing.
background_jobs() {
  local repo=$1 target=$2 host saved index job label
  local options=() enabled=()
  saved=$(read_background_jobs) || return 1
  host=$(uname -n)

  CHOSEN_INDEXES=()
  for index in "${!BACKGROUND_JOBS[@]}"; do
    job=${BACKGROUND_JOBS[index]}
    label=$(background_job_label "$job") || return 1
    options+=("$label")
    ! grep -Fxq "$job" <<<"$saved" || CHOSEN_INDEXES+=("$((index + 1))")
  done
  choose_many "Background jobs on $host" 'apply and return' "${options[@]}" || return 0

  for index in "${CHOSEN_INDEXES[@]+"${CHOSEN_INDEXES[@]}"}"; do
    enabled+=("${BACKGROUND_JOBS[index - 1]}")
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

readonly BOARD_SYNC_UNIT=gh-board-sync.service

# systemd keeps a unit's last outcome only in memory, so "not run yet" means not
# since the user manager started. A oneshot never stays active: success leaves
# it inactive with Result=success and an exit time, a failure leaves it failed
# with any other Result, and each start resets Result and clears the exit time.
board_sync_health() {
  local jobs state key value load='' active='' result='' exited='' changed=''
  # An unreadable or unknown jobs file is already a core failure from the output check.
  jobs=$(read_background_jobs 2>/dev/null) || return 0
  grep -Fxq board-sync <<<"$jobs" || return 0

  command -v systemctl >/dev/null 2>&1 || {
    health_result warn jobs 'board sync is enabled, but systemctl is unavailable to report its last run'
    return 0
  }
  state=$(systemctl --user show "$BOARD_SYNC_UNIT" -p LoadState -p ActiveState -p Result \
    -p ExecMainExitTimestamp -p StateChangeTimestamp 2>&1) || {
    health_result warn jobs "board sync is enabled, but the systemd user manager did not answer: ${state%%$'\n'*}"
    return 0
  }
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState) load=$value ;;
      ActiveState) active=$value ;;
      Result) result=$value ;;
      ExecMainExitTimestamp) exited=$value ;;
      StateChangeTimestamp) changed=$value ;;
    esac
  done <<<"$state"

  if [ "$load" != loaded ]; then
    health_result warn jobs "board sync is enabled, but $BOARD_SYNC_UNIT is ${load:-unknown to systemd}; choose Apply from the menu"
  elif [ "$result" != success ]; then
    # Entering the failed state is the failure time even when no process ran,
    # as with start-limit-hit, where the exit time belongs to an earlier run.
    health_result warn jobs "board sync failed at ${changed:-${exited:-an unknown time}} ($result); see journalctl --user -u gh-board-sync"
  elif [ "$active" = activating ]; then
    health_result warn jobs 'board sync is running now, so its outcome is not known yet'
  elif [ -z "$exited" ]; then
    health_result warn jobs 'board sync has not run yet since the systemd user manager started'
  else
    health_result ok jobs "board sync (last run finished $exited)"
  fi
}

# Each check records one result as "level<TAB>area<TAB>message": level is ok,
# warn, fail or optional, and area is core, accounts, path or jobs. Plain mode
# prints each as today's line the moment it is known, so the lines and their
# order among the account check's own output stay exactly as they were. A
# stored message is kept to one line so every result stays one record.
HEALTH_RESULTS=()
health_result() {
  local level=$1 area=$2 message=$3
  HEALTH_RESULTS+=("$level"$'\t'"$area"$'\t'"${message//[$'\t\n']/ }")
  styled_prompts || log "$(health_plain_prefix "$level" "$area")$message"
}

# The prefixes today's plain lines start with.
health_plain_prefix() {
  local level=$1 area=$2 tag
  [ "$level" != ok ] || { printf 'OK: '; return 0; }
  case "$area" in
    core) tag=CORE ;;
    accounts) tag=AUTH ;;
    path) tag=PATH ;;
    jobs) tag=BOARD ;;
    *) fail "unknown Health area: $area" ;;
  esac
  case "$level" in
    warn) printf '%s WARN: ' "$tag" ;;
    fail) printf '%s FAIL: ' "$tag" ;;
    optional) printf '%s OPTIONAL: ' "$tag" ;;
    *) fail "unknown Health level: $level" ;;
  esac
}

readonly HEALTH_AREAS=(core accounts path jobs)
readonly HEALTH_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/bro/health"

# The latest run, for the menu to show later: a "checked<TAB>epoch seconds"
# line, then one result per line in check order. Saving is best effort, so a
# state directory that cannot be written only warns and never fails Health.
save_health_results() {
  local checked_at=$1 state_dir tmp
  state_dir=$(dirname "$HEALTH_STATE_FILE")
  if mkdir -p "$state_dir" && chmod 700 "$state_dir" \
    && tmp=$(mktemp "$state_dir/.health.XXXXXX"); then
    if { printf 'checked\t%s\n' "$checked_at"
      printf '%s\n' "${HEALTH_RESULTS[@]+"${HEALTH_RESULTS[@]}"}"; } >"$tmp" \
      && mv -f "$tmp" "$HEALTH_STATE_FILE"; then
      return 0
    fi
    rm -f "$tmp"
  fi
  warn "could not save the Health results to $HEALTH_STATE_FILE"
}

health_area_heading() {
  case "$1" in
    core) printf 'Core' ;;
    accounts) printf 'Accounts' ;;
    path) printf 'PATH' ;;
    jobs) printf 'Jobs' ;;
  esac
}

# A fix in plain text reads "; choose X from the menu"; a styled line points
# at the menu item instead.
health_styled_message() {
  local message=$1 item
  case "$message" in
    *'; choose '*' from the menu')
      item=${message##*'; choose '}
      printf '%s → %s\n' "${message%'; choose '*}" "${item%' from the menu'}" ;;
    *) printf '%s\n' "$message" ;;
  esac
}

# Results are grouped by area in a fixed order, leaving out an area with none.
# A long message wraps under its own first column.
health_screen() {
  local checked=$1 room area heading result level result_area message line indent
  room=$(($(styled_width) - 4))
  [ "$room" -gt 0 ] || room=1
  printf '\n\e[3%sm%s\e[39m %s· checked %s%s\n' "$STYLE_ACCENT" Health "$STYLE_DIM" "$checked" "$STYLE_UNDIM"
  for area in "${HEALTH_AREAS[@]}"; do
    heading=$(health_area_heading "$area")
    for result in "${HEALTH_RESULTS[@]+"${HEALTH_RESULTS[@]}"}"; do
      IFS=$'\t' read -r level result_area message <<<"$result"
      [ "$result_area" = "$area" ] || continue
      if [ -n "$heading" ]; then
        printf '\e[3%sm%s\e[39m\n' "$STYLE_ACCENT" "$heading"
        heading=''
      fi
      indent="  $(styled_mark "$level") "
      while IFS= read -r line; do
        printf '%s%s\n' "$indent" "${line%"${line##*[! ]}"}"
        indent='    '
      done < <(health_styled_message "$message" | fold -s -w "$room")
    done
  done
}

# Only a core or accounts failure fails Health. A shadowed binary or a Board
# sync problem is a warning, so a first install on a machine with a
# hand-installed tool still succeeds.
health_passed() {
  local result
  for result in "${HEALTH_RESULTS[@]+"${HEALTH_RESULTS[@]}"}"; do
    case "$result" in
      fail$'\t'core$'\t'* | fail$'\t'accounts$'\t'*) return 1 ;;
    esac
  done
}

health() {
  local repo=$1 target=$2
  local locale_output startup_file tmux_socket expr checked
  HEALTH_RESULTS=()
  # One clock reading for both the saved time and the time on screen.
  checked=$(date '+%s %H:%M')

  command -v nix >/dev/null 2>&1 || health_result fail core 'Nix is unavailable'
  if run_nix_with_dns_retry nix flake metadata "path:$repo" >/dev/null; then
    health_result ok core 'checkout metadata'
  else
    health_result fail core 'flake metadata validation failed'
  fi
  if expr=$(home_expr "$repo" "$target" 'activationPackage.drvPath') \
    && run_nix_with_dns_retry nix eval --impure --raw --expr "$expr" >/dev/null; then
    health_result ok core "$target flake output"
  else
    health_result fail core "platform output is unavailable: $target"
  fi

  locale_output=$(locale 2>&1) || {
    health_result fail core "current locale is invalid: ${locale_output//$'\n'/ }"
    if env -u LC_ALL locale >/dev/null 2>&1; then
      health_result fail core 'inherited LC_ALL is the cause; applying in a terminal refreshes it'
    fi
  }
  [ -z "${LC_ALL:-}" ] || health_result warn core 'LC_ALL is set; managed shells inherit the OS locale'

  for startup_file in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    if [ -f "$startup_file" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?LC_ALL=' "$startup_file"; then
      health_result fail core "stale LC_ALL assignment in $startup_file"
    fi
  done

  if [ -x "$HOME/.nix-profile/bin/zsh" ] && env -u LC_ALL "$HOME/.nix-profile/bin/zsh" -lic 'exit' >/dev/null 2>&1; then
    health_result ok core 'managed zsh startup'
  else
    health_result fail core 'managed zsh startup'
  fi

  if [ -x "$HOME/.nix-profile/bin/tmux" ] && [ -r "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" ]; then
    tmux_socket="nix-config-health-$$"
    if "$HOME/.nix-profile/bin/tmux" -L "$tmux_socket" -f "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" new-session -d -s health \
      && "$HOME/.nix-profile/bin/tmux" -L "$tmux_socket" has-session -t health; then
      "$HOME/.nix-profile/bin/tmux" -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
      health_result ok core 'managed tmux server'
    else
      "$HOME/.nix-profile/bin/tmux" -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
      health_result fail core 'managed tmux server'
    fi
  else
    health_result fail core 'managed tmux or configuration is unavailable'
  fi

  if [ -x "$ACCOUNT_SETUP" ]; then
    if "$ACCOUNT_SETUP" --check; then
      health_result ok accounts 'optional account setup check'
    else
      health_result fail accounts 'configured account setup has errors; choose Accounts from the menu'
    fi
  else
    health_result optional accounts 'account setup is not installed yet; apply the configuration first'
  fi

  # A shadowed binary means an older tool runs instead of the managed one. That
  # is a hygiene problem rather than a broken account, so it never fails health.
  if [ -x "$SHADOW_SCANNER" ]; then
    if shadowed_binaries_present; then
      health_result warn path 'unmanaged binaries shadow the Nix profile; choose Clean up from the menu'
    else
      health_result ok path 'no unmanaged binaries shadow the Nix profile'
    fi
  fi

  # An unattended job failing, say on an expired gh token, is worth seeing but
  # breaks nothing here, so like a shadowed binary it never fails health.
  # Background jobs are systemd user timers, which only Linux has.
  case "$target" in
    *-linux) board_sync_health ;;
  esac

  ! styled_prompts || health_screen "${checked#* }"
  save_health_results "${checked%% *}"
  health_passed
}
