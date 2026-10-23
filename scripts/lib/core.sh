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
# below keep working. NIX_CONFIG_TEST_PLAIN pins the plain prompts so the suite
# can assert their exact text on a host that has gum; it is a harness seam and
# never part of the user surface.
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

# gum exits 130 on ctrl-c and 1 on Esc or No, which count as leaving the
# prompt, as end-of-input does at a plain prompt. gum also exits 1 for its own
# usage errors, which no status can tell apart; it reports those on the
# terminal itself. Any other status is a failure that must not pass for an
# answer.
gum_answered() {
  case "$1" in
    0) return 0 ;;
    1 | 130) return 1 ;;
    *) fail "gum $2 failed with exit status $1" ;;
  esac
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
      *) warn 'Please answer y or n.' ;;
    esac
  done
}

# gum draws on stderr, so both it and its keys go to the terminal; callers may
# be capturing stdout.
confirm_styled() {
  local question=$1 default=false status=0
  [ "$2" != yes ] || default=true
  gum confirm --default="$default" --no-show-help \
    --prompt.foreground="$STYLE_ACCENT" \
    --selected.foreground=0 --selected.background="$STYLE_ACCENT" \
    --unselected.foreground=7 --unselected.background=8 \
    -- "$question" </dev/tty >/dev/tty 2>/dev/tty || status=$?
  gum_answered "$status" confirm
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
    printf '\n  choose [1-%d]: ' "$count" >/dev/tty
    IFS= read -r answer </dev/tty || { printf '\n' >/dev/tty; return 1; }
    case "$answer" in
      '' | *[!0-9]*) warn "Enter a number from 1 to $count." ; continue ;;
    esac
    if [ "$answer" -ge 1 ] && [ "$answer" -le "$count" ]; then
      CHOICE_INDEX=$answer
      return 0
    fi
    warn "Enter a number from 1 to $count."
  done
}

# Prints one gum row per option: the aligned label and dimmed description, a
# tab, then the option's index. gum shows the text and answers with the index,
# so the answer never depends on what a label says. gum draws MARKS columns
# before each row (its cursor, and in a multi-select a tick mark), and a
# description too long for what is left ends in an ellipsis so the cut shows.
styled_rows() {
  local marks=$1 && shift
  local options=("$@") index label description width room
  width=$(label_column_width "$@")
  room=$(($(styled_width) - marks - width - 1))
  for index in "${!options[@]}"; do
    label=${options[index]%%$'\t'*}
    description=${options[index]#*$'\t'}
    if [ "$label" = "$description" ] || [ "$room" -le 0 ]; then
      printf '%s\t%d\n' "$label" "$((index + 1))"
      continue
    fi
    [ "${#description}" -le "$room" ] || description="${description:0:room-1}…"
    printf '%-*s %s%s%s\t%d\n' "$width" "$label" \
      "$STYLE_DIM" "$description" "$STYLE_UNDIM" "$((index + 1))"
  done
}

is_option_index() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le "$2" ]
}

choose_styled() {
  local title=$1 && shift
  local count=$# rows=() row answer status=0
  while IFS= read -r row; do
    rows+=("$row")
  done < <(styled_rows 2 "$@")
  answer=$(gum choose --header="$title" --label-delimiter=$'\t' --no-show-help \
    --header.foreground="$STYLE_ACCENT" --cursor.foreground="$STYLE_ACCENT" \
    -- "${rows[@]}" </dev/tty 2>/dev/tty) || status=$?
  gum_answered "$status" choose || return 1
  is_option_index "$answer" "$count" || fail "gum choose answered with an unknown option: $answer"
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

# The ticked set is kept in option order whatever order gum or the toggles
# produced it in.
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

# gum ticks rows by their text and splits --selected on commas unless one is
# escaped as "\,". Its parser has no escape for a backslash, so a row holding
# a literal backslash-comma cannot be ticked, and is refused rather than shown
# unticked.
choose_many_styled() {
  local title=$1 done=$2 && shift 2
  local count=$# rows=() selected=() answers=() row index answer status=0 escaped_comma='\,'
  while IFS= read -r row; do
    rows+=("$row")
  done < <(styled_rows 4 "$@")
  for index in "${CHOSEN_INDEXES[@]+"${CHOSEN_INDEXES[@]}"}"; do
    is_option_index "$index" "$count" || continue
    row=${rows[index - 1]%$'\t'*}
    case "$row" in *'\,'*) fail "cannot pre-tick an option containing a backslash-comma: ${row%%"$STYLE_DIM"*}" ;; esac
    selected+=("--selected=${row//,/"$escaped_comma"}")
  done
  answer=$(gum choose --no-limit --label-delimiter=$'\t' --no-show-help \
    --header="$title"$'\n'"${STYLE_DIM}x toggles, enter to $done, esc to cancel$STYLE_UNDIM" \
    --header.foreground="$STYLE_ACCENT" --cursor.foreground="$STYLE_ACCENT" \
    --selected.foreground="$STYLE_ACCENT" \
    "${selected[@]+"${selected[@]}"}" -- "${rows[@]}" </dev/tty 2>/dev/tty) || status=$?
  gum_answered "$status" choose || return 1
  while IFS= read -r index; do
    [ -n "$index" ] || continue
    is_option_index "$index" "$count" || fail "gum choose answered with an unknown option: $index"
    answers+=("$index")
  done <<<"$answer"
  set_chosen_indexes "$count" "${answers[@]+"${answers[@]}"}"
}

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
# shellcheck disable=SC2034 # read by actions.sh and bro
readonly BACKED_OUT=117

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
