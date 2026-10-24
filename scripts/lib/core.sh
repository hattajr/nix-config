# Terminal interaction shared by every entry point.
#
# Nothing here reads configuration from the environment. Every choice a user
# makes is a prompt, so the only documented interface is the menu. The
# NIX_CONFIG_TEST_* variables read elsewhere in this library exist solely so
# the test suite can inject fixtures; they are never part of the user surface.

log() { printf 'nix-config: %s\n' "$*"; }
warn() { printf 'nix-config: %s\n' "$*" >&2; }
fail() { printf 'nix-config: ERROR: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$1"; }

# Prompts always use the controlling terminal rather than stdin: the installer
# reaches this code through "curl | sh", where stdin carries the script itself.
# NIX_CONFIG_TEST_NO_TTY lets the test suite assert unattended behaviour from a
# terminal; it is a harness seam and never part of the user surface.
has_tty() {
  [ -z "${NIX_CONFIG_TEST_NO_TTY:-}" ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

require_tty() {
  has_tty || fail "$1 needs a terminal; run it from an interactive shell"
}

# Styled prompts need a terminal and gum; without either, the plain prompts
# below keep working. bro draws its styled prompts itself, because gum cannot
# be taught a key such as q; gum on PATH still marks a machine Home Manager has
# set up, and before that a first install shows the plain prompts.
# NIX_CONFIG_TEST_PLAIN pins the plain prompts so the suite can assert their
# exact text on a host that has gum; it is a harness seam and never part of the
# user surface.
styled_prompts() {
  [ -z "${NIX_CONFIG_TEST_PLAIN:-}" ] && has_tty && command -v gum >/dev/null 2>&1
}

# Only the terminal's own 16 colours, so styled prompts follow its theme.
readonly STYLE_ACCENT=6
readonly STYLE_DIM=$'\e[2m' STYLE_UNDIM=$'\e[22m'

# Result markers in the terminal's own green, yellow and red; an optional
# result is only dimmed.
styled_mark() {
  case "$1" in
    ok) printf '\e[32m✓\e[39m' ;;
    warn) printf '\e[33m!\e[39m' ;;
    fail) printf '\e[31m✗\e[39m' ;;
    *) printf '%s·%s' "$STYLE_DIM" "$STYLE_UNDIM" ;;
  esac
}

# Styled rows fit in 60 columns, or in the terminal when it is narrower. A
# terminal that reports no size gets the full 60.
styled_width() {
  local size columns
  size=$(stty size </dev/tty 2>/dev/null) || size=''
  columns=${size#* }
  case "$columns" in '' | 0 | *[!0-9]*) columns=60 ;; esac
  [ "$columns" -le 60 ] || columns=60
  printf '%s\n' "$columns"
}

# q at any prompt quits at once, from the menu or from deep inside an action,
# while Esc only leaves the prompt. Actions run in subshells, so quitting
# leaves each one with QUIT, its caller quits in turn, and the outermost shell
# exits with success. QUIT_CLEANUP, when set, is a command that must run
# before quitting from the prompts it guards.
readonly QUIT=118
QUIT_CLEANUP=()
quit_now() {
  [ "${#QUIT_CLEANUP[@]}" = 0 ] || "${QUIT_CLEANUP[@]}"
  [ "$BASH_SUBSHELL" = 0 ] || exit "$QUIT"
  exit 0
}

# Answer defaults to the capitalised letter so a bare Return is always safe.
confirm() {
  local question=$1 default=${2:-no}
  require_tty 'this step'
  if styled_prompts; then
    confirm_styled "$question" "$default"
  else
    confirm_plain "$question" "$default"
  fi
}

confirm_plain() {
  local question=$1 default=$2 answer
  while true; do
    case "$default" in
      yes) printf '%s [Y/n] ' "$question" >/dev/tty ;;
      *) printf '%s [y/N] ' "$question" >/dev/tty ;;
    esac
    IFS= read -r answer </dev/tty || { printf '\n' >/dev/tty; return 1; }
    [ -n "$answer" ] || answer=$default
    case "$answer" in
      y | Y | yes | YES) return 0 ;;
      n | N | no | NO) return 1 ;;
      q | Q) quit_now ;;
      *) warn 'Please answer y or n, or q to quit.' ;;
    esac
  done
}

