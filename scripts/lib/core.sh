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

# gum ticks rows by their text and splits --selected on commas, so a ticked row
# with a comma would quietly start unticked; refuse it instead.
choose_many_styled() {
  local title=$1 done=$2 && shift 2
  local count=$# rows=() selected=() answers=() row index answer status=0
  while IFS= read -r row; do
    rows+=("$row")
  done < <(styled_rows 4 "$@")
  for index in "${CHOSEN_INDEXES[@]+"${CHOSEN_INDEXES[@]}"}"; do
    is_option_index "$index" "$count" || continue
    row=${rows[index - 1]%$'\t'*}
    case "$row" in *,*) fail "cannot pre-tick an option containing a comma: ${row%%"$STYLE_DIM"*}" ;; esac
    selected+=("--selected=$row")
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
