#!/usr/bin/env bash
set -euo pipefail

export HOME=/home/test USER=test LOGNAME=test
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
export LANG=C.UTF-8 LC_ALL=C.UTF-8

locale_archive=$(find /nix/store -path '*/glibc-locales*/lib/locale/locale-archive' -print -quit)
if [ -n "$locale_archive" ]; then
  export LOCALE_ARCHIVE="$locale_archive"
fi

mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
  "$HOME/.local/state/nix/profiles" "$HOME/.local"
chmod 700 "$HOME"
git config --global --add safe.directory /source

activation_package=$(nix build --no-link --print-out-paths \
  /source#homeConfigurations.docker-test.activationPackage)
"$activation_package/activate"
export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH"

# Home Manager links the checked-in Neovim tree read-only. Make a disposable
# writable copy so LazyVim can update lazy-lock.json and plugin state.
if [ -L "$XDG_CONFIG_HOME/nvim" ]; then
  cp -rL "$XDG_CONFIG_HOME/nvim" "$XDG_CONFIG_HOME/nvim.mutable"
  rm "$XDG_CONFIG_HOME/nvim"
  mv "$XDG_CONFIG_HOME/nvim.mutable" "$XDG_CONFIG_HOME/nvim"
  chmod -R u+rwX "$XDG_CONFIG_HOME/nvim"
fi

if ! npm install --global --prefix "$HOME/.local" \
  '@earendil-works/pi-coding-agent@0.84.2' >/tmp/pi-install.log 2>&1; then
  cat /tmp/pi-install.log >&2
  exit 1
fi

command -v nvim >/dev/null || { printf '%s\n' 'test-interactive: nvim is missing' >&2; exit 1; }
command -v pi >/dev/null || { printf '%s\n' 'test-interactive: pi is missing' >&2; exit 1; }
command -v iconv >/dev/null || { printf '%s\n' 'test-interactive: iconv is missing' >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'test-interactive: setup unexpectedly lost root' >&2; exit 1; }

chown -R 30033:1000 "$HOME"
printf '%s\n' 'test-interactive: Home Manager and Pi environment are ready'
printf 'test-interactive: final shell runs as uid 30033 with HOME=%s\n' "$HOME"
printf '%s\n' 'test-interactive: try nvim, pi, tmux, git, lazygit, or lazydocker'

if [ "${INTERACTIVE_SMOKE:-0}" = 1 ]; then
  exec setpriv --reuid=30033 --regid=1000 --clear-groups \
    zsh -lic '
      test "$(id -u)" = 30033
      test "$HOME" = /home/test
      test "$LANG" = C.UTF-8
      test "$LC_ALL" = C.UTF-8
      command -v nvim >/dev/null
      command -v pi >/dev/null
      command -v iconv >/dev/null
      nvim --headless +"qa!"
      pi --version >/dev/null
      printf "%s\\n" "test-interactive: smoke passed (uid, HOME, UTF-8, iconv, nvim, pi)"
    '
fi

exec setpriv --reuid=30033 --regid=1000 --clear-groups zsh -l
