# What the styled menu draws around itself: a status card above it and a pause
# after each action.
#
# The card reads local state only: the checkout's Git metadata and the saved
# Health run. It never runs Nix, a fetch, or a check, so it is instant and
# works offline, and it is drawn every time the menu is.

# The card's own glyphs, each one column wide, and a one-byte stand-in for
# each. Text is measured and cut with the stand-ins in place, because in a C
# locale bash counts a glyph's bytes and could cut one in half.
readonly CARD_GLYPHS=(✓ ✗ · … →)
readonly CARD_GLYPH_BYTES=($'\021' $'\022' $'\023' $'\024' $'\025')
readonly CARD_ELLIPSIS_BYTE=$'\024'

# Sets CARD_TEXT to TEXT with its glyphs swapped for their stand-ins, or with
# "back", the stand-ins swapped for their glyphs.
CARD_TEXT=''
card_glyph_swap() {
  local text=$1 direction=${2:-} index from to
  for index in "${!CARD_GLYPHS[@]}"; do
    from=${CARD_GLYPHS[index]} to=${CARD_GLYPH_BYTES[index]}
    [ "$direction" != back ] || { from=$to to=${CARD_GLYPHS[index]}; }
    text=${text//"$from"/"$to"}
  done
  CARD_TEXT=$text
}

# Sets CARD_COLUMNS to how many columns TEXT, holding no colour, takes.
CARD_COLUMNS=0
card_columns() {
  card_glyph_swap "$1"
  CARD_COLUMNS=${#CARD_TEXT}
}

# Sets CARD_TEXT to TEXT, holding no colour, cut to COLUMNS and ending in an
# ellipsis when anything was cut.
card_fit() {
  local columns=$2 text
  card_glyph_swap "$1"
  text=$CARD_TEXT
  if [ "${#text}" -gt "$columns" ]; then
    text=''
    [ "$columns" -lt 1 ] || text="${CARD_TEXT:0:columns-1}$CARD_ELLIPSIS_BYTE"
  fi
  card_glyph_swap "$text" back
}

# Prints one row of the card, ROOM columns inside its borders. PREFIX and TAIL
# may hold colour and stay whole while the plain HEAD gives way to fit; a row
# too narrow even for them is cut as a whole, its colours dropped.
card_row() {
  local room=$1 prefix=$2 head=$3 tail=$4 fixed text
  plain_text "$prefix$tail"
  card_columns "$PLAIN_TEXT"
  fixed=$CARD_COLUMNS
  card_columns "$head"
  if [ $((fixed + CARD_COLUMNS)) -le "$room" ]; then
    text=$prefix$head$tail
  elif [ $((room - fixed)) -ge 2 ]; then
    card_fit "$head" $((room - fixed))
    text=$prefix$CARD_TEXT$tail
  else
    plain_text "$prefix$head$tail"
    card_fit "$PLAIN_TEXT" "$room"
    text=$CARD_TEXT
  fi
  plain_text "$text"
  card_columns "$PLAIN_TEXT"
  printf '%s│%s %s%*s %s│%s\n' "$STYLE_DIM" "$STYLE_UNDIM" "$text" \
    "$((room - CARD_COLUMNS))" '' "$STYLE_DIM" "$STYLE_UNDIM"
}

# How long ago, in the largest whole unit: 45s, 12m, 3h, or 2d.
card_age() {
  local seconds=$1
  # A clock set back would otherwise put the time in the future.
  [ "$seconds" -ge 0 ] || seconds=0
  if [ "$seconds" -lt 60 ]; then
    printf '%ds\n' "$seconds"
  elif [ "$seconds" -lt 3600 ]; then
    printf '%dm\n' "$((seconds / 60))"
  elif [ "$seconds" -lt 86400 ]; then
    printf '%dh\n' "$((seconds / 3600))"
  else
    printf '%dd\n' "$((seconds / 86400))"
  fi
}

# A file's modification time in epoch seconds. GNU stat takes -c and BSD stat
# takes -f, and GNU stat given -f reports the file system instead, so only a
# number that a successful call printed is believed.
file_mtime() {
  local mtime
  mtime=$(stat -c %Y "$1" 2>/dev/null) || mtime=$(stat -f %m "$1" 2>/dev/null) || return 1
  case "$mtime" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$mtime"
}

# The card only reads, so it takes none of the optional locks git status would
# otherwise hold over a Git command the user runs at the same time.
card_git() {
  local repo=$1 && shift
  git --no-optional-locks -C "$repo" "$@" 2>/dev/null
}

# The branch, or the short commit when detached; whether the tree is clean;
# where it stands against its upstream; and when it last fetched, which only
# a fetch writes, so the card never fetches to find out.
card_git_row() {
  local room=$1 repo=$2 now=$3 ref changes count counts ahead behind state tracking fetched mtime
  # run_git would borrow Git from Nix, which the card never runs.
  command -v git >/dev/null 2>&1 || { card_row "$room" '' 'Git is not installed' ''; return 0; }
  ref=$(card_git "$repo" symbolic-ref --quiet --short HEAD) \
    || ref=$(card_git "$repo" rev-parse --short HEAD) || ref='unknown commit'

  if ! changes=$(card_git "$repo" status --porcelain); then
    state=' changes unknown'
  elif [ -z "$changes" ]; then
    state=" $(styled_mark ok) clean"
  else
    count=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
    state=" $count changes"
    [ "$count" != 1 ] || state=' 1 change'
  fi

  # Git prints "ahead<TAB>behind", and fails when there is no upstream.
  counts=$(card_git "$repo" rev-list --left-right --count 'HEAD...@{upstream}') || counts=''
  case "$counts" in *$'\t'*) ;; *) counts='' ;; esac
  ahead=${counts%%$'\t'*} behind=${counts#*$'\t'}
  case "$ahead:$behind" in
    *[!0-9:]* | :* | *:) tracking='no upstream' ;;
    0:0) tracking='up to date' ;;
    *:0) tracking="$ahead ahead" ;;
    0:*) tracking="$behind behind" ;;
    *) tracking="$ahead ahead, $behind behind" ;;
  esac

  if [ ! -e "$repo/.git/FETCH_HEAD" ]; then
    fetched='never fetched'
  elif mtime=$(file_mtime "$repo/.git/FETCH_HEAD"); then
    fetched="fetched $(card_age "$((now - mtime))") ago"
  else
    fetched='fetch time unknown'
  fi
  card_row "$room" '' "$ref" "$state · $tracking $STYLE_DIM($fetched)$STYLE_UNDIM"
}