confirm_styled() {
  local status=0
  pick_yes_or_no "$1" "$2" || status=$?
  picker_answered "$status" confirm
}

# A label longer than the usual column widens it so descriptions stay aligned.
label_column_width() {
  local option label width=12
  for option in "$@"; do
    label=${option%%$'\t'*}
    [ "${#label}" -le "$width" ] || width=${#label}
  done
  printf '%s\n' "$width"
}

# Sets CHOICE_INDEX to the 1-based index of the chosen label, or returns 1 when
# the prompt is left without a choice. Callers pass labels as
# "key<TAB>description" so the menu can align its own columns.
CHOICE_INDEX=0
choose() {
  require_tty 'the menu'
  if styled_prompts; then
    choose_styled "$@"
  else
    choose_plain "$@"
  fi
}

choose_plain() {
  local title=$1 && shift
  local options=("$@") count=$# index answer label description width
  width=$(label_column_width "$@")
  while true; do
    printf '\n%s\n\n' "$title" >/dev/tty
    for index in "${!options[@]}"; do
      label=${options[index]%%$'\t'*}
      description=${options[index]#*$'\t'}
      if [ "$label" = "$description" ]; then
        printf '  %d) %s\n' "$((index + 1))" "$label" >/dev/tty
      else
        printf '  %d) %-*s %s\n' "$((index + 1))" "$width" "$label" "$description" >/dev/tty
      fi
    done
    printf '\n  choose [1-%d, q quits]: ' "$count" >/dev/tty
    IFS= read -r answer </dev/tty || { printf '\n' >/dev/tty; return 1; }
    case "$answer" in
      q | Q) quit_now ;;
      '' | *[!0-9]*) warn "Enter a number from 1 to $count, or q to quit." ; continue ;;
    esac
    if [ "$answer" -ge 1 ] && [ "$answer" -le "$count" ]; then
      CHOICE_INDEX=$answer
      return 0
    fi
    warn "Enter a number from 1 to $count, or q to quit."
  done
}

# Prints one styled row per option: the aligned label and dimmed description.
# The picker draws MARKS columns before each row (its cursor, and in a
# multi-select a tick mark), and a description too long for what is left ends
# in an ellipsis so the cut shows.
styled_rows() {
  local marks=$1 && shift
  local options=("$@") index label description width room
  width=$(label_column_width "$@")
  room=$(($(styled_width) - marks - width - 1))
  for index in "${!options[@]}"; do
    label=${options[index]%%$'\t'*}
    description=${options[index]#*$'\t'}
    if [ "$label" = "$description" ] || [ "$room" -le 0 ]; then
      printf '%s\n' "$label"
      continue
    fi
    [ "${#description}" -le "$room" ] || description="${description:0:room-1}…"
    printf '%-*s %s%s%s\n' "$width" "$label" "$STYLE_DIM" "$description" "$STYLE_UNDIM"
  done
}

choose_styled() {
  local answer status=0
  answer=$(pick_one "$@") || status=$?
  picker_answered "$status" choose || return 1
  CHOICE_INDEX=$answer
}

list_contains() {
  local wanted=$1 item && shift
  for item in "$@"; do
    [ "$item" != "$wanted" ] || return 0
  done
  return 1
}

# Ticks the options whose 1-based indexes CHOSEN_INDEXES holds. Done leaves the
# ticked indexes there in option order; leaving the prompt any other way returns
# 1 with CHOSEN_INDEXES as it was. Plain prompts end the list with a Done row,
# which the caller describes because Done is what commits the choice.
CHOSEN_INDEXES=()
choose_many() {
  require_tty 'the menu'
  if styled_prompts; then
    choose_many_styled "$@"
  else
    choose_many_plain "$@"
  fi
}

# The ticked set is kept in option order whatever order the toggles produced
# it in.
set_chosen_indexes() {
  local count=$1 index chosen=() && shift
  for ((index = 1; index <= count; index++)); do
    ! list_contains "$index" "$@" || chosen+=("$index")
  done
  CHOSEN_INDEXES=("${chosen[@]+"${chosen[@]}"}")
}

choose_many_plain() {
  local title=$1 done=$2 && shift 2
  local options=("$@") count=$# rows=() ticked=() remaining=() index mark kept
  ticked=("${CHOSEN_INDEXES[@]+"${CHOSEN_INDEXES[@]}"}")
  while true; do
    rows=()
    for index in "${!options[@]}"; do
      if list_contains "$((index + 1))" "${ticked[@]+"${ticked[@]}"}"; then mark='[x]'; else mark='[ ]'; fi
      rows+=("$mark ${options[index]}")
    done
    rows+=("Done"$'\t'"$done")
    choose_plain "$title" "${rows[@]}" || return 1
    [ "$CHOICE_INDEX" -le "$count" ] || break

    if list_contains "$CHOICE_INDEX" "${ticked[@]+"${ticked[@]}"}"; then
      remaining=()
      for kept in "${ticked[@]}"; do
        [ "$kept" = "$CHOICE_INDEX" ] || remaining+=("$kept")
      done
      ticked=("${remaining[@]+"${remaining[@]}"}")
    else
      ticked+=("$CHOICE_INDEX")
    fi
  done
  set_chosen_indexes "$count" "${ticked[@]+"${ticked[@]}"}"
}

choose_many_styled() {
  local count=$(($# - 2)) answer index answers=() status=0
  answer=$(pick_many "$@") || status=$?
  picker_answered "$status" choose || return 1
  for index in $answer; do
    answers+=("$index")
  done
  set_chosen_indexes "$count" "${answers[@]+"${answers[@]}"}"
}

# --- styled pickers -----------------------------------------------------------

# A picker answers 0, leaves with 1 on Esc or a lost terminal and with 130 on
# ctrl-c, both of which count as leaving the prompt, as end-of-input does at a
# plain prompt, and returns QUIT on q. Any other status is a failure that must
# not pass for an answer.
picker_answered() {
  case "$1" in
    0) return 0 ;;
    1 | 130) return 1 ;;
    "$QUIT") quit_now ;;
    *) fail "the $2 prompt failed with exit status $1" ;;
  esac
}

