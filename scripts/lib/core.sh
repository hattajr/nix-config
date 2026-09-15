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

# Answer defaults to the capitalised letter so a bare Return is always safe.
confirm() {
  local question=$1 default=${2:-no} answer
  require_tty 'this step'
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

# Prints the 1-based index of the chosen label. Callers pass labels as
# "key<TAB>description" so the menu can align its own columns.
CHOICE_INDEX=0
choose() {
  local title=$1 && shift
  local options=("$@") count=${#options[@]} index answer label description
  require_tty 'the menu'
  while true; do
    printf '\n%s\n\n' "$title" >/dev/tty
    for index in "${!options[@]}"; do
      label=${options[index]%%$'\t'*}
      description=${options[index]#*$'\t'}
      if [ "$label" = "$description" ]; then
        printf '  %d) %s\n' "$((index + 1))" "$label" >/dev/tty
      else
        printf '  %d) %-12s %s\n' "$((index + 1))" "$label" "$description" >/dev/tty
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
