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

# path: includes newly added files during pre-commit validation; a plain Git
# flake intentionally hides untracked files.
activation_package=$(nix build --no-link --print-out-paths \
  path:/source#homeConfigurations.incus-test.activationPackage)
"$activation_package/activate"
export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH"
PYTHON=$(command -v python3)
export PYTHON

command -v nvim >/dev/null || { printf '%s\n' 'test-interactive: nvim is missing' >&2; exit 1; }
command -v pi >/dev/null || { printf '%s\n' 'test-interactive: pi is missing' >&2; exit 1; }
command -v iconv >/dev/null || { printf '%s\n' 'test-interactive: iconv is missing' >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'test-interactive: setup unexpectedly lost root' >&2; exit 1; }

chown -R 30033:1000 "$HOME"

# Run the same application checks before opening the shell. Pi lazily installs
# configured extensions on first use, so this catches native-module failures
# during setup instead of surprising the user at the prompt.
# The single-quoted script intentionally expands inside the target zsh.
# shellcheck disable=SC2016
setpriv --reuid=30033 --regid=1000 --clear-groups \
  zsh -lc '
    test "$(id -u)" = 30033
    test "$HOME" = /home/test
    test "$LANG" = C.UTF-8
    test "$LC_ALL" = C.UTF-8
    for command_name in nvim pi tmux git lazygit lazydocker iconv python3 sed; do
      command -v "$command_name" >/dev/null || {
        printf "test-interactive: missing command: %s\\n" "$command_name" >&2
        exit 1
      }
    done
    test -x "$PYTHON"
    # Validate the Neovim executable without triggering asynchronous
    # Lazy/Mason provisioning in a startup-and-exit smoke command.
    nvim --clean --headless +"qa!"
    pi --version >/dev/null
    lazygit --version >/dev/null
    lazydocker --version >/dev/null
    tmux -V >/dev/null
    git --version >/dev/null
  '

printf '%s\n' 'test-interactive: application smoke passed (nvim, pi, tmux, git, lazygit, lazydocker)'
printf '%s\n' 'test-interactive: Home Manager and Pi environment are ready'
printf 'test-interactive: final shell runs as uid 30033 with HOME=%s\n' "$HOME"
printf '%s\n' 'test-interactive: try nvim, pi, tmux, git, lazygit, or lazydocker'

if [ "${INTERACTIVE_SMOKE:-0}" = 1 ]; then
  printf '%s\n' 'test-interactive: smoke passed (uid, HOME, UTF-8, iconv, nvim, pi, tmux, git, lazygit, lazydocker)'
  exit 0
fi

# The preflight shell above is intentionally noninteractive so it cannot
# steal Incus's foreground process group. The final login shell inherits the
# Incus TTY and becomes interactive normally.
exec setpriv --reuid=30033 --regid=1000 --clear-groups zsh -l