# A lone Esc and the start of an arrow key's escape sequence begin with the
# same byte, so after an Esc the reader waits briefly for more. Bash before 4
# waits only in whole seconds.
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  readonly ESCAPE_WAIT=0.05
else
  readonly ESCAPE_WAIT=1
fi

# Sets KEY to the next key pressed: up, down, left, right, home, end, enter,
# tab, esc, the character typed, or eof once the terminal is gone. An escape
# sequence for any other key is ''. Alt with a key arrives as Esc followed at
# once by that key, and no prompt uses one, so it counts as Esc.
KEY=''
read_key() {
  local char
  IFS= read -rsn1 char </dev/tty || { KEY=eof; return 0; }
  case "$char" in
    '' | $'\r' | $'\n') KEY=enter ;;
    $'\t') KEY=tab ;;
    $'\e') read_escape_key ;;
    *) KEY=$char ;;
  esac
}

read_escape_key() {
  local char sequence=''
  if ! IFS= read -rsn1 -t "$ESCAPE_WAIT" char </dev/tty; then
    KEY=esc
    return 0
  fi
  case "$char" in
    '[' | O) ;;
    *) KEY=esc; return 0 ;;
  esac
  # A sequence ends at its first letter or tilde.
  while IFS= read -rsn1 -t "$ESCAPE_WAIT" char </dev/tty; do
    sequence+=$char
    case "$char" in [[:alpha:]] | '~') break ;; esac
  done
  case "$sequence" in
    A) KEY=up ;;
    B) KEY=down ;;
    C) KEY=right ;;
    D) KEY=left ;;
    H | 1~ | 7~) KEY=home ;;
    F | 4~ | 8~) KEY=end ;;
    *) KEY='' ;;
  esac
}

# Sets FIT_TEXT to TEXT cut to the styled width with an ellipsis. Prompt text
# is plain ASCII, so its length is its width.
FIT_TEXT=''
fit_text() {
  local text=$1 columns
  columns=$(styled_width)
  [ "${#text}" -le "$columns" ] || text="${text:0:columns-1}…"
  FIT_TEXT=$text
}