# The saved Health run as the card sums it up: SAVED_HEALTH is missing,
# unreadable, fail, warn, or ok; SAVED_HEALTH_TEXT is the first failure, else
# the first warning; SAVED_HEALTH_MORE counts the warnings after that one; and
# SAVED_HEALTH_CHECKED is when it ran.
SAVED_HEALTH=missing
SAVED_HEALTH_TEXT=''
SAVED_HEALTH_MORE=0
SAVED_HEALTH_CHECKED=0
read_saved_health() {
  SAVED_HEALTH=missing SAVED_HEALTH_TEXT='' SAVED_HEALTH_MORE=0 SAVED_HEALTH_CHECKED=0
  [ -e "$HEALTH_STATE_FILE" ] || return 0
  # Any line out of shape makes the whole file unreadable rather than half
  # believed. Reading a directory fails like reading a broken file.
  parse_saved_health 2>/dev/null <"$HEALTH_STATE_FILE" || SAVED_HEALTH=unreadable
}

# Reads the format save_health_results writes, from stdin: a "checked<TAB>epoch
# seconds" line, then any number of "level<TAB>area<TAB>message" lines.
parse_saved_health() {
  local line level area message first_fail='' first_warn='' warnings=0
  IFS= read -r line || return 1
  case "$line" in checked$'\t'[0-9]*) ;; *) return 1 ;; esac
  SAVED_HEALTH_CHECKED=${line#checked$'\t'}
  case "$SAVED_HEALTH_CHECKED" in *[!0-9]*) return 1 ;; esac
  # Arithmetic would read a leading zero as octal, so the time is read in base 10.
  SAVED_HEALTH_CHECKED=$((10#$SAVED_HEALTH_CHECKED))

  while IFS= read -r line || [ -n "$line" ]; do
    # A run with no results at all is saved as one empty line.
    [ -n "$line" ] || continue
    case "$line" in *$'\t'*$'\t'*) ;; *) return 1 ;; esac
    level=${line%%$'\t'*} line=${line#*$'\t'}
    area=${line%%$'\t'*} message=${line#*$'\t'}
    [ -n "$area" ] && [ -n "$message" ] || return 1
    case "$level" in
      ok | optional) ;;
      fail) [ -n "$first_fail" ] || first_fail=$area$'\t'$message ;;
      warn)
        warnings=$((warnings + 1))
        [ -n "$first_warn" ] || first_warn=$area$'\t'$message
        ;;
      *) return 1 ;;
    esac
  done

  if [ -n "$first_fail" ]; then
    SAVED_HEALTH=fail
    saved_health_text "$first_fail"
  elif [ -n "$first_warn" ]; then
    SAVED_HEALTH=warn SAVED_HEALTH_MORE=$((warnings - 1))
    saved_health_text "$first_warn"
  else
    SAVED_HEALTH=ok SAVED_HEALTH_TEXT='all checks passed'
  fi
}

