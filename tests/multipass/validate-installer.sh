#!/usr/bin/env bash
# Exercise the public stage-zero installer and lossless managed-leaf takeover.
set -euo pipefail

source_root=/home/ubuntu/source
destination=/home/ubuntu/installed-nix-config

cd "$source_root"
git init -q
git config user.name multipass-fixture
git config user.email multipass-fixture@example.invalid
git add .
git commit -qm fixture
revision=$(git rev-parse HEAD)

mkdir -p \
  "$HOME/.ssh" \
  "$HOME/.config/bottom" \
  "$HOME/.config/git" \
  "$HOME/.config/tmux" \
  "$HOME/.config/nvim/local"
printf legacy-input >"$HOME/.inputrc"
printf legacy-ssh >"$HOME/.ssh/config"
printf legacy-zprofile >"$HOME/.zprofile"
printf legacy-zshenv >"$HOME/.zshenv"
printf legacy-zshrc >"$HOME/.zshrc"
printf legacy-bottom >"$HOME/.config/bottom/bottom.toml"
printf legacy-ignore >"$HOME/.config/git/ignore"
printf legacy-tmux >"$HOME/.config/tmux/tmux.conf"
mkdir "$HOME/.config/tmux/keys.sh"
printf preserve-tmux >"$HOME/.config/tmux/keys.sh/keep.txt"
printf legacy-nvim >"$HOME/.config/nvim/init.lua"
printf preserve-nvim >"$HOME/.config/nvim/local/keep.txt"
printf legacy-git >"$HOME/.gitconfig"

curl -fsSL "file://$source_root/scripts/install.sh" |
  env NIX_CONFIG_REPOSITORY_URL="file://$source_root" \
    NIX_CONFIG_REVISION="$revision" \
    NIX_CONFIG_APPLY=yes \
    NIX_CONFIG_START_SHELL=no \
    sh -s -- "$destination"

assert_takeover() {
  local managed
  for managed in \
    "$HOME/.inputrc" \
    "$HOME/.ssh/config" \
    "$HOME/.zprofile" \
    "$HOME/.zshenv" \
    "$HOME/.zshrc" \
    "$HOME/.config/bottom/bottom.toml" \
    "$HOME/.config/git/ignore" \
    "$HOME/.config/tmux/tmux.conf" \
    "$HOME/.config/tmux/keys.sh" \
    "$HOME/.config/nvim/init.lua" \
    "$HOME/.config/git/config"; do
    test -L "$managed"
  done

  test ! -e "$HOME/.gitconfig"
  grep -Fx preserve-nvim "$HOME/.config/nvim/local/keep.txt"
  backup_root=$(find "$HOME/.local/state/home-manager/takeover" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  test -n "$backup_root"
  grep -Fx preserve-tmux "$backup_root/.config/tmux/keys.sh/keep.txt"
  grep -Fx legacy-git "$backup_root/.gitconfig"
}

assert_takeover

# Add runtime credentials after bootstrap health has completed, then prove a
# later activation preserves them while refreshing every forced managed leaf.
mkdir -p "$HOME/.pi/agent" "$HOME/.config/proton-pass"
printf '{"oauth":"preserve"}\n' >"$HOME/.pi/agent/auth.json"
printf 'PI_ENV_PRESERVE=yes\n' >"$HOME/.config/proton-pass/pi.env"
# shellcheck disable=SC1091
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
NIX_CONFIG_REPOSITORY_URL="file://$source_root" "$HOME/.local/bin/bro" apply
assert_takeover
jq -e '.oauth == "preserve"' "$HOME/.pi/agent/auth.json" >/dev/null
grep -Fx PI_ENV_PRESERVE=yes "$HOME/.config/proton-pass/pi.env"