# A picker runs in a subshell of its own, so its traps put the terminal back
# however it ends: echo and line editing stay off while it reads single keys,
# and the cursor stays hidden while it draws. Every line a picker draws fits
# the styled width, so the lines it drew are the rows it moves back over.
PICKER_LINES=0
open_picker() {
  local saved
  saved=$(stty -g </dev/tty)
  trap 'stty "'"$saved"'" </dev/tty 2>/dev/null; printf "\e[?25h" >/dev/tty' EXIT
  trap 'exit 130' INT TERM HUP
  stty -echo -icanon </dev/tty
  printf '\e[?25l' >/dev/tty
  PICKER_LINES=0
}

# The title is drawn once, above the lines the picker redraws, so the prompts
# a session showed can be counted in what the terminal was sent.
draw_picker_title() {
  fit_text "$1"
  printf '\e[3%sm%s\e[39m\n' "$STYLE_ACCENT" "$FIT_TEXT" >/dev/tty
}

# Draws LINES over the ones the picker drew last, in a single write.
draw_picker() {
  local line frame=''
  [ "$PICKER_LINES" = 0 ] || printf -v frame '\r\e[%dA' "$PICKER_LINES"
  for line in "$@"; do
    frame+="$line"$'\e[K\n'
  done
  printf '%s\e[J' "$frame" >/dev/tty
  PICKER_LINES=$#
}

# A finished picker leaves nothing behind: its lines and its title go.
close_picker() {
  printf '\r\e[%dA\e[J' "$((PICKER_LINES + 1))" >/dev/tty
}

# Sets PICKER_HELP to the dimmed line of keys under a picker.
PICKER_HELP=''
picker_help() {
  fit_text "$1"
  PICKER_HELP="$STYLE_DIM$FIT_TEXT$STYLE_UNDIM"
}

# Moves PICKER_CURSOR through COUNT rows for KEY, wrapping at either end, and
# returns 1 for a key that moves nothing.
PICKER_CURSOR=0
move_picker_cursor() {
  local count=$1
  case "$KEY" in
    up | k) PICKER_CURSOR=$(((PICKER_CURSOR + count - 1) % count)) ;;
    down | j) PICKER_CURSOR=$(((PICKER_CURSOR + 1) % count)) ;;
    home | g) PICKER_CURSOR=0 ;;
    end | G) PICKER_CURSOR=$((count - 1)) ;;
    *) return 1 ;;
  esac
}

# Prints the 1-based index of the row picked.
pick_one() (
  local title=$1 && shift
  local count=$# rows=() lines=() row index
  local accent=$'\e[3'"$STYLE_ACCENT"'m' unaccent=$'\e[39m'
  while IFS= read -r row; do
    rows+=("$row")
  done < <(styled_rows 2 "$@")
  picker_help 'enter picks, esc goes back, q quits'
  PICKER_CURSOR=0
  open_picker
  draw_picker_title "$title"
  while true; do
    lines=()
    for index in "${!rows[@]}"; do
      if [ "$index" = "$PICKER_CURSOR" ]; then
        lines+=("$accent> ${rows[index]}$unaccent")
      else
        lines+=("  ${rows[index]}")
      fi
    done
    draw_picker "${lines[@]}" "$PICKER_HELP"
    read_key
    if move_picker_cursor "$count"; then
      continue
    fi
    case "$KEY" in
      enter) close_picker; printf '%s\n' "$((PICKER_CURSOR + 1))"; return 0 ;;
      esc | eof) close_picker; return 1 ;;
      q | Q) close_picker; return "$QUIT" ;;
    esac
  done
)