# A result as the card shows it: its area's heading, then its message as the
# Health screen shows it, a fix pointing at its menu item.
saved_health_text() {
  local area=${1%%$'\t'*} message=${1#*$'\t'} heading
  heading=$(health_area_heading "$area")
  SAVED_HEALTH_TEXT="${heading:+$heading: }$(health_styled_message "$message")"
}

card_health_row() {
  local room=$1 now=$2 label="${STYLE_DIM}health$STYLE_UNDIM " more=''
  read_saved_health
  case "$SAVED_HEALTH" in
    missing) card_row "$room" "$label" 'not checked yet' '' ;;
    unreadable) card_row "$room" "$label" 'unreadable' '' ;;
    *)
      [ "$SAVED_HEALTH_MORE" = 0 ] || more=" (+$SAVED_HEALTH_MORE more)"
      card_row "$room" "$label$(styled_mark "$SAVED_HEALTH") " "$SAVED_HEALTH_TEXT" \
        "$more $STYLE_DIM· checked $(card_age "$((now - SAVED_HEALTH_CHECKED))") ago$STYLE_UNDIM"
      ;;
  esac
}

# The card for the checkout REPO on platform TARGET, as wide as styled rows.
status_card() {
  local repo=$1 target=$2 width room now title gap
  width=$(styled_width)
  room=$((width - 4))
  [ "$room" -ge 1 ] || room=1
  now=$(date +%s)
  title=$'\e[3'"$STYLE_ACCENT"$'mbro\e[39m'" $STYLE_DIM·$STYLE_UNDIM nix-config"
  # The platform sits at the right edge; on a narrow card it is cut instead.
  plain_text "$title"
  card_columns "$PLAIN_TEXT"
  gap=$((room - CARD_COLUMNS - ${#target}))
  [ "$gap" -ge 1 ] || gap=1

  box_rule "$((width - 2))"
  printf '%s╭%s╮%s\n' "$STYLE_DIM" "$BOX_RULE" "$STYLE_UNDIM"
  card_row "$room" "$title" '' "$(printf '%*s' "$gap" '')$STYLE_DIM$target$STYLE_UNDIM"
  card_git_row "$room" "$repo" "$now"
  card_health_row "$room" "$now"
  printf '%s╰%s╯%s\n' "$STYLE_DIM" "$BOX_RULE" "$STYLE_UNDIM"
}

# Each time the styled menu appears it starts a fresh screen, card on top.
show_status_card() {
  { printf '\e[H\e[2J'; status_card "$@"; } >/dev/tty
}

# The next menu clears the screen, so what an action printed stays up until
# the user has read it. A closed terminal ends the wait as a key would, and q
# quits instead, as it does at every prompt.
wait_for_key() {
  local key=''
  printf '\n %spress any key to return, q to quit%s' "$STYLE_DIM" "$STYLE_UNDIM" >/dev/tty
  IFS= read -rsn1 key </dev/tty || true
  printf '\n' >/dev/tty
  case "$key" in q | Q) quit_now ;; esac
}
