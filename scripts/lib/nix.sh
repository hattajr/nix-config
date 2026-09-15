# Nix, Git, and Home Manager identity helpers.

readonly TRUSTED_ORIGIN_HTTPS='https://github.com/hattajr/nix-config.git'
readonly TRUSTED_ORIGIN_SSH='git@github.com:hattajr/nix-config.git'
readonly CHECKOUT_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/bro/checkout"

enable_nix_features() {
  export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}experimental-features = nix-command flakes"
}

run_git() {
  if command -v git >/dev/null 2>&1; then
    git "$@"
  else
    command -v nix >/dev/null 2>&1 || fail 'Git is missing and Nix is unavailable'
    nix shell --accept-flake-config nixpkgs#git --command git "$@"
  fi
}

# Transient DNS failures are common on laptops resuming from sleep, so a
# resolution error is retried while any other failure is reported immediately.
run_nix_with_dns_retry() {
  local attempt=1 max_attempts=5 delay=1 status
  local stdout_file stderr_file
  stdout_file=$(mktemp "${TMPDIR:-/tmp}/nix-config-stdout.XXXXXX") || fail 'could not create a Nix output file'
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/nix-config-stderr.XXXXXX") || {
    rm -f "$stdout_file"
    fail 'could not create a Nix error file'
  }

  while true; do
    : >"$stdout_file"
    : >"$stderr_file"
    if "$@" >"$stdout_file" 2>"$stderr_file"; then
      cat "$stderr_file" >&2
      cat "$stdout_file"
      rm -f "$stdout_file" "$stderr_file"
      return 0
    else
      # The failing command's status is only readable inside this branch: an if
      # whose condition fails and which has no else clause evaluates to 0.
      status=$?
    fi
    cat "$stderr_file" >&2
    [ ! -s "$stdout_file" ] || cat "$stdout_file" >&2

    if ! grep -Eiq \
      'could not resolve (host(name)?|proxy)|temporary failure in name resolution|name or service not known' \
      "$stderr_file" "$stdout_file"; then
      rm -f "$stdout_file" "$stderr_file"
      return "$status"
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      warn "DNS resolution failed after $max_attempts attempts"
      rm -f "$stdout_file" "$stderr_file"
      return "$status"
    fi
    warn "DNS resolution failed; retrying in ${delay}s (attempt $((attempt + 1))/$max_attempts)"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# The identity reaches Nix as a quoted string literal, so a value able to close
# that literal would change the expression rather than the configuration.
reject_nix_metacharacters() {
  case "$1" in
    *'"'* | *'\'* | *'${'*)
      fail "$2 must not contain quotes, backslashes, or Nix interpolation" ;;
  esac
}

# Identity belongs to the account running this, never to the repository, and is
# never configurable: it is read from the account itself.
IDENTITY_USERNAME=''
IDENTITY_HOME=''
resolve_identity() {
  IDENTITY_USERNAME=${USER:-$(id -un 2>/dev/null || true)}
  IDENTITY_HOME=${HOME:-}
  [ -n "$IDENTITY_USERNAME" ] || fail 'could not determine the current account name'
  [ -n "$IDENTITY_HOME" ] || fail 'could not determine the current home directory'
  [ "${IDENTITY_HOME#/}" != "$IDENTITY_HOME" ] \
    || fail "home directory must be absolute: $IDENTITY_HOME"
  reject_nix_metacharacters "$IDENTITY_USERNAME$IDENTITY_HOME" 'identity'
}

# Passing the identity as an explicit builder argument keeps every committed
# flake output pure while still activating accounts this repository never names.
home_expr() {
  local repo=$1 platform=$2 attribute=$3
  printf '((builtins.getFlake "path:%s").lib.mkHome { system = "%s"; username = "%s"; homeDirectory = "%s"; }).%s' \
    "$repo" "$platform" "$IDENTITY_USERNAME" "$IDENTITY_HOME" "$attribute"
}

detect_platform() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64 | Darwin:aarch64) printf 'aarch64-darwin\n' ;;
    Linux:arm64 | Linux:aarch64) printf 'aarch64-linux\n' ;;
    Linux:x86_64 | Linux:amd64) printf 'x86_64-linux\n' ;;
    *) fail "unsupported platform: $(uname -s)/$(uname -m)" ;;
  esac
}

origin_is_trusted() {
  case "$1" in
    "$TRUSTED_ORIGIN_HTTPS" | "$TRUSTED_ORIGIN_SSH") return 0 ;;
    *) return 1 ;;
  esac
}

# The recorded checkout is written once at install time. It is state, not
# configuration, so there is no way to point bro elsewhere by typing.
resolve_checkout() {
  local candidate origin
  if [ -r "$CHECKOUT_STATE_FILE" ]; then
    candidate=$(cat "$CHECKOUT_STATE_FILE")
  else
    candidate=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
  fi
  [ -d "$candidate/.git" ] || fail "not a Git checkout: $candidate"
  candidate=$(CDPATH='' cd -- "$candidate" && pwd -P)
  origin=$(run_git -C "$candidate" remote get-url origin 2>/dev/null || true)
  origin_is_trusted "$origin" || fail "checkout origin is not $TRUSTED_ORIGIN_HTTPS"
  reject_nix_metacharacters "$candidate" 'checkout path'
  printf '%s\n' "$candidate"
}

write_checkout_state() {
  local repo=$1 state_dir tmp
  state_dir=$(dirname "$CHECKOUT_STATE_FILE")
  mkdir -p "$state_dir" || fail 'could not create the checkout state directory'
  chmod 700 "$state_dir" || fail 'could not secure the checkout state directory'
  tmp=$(mktemp "$state_dir/.checkout.XXXXXX") || fail 'could not create the checkout state file'
  printf '%s\n' "$(CDPATH='' cd -- "$repo" && pwd -P)" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CHECKOUT_STATE_FILE"
}