# Prints the 1-based indexes ticked when Enter is pressed, one per line,
# starting from the ones CHOSEN_INDEXES holds.
pick_many() (
  local title=$1 done=$2 && shift 2
  local count=$# rows=() ticked=() lines=() row index cursor instructions
  local accent=$'\e[3'"$STYLE_ACCENT"'m' unaccent=$'\e[39m'
  while IFS= read -r row; do
    rows+=("$row")
  done < <(styled_rows 4 "$@")
  for index in "${!rows[@]}"; do
    ticked[index]=no
    ! list_contains "$((index + 1))" "${CHOSEN_INDEXES[@]+"${CHOSEN_INDEXES[@]}"}" || ticked[index]=yes
  done
  fit_text "x toggles, enter to $done"
  instructions="$STYLE_DIM$FIT_TEXT$STYLE_UNDIM"
  picker_help 'esc cancels, q quits'
  PICKER_CURSOR=0
  open_picker
  draw_picker_title "$title"
  while true; do
    lines=("$instructions")
    for index in "${!rows[@]}"; do
      cursor='  '
      [ "$index" != "$PICKER_CURSOR" ] || cursor="$accent>$unaccent "
      if [ "${ticked[index]}" = yes ]; then
        lines+=("$cursor$accent✓ ${rows[index]}$unaccent")
      else
        lines+=("$cursor• ${rows[index]}")
      fi
    done
    draw_picker "${lines[@]}" "$PICKER_HELP"
    read_key
    if move_picker_cursor "$count"; then
      continue
    fi
    case "$KEY" in
      x | ' ' | tab)
        if [ "${ticked[PICKER_CURSOR]}" = yes ]; then
          ticked[PICKER_CURSOR]=no
        else
          ticked[PICKER_CURSOR]=yes
        fi
        ;;
      enter)
        close_picker
        for index in "${!ticked[@]}"; do
          [ "${ticked[index]}" = no ] || printf '%s\n' "$((index + 1))"
        done
        return 0
        ;;
      esc | eof) close_picker; return 1 ;;
      q | Q) close_picker; return "$QUIT" ;;
    esac
  done
)

# Yes and No side by side, the picked one in the accent colour.
confirm_buttons() {
  local on=$'\e[30;4'"$STYLE_ACCENT"'m' off=$'\e[37;100m' reset=$'\e[39;49m'
  if [ "$1" = yes ]; then
    printf ' %s  Yes  %s  %s  No  %s' "$on" "$reset" "$off" "$reset"
  else
    printf ' %s  Yes  %s  %s  No  %s' "$off" "$reset" "$on" "$reset"
  fi
}

# Returns 0 for Yes and 1 for No, starting on the DEFAULT button; y and n
# answer at once.
pick_yes_or_no() (
  local question=$1 picked=no
  [ "$2" != yes ] || picked=yes
  picker_help 'enter answers, esc cancels, q quits'
  open_picker
  draw_picker_title "$question"
  while true; do
    draw_picker "$(confirm_buttons "$picked")" "$PICKER_HELP"
    read_key
    case "$KEY" in
      left | right | h | l | tab)
        if [ "$picked" = yes ]; then picked=no; else picked=yes; fi
        ;;
      y | Y) picked=yes; break ;;
      n | N) picked=no; break ;;
      enter) break ;;
      esc | eof) close_picker; return 1 ;;
      q | Q) close_picker; return "$QUIT" ;;
    esac
  done
  close_picker
  [ "$picked" = yes ]
)

# An action that runs logged steps keeps all their output in a log of its own.
# Only the newest logs are kept, so the directory never grows without bound.
readonly ACTION_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/bro/logs"
readonly ACTION_LOGS_KEPT=20
ACTION_LOG=''

# Sets ACTION_LOG to a new, empty log named after the action and the time, then
# prunes the logs past ACTION_LOGS_KEPT.
open_action_log() {
  local name stamp path attempt=1
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  name=${name// /-}
  stamp=$(date +%Y%m%d-%H%M%S)
  if ! mkdir -p "$ACTION_LOG_DIR" || ! chmod 700 "$ACTION_LOG_DIR"; then
    warn "could not create the log directory $ACTION_LOG_DIR"
    return 1
  fi
  path="$ACTION_LOG_DIR/$name-$stamp.log"
  # Two actions within a second each get a log of their own.
  until (set -C && : >"$path") 2>/dev/null; do
    [ "$attempt" -lt 10 ] || { warn "could not create a log in $ACTION_LOG_DIR"; return 1; }
    attempt=$((attempt + 1))
    path="$ACTION_LOG_DIR/$name-$stamp-$attempt.log"
  done
  ACTION_LOG=$path
  prune_action_logs
}

# The newest logs are the ones written last. Every log name is bro's own and
# holds no newline, so listing them one per line is safe.
prune_action_logs() {
  local name kept=0
  # shellcheck disable=SC2012
  ls -t "$ACTION_LOG_DIR" | while IFS= read -r name; do
    case "$name" in *.log) ;; *) continue ;; esac
    kept=$((kept + 1))
    [ "$kept" -le "$ACTION_LOGS_KEPT" ] || rm -f "$ACTION_LOG_DIR/$name"
  done
}

format_duration() {
  if [ "$1" -lt 60 ]; then
    printf '%ds\n' "$1"
  else
    printf '%dm%02ds\n' "$(($1 / 60))" "$(($1 % 60))"
  fi
}

# Styled mode ends an action on one line saying how it went, and where its log
# is when it has one. Plain mode prints nothing more than it always has.
report_action() {
  local outcome=$1 name=$2 seconds=$3 shown=$ACTION_LOG
  styled_prompts || return 0
  case "$shown" in "$HOME"/*) printf -v shown '%s/%s' '~' "${shown#"$HOME"/}" ;; esac
  if [ "$outcome" = ok ]; then
    printf '\n %s %s finished in %s\n' "$(styled_mark ok)" "$name" "$(format_duration "$seconds")"
  else
    printf '\n %s %s failed\n' "$(styled_mark fail)" "$name"
  fi
  [ -z "$shown" ] || printf '   %slog: %s%s\n' "$STYLE_DIM" "$shown" "$STYLE_UNDIM"
}

# An item that the user leaves, at a Back choice or with Esc, before it has
# run anything returns BACKED_OUT: today Accounts' Back or Esc, and Jobs' Esc.
# The menu then comes straight back, with no pause, since there is nothing on
# screen worth keeping. Update's cancel comes after its sync has run, so it is
# not one of these.
readonly BACKED_OUT=117

# Runs a program whose exit status an item passes on to the menu. A program
# that happens to exit with BACKED_OUT or QUIT has failed, not backed out or
# quit, so that status becomes 1. Only for a program: a shell function run
# this way would run without set -e.
pass_on_status() {
  local status=0
  "$@" || status=$?
  case "$status" in "$BACKED_OUT" | "$QUIT") status=1 ;; esac
  return "$status"
}

# Steps are boxed only inside an action, which owns the log, and only in
# styled mode. Elsewhere, as in Apply run from Jobs, a step runs exactly as it
# did before steps were logged.
step_boxes() {
  [ -n "$ACTION_LOG" ] && styled_prompts
}

# A step too quick to box is a ✓ line where steps are boxed, and a log line
# everywhere else.
log_step() {
  if step_boxes; then
    printf ' %s %s\n' "$(styled_mark ok)" "$1"
  else
    log "$1"
  fi
}

# Runs one step of an action, copying its output to the action's log. In
# styled mode a box shows the output as it arrives; in plain mode it streams
# as it always has. A caller capturing stdout still gets it, whole, once the
# step ends, and the box then shows only stderr. A step never asks for input:
# prompts come between steps, never inside a box.
run_logged() {
  local step=$1 result='' status=0 && shift
  if [ -z "$ACTION_LOG" ]; then
    "$@"
    return
  fi
  if [ ! -t 1 ]; then
    result=$(mktemp "${TMPDIR:-/tmp}/bro-step.XXXXXX") || fail 'could not create a step output file'
  fi
  # bro runs with pipefail, so each pipeline fails when its step does, and
  # the step's own status is the first in it.
  if styled_prompts; then
    step_events "$result" "$@" | draw_step_box "$step" >/dev/tty || status=$?
  elif [ -n "$result" ]; then
    "$@" 2>&1 >"$result" | tee -a "$ACTION_LOG" >&2 || status=${PIPESTATUS[0]}
  else
    "$@" 2>&1 | tee -a "$ACTION_LOG" || status=${PIPESTATUS[0]}
  fi
  if [ -n "$result" ]; then
    tee -a "$ACTION_LOG" <"$result"
    rm -f "$result"
  fi
  return "$status"
}

# Output lines reach the box as they are. A line holding only one of these
# control characters carries the clock or, followed by it, the step's status.
# Neither is \001, which older bash versions mangle when reading.
readonly BOX_TICK=$'\036' BOX_END=$'\037'
readonly BOX_ROWS=6 FAILURE_ROWS=30
BOX_SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# Feeds draw_step_box: every output line, a tick ten times a second so the box
# keeps moving while the step is silent, and last the step's status. tee keeps
# the exact output for the log, and grep passes only whole lines on, so a tick
# never lands inside a line. Like draw_step_box it runs in a subshell of its
# own, where an exit trap also runs on ctrl-c.
step_events() (
  local result=$1 ticker status=0 && shift
  while :; do
    sleep 0.1 >/dev/null
    printf '%s\n' "$BOX_TICK"
  done &
  ticker=$!
  # The ticker would otherwise outlive an interrupted step.
  trap 'kill "$ticker" 2>/dev/null' EXIT
  trap 'exit 130' INT TERM HUP
  if [ -n "$result" ]; then
    "$@" </dev/null 2>&1 >"$result" | tee -a "$ACTION_LOG" | grep -a --line-buffered '' \
      || status=${PIPESTATUS[0]}
  else
    "$@" </dev/null 2>&1 | tee -a "$ACTION_LOG" | grep -a --line-buffered '' \
      || status=${PIPESTATUS[0]}
  fi
  kill "$ticker" 2>/dev/null
  printf '%s%s\n' "$BOX_END" "$status"
)

# Box rows hold printable text only. After a carriage return a terminal shows
# what came last, so that is what is kept; escape sequences and any other
# control characters are dropped. Sets PLAIN_TEXT, as this runs for each line
# shown.
PLAIN_TEXT=''
# An escape sequence's parameter, intermediate and final bytes are listed one
# by one: what a range such as @-~ matches follows the locale's collation, and
# under some UTF-8 locales it leaves out the letters, m included.
readonly ESCAPE_SEQUENCE=$'\e\\[[[:digit:];:<=>?]*[] !"#$%&\'()*+,./-]*[]@[:alpha:][\\^_`{|}~]'
plain_text() {
  local text=${1%$'\r'} escape=$ESCAPE_SEQUENCE
  text=${text##*$'\r'}
  text=${text//$'\t'/ }
  while [[ $text =~ $escape ]]; do
    text=${text/"${BASH_REMATCH[0]}"/}
  done
  PLAIN_TEXT=${text//[[:cntrl:]]/}
}

# Sets NEWEST_LINES to the last LIMIT of COUNT lines, as plain text, from a
# ring of the last FAILURE_ROWS raw lines where line N is at N % FAILURE_ROWS.
NEWEST_LINES=()
newest_lines() {
  local limit=$1 count=$2 index && shift 2
  local ring=("$@")
  NEWEST_LINES=()
  for ((index = count > limit ? count - limit : 0; index < count; index++)); do
    plain_text "${ring[index % FAILURE_ROWS]}"
    NEWEST_LINES+=("$PLAIN_TEXT")
  done
}

# Sets BOX_RULE to a horizontal border COUNT columns long.
BOX_RULE=''
box_rule() {
  local count=$1
  [ "$count" -ge 0 ] || count=0
  printf -v BOX_RULE '%*s' "$count" ''
  BOX_RULE=${BOX_RULE// /─}
}

# Draws a running step as a box on the terminal: a spinner, the step name, and
# the elapsed time on top, the step's last BOX_ROWS lines cut to fit, and how
# many lines there were at the bottom. Redrawing only on ticks keeps a burst of
# output to ten frames a second. At the end the box gives way to one ✓ line,
# or on failure to the last FAILURE_ROWS lines and a ✗, and the step's status
# is returned. A line is only stored as it arrives, so a fast step is not held
# back by the box; it is cleaned up for the terminal only if it is shown.
draw_step_box() (
  local step=$1 width started=$SECONDS frame=0 count=0 status=1 line
  local recent=()
  width=$(styled_width)
  # Whatever ends the box, the cursor is shown again.
  trap 'printf "\e[?25h"' EXIT
  trap 'exit 130' INT TERM HUP
  printf '\e[?25l'
  draw_box_frame "$step" "$width" 0 0 0
  while IFS= read -r line; do
    case "$line" in
      "$BOX_TICK")
        frame=$((frame + 1))
        newest_lines "$BOX_ROWS" "$count" "${recent[@]+"${recent[@]}"}"
        printf '\r\e[%dA' "$((BOX_ROWS + 2))"
        draw_box_frame "$step" "$width" "$frame" "$((SECONDS - started))" "$count" \
          "${NEWEST_LINES[@]+"${NEWEST_LINES[@]}"}"
        ;;
      "$BOX_END"*)
        status=${line#"$BOX_END"}
        break
        ;;
      *)
        recent[count % FAILURE_ROWS]=$line
        count=$((count + 1))
        ;;
    esac
  done
  printf '\r\e[%dA\e[J' "$((BOX_ROWS + 2))"
  if [ "$status" = 0 ]; then
    printf ' %s %s  %s%s%s\n' "$(styled_mark ok)" "$step" \
      "$STYLE_DIM" "$(format_duration "$((SECONDS - started))")" "$STYLE_UNDIM"
    return 0
  fi
  newest_lines "$FAILURE_ROWS" "$count" "${recent[@]+"${recent[@]}"}"
  [ "$count" = 0 ] || printf '%s\n' "${NEWEST_LINES[@]}"
  printf ' %s %s failed\n' "$(styled_mark fail)" "$step"
  return "$status"
)

# One frame of a step's box, drawn in a single write: the step, the box width,
# the spinner frame, the seconds elapsed, the number of lines so far, and the
# newest lines.
draw_box_frame() {
  local step=$1 width=$2 frame=$3 seconds=$4 count=$5 && shift 5
  local accent=$'\e[3'"$STYLE_ACCENT"'m' unaccent=$'\e[39m' room=$((width - 4))
  local clock label text padding row frame_text
  printf -v clock '%d:%02d' "$((seconds / 60))" "$((seconds % 60))"
  box_rule "$((width - 10 - ${#step} - ${#clock}))"
  frame_text="$STYLE_DIM╭─$STYLE_UNDIM $accent${BOX_SPINNER[frame % ${#BOX_SPINNER[@]}]} $step$unaccent"
  frame_text+=" $STYLE_DIM$BOX_RULE $clock ─╮$STYLE_UNDIM"$'\e[K\n'
  for ((row = 1; row <= BOX_ROWS; row++)); do
    text=''
    [ "$row" -gt "$#" ] || text=${!row}
    [ "${#text}" -le "$room" ] || text="${text:0:room-1}…"
    printf -v padding '%*s' "$((room - ${#text}))" ''
    frame_text+="$STYLE_DIM│$STYLE_UNDIM $text$padding $STYLE_DIM│$STYLE_UNDIM"$'\e[K\n'
  done
  label=''
  [ "$count" = 0 ] || label=" last $# of $count "
  box_rule "$((width - 3 - ${#label}))"
  frame_text+="$STYLE_DIM╰$BOX_RULE$label─╯$STYLE_UNDIM"$'\e[K\n'
  printf '%s' "$frame_text"
}

# A result to read before the next prompt, such as Update's summary, in a box
# of its own: the title on the top border, then each row cut with … to fit.
# The title is cut too, keeping at least one column of border after it. An
# arrow is one column wide, so it is measured and cut as a one-byte stand-in,
# which counts as one column in any locale.
draw_text_box() {
  local title=$1 && shift
  local accent=$'\e[3'"$STYLE_ACCENT"'m' unaccent=$'\e[39m' arrow=$'\032'
  local width room title_room title_columns=${#title} text columns padding frame_text
  width=$(styled_width)
  room=$((width - 4))
  title_room=$((width - 6))
  if [ "$title_columns" -gt "$title_room" ]; then
    if [ "$title_room" -ge 1 ]; then
      title="${title:0:title_room-1}…"
      title_columns=$title_room
    else
      title='' title_columns=0
    fi
  fi
  box_rule "$((width - 5 - title_columns))"
  frame_text="$STYLE_DIM╭─$STYLE_UNDIM $accent$title$unaccent $STYLE_DIM$BOX_RULE╮$STYLE_UNDIM"$'\n'
  for text in "$@"; do
    text=${text//→/$arrow}
    columns=${#text}
    if [ "$columns" -gt "$room" ]; then
      text="${text:0:room-1}…"
      columns=$room
    fi
    text=${text//$arrow/→}
    printf -v padding '%*s' "$((room - columns))" ''
    frame_text+="$STYLE_DIM│$STYLE_UNDIM $text$padding $STYLE_DIM│$STYLE_UNDIM"$'\n'
  done
  box_rule "$((width - 2))"
  frame_text+="$STYLE_DIM╰$BOX_RULE╯$STYLE_UNDIM"$'\n'
  printf '%s' "$frame_text"
}
