#!/usr/bin/env bash
set -euo pipefail

source_root=${SOURCE_ROOT:-/source}
home_dir=/home/test
validation_name=${VALIDATION_NAME:-multipass-validation}
# path: includes newly added files during pre-commit validation; a plain Git
# flake intentionally hides untracked files.
flake_source="path:$source_root"
flake_ref="$flake_source#homeConfigurations.multipass-test"

fail() {
  printf '%s: FAIL: %s\n' "$validation_name" "$1" >&2
  exit 1
}

export HOME="$home_dir"
export USER=test
export LOGNAME=test
export XDG_CONFIG_HOME="$home_dir/.config"
export XDG_DATA_HOME="$home_dir/.local/share"
export XDG_STATE_HOME="$home_dir/.local/state"
export XDG_CACHE_HOME="$home_dir/.cache"
export NIX_CONFIG="experimental-features = nix-command flakes"

rm -rf "$home_dir"
mkdir -p "$home_dir" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
  "$home_dir/.local/state/nix/profiles"
chmod 700 "$home_dir"
# The read-only checkout is usually owned by the host user, not container root.
# Mark only this disposable source mount safe for Git's ownership check.
nix shell nixpkgs#git --command git config --global --add safe.directory "$source_root"

printf '%s: checking locked flake metadata and evaluation\n' "$validation_name"
# `nix flake check` treats Home Manager's configuration object as a generic
# flake output and rejects its nested `type` attr. Show/eval validates the
# locked flake and synthetic configuration without masking that limitation.
nix flake metadata "$flake_source" >/tmp/flake-metadata.txt
nix flake show --impure "$flake_source" --json >/tmp/flake-show.json
activation_drv=$(nix eval --impure --raw "$flake_ref.activationPackage.drvPath")
darwin_arm_drv=$(nix eval --impure --raw \
  "$flake_source#homeConfigurations.aarch64-darwin.activationPackage.drvPath")
linux_arm_drv=$(nix eval --impure --raw \
  "$flake_source#homeConfigurations.aarch64-linux.activationPackage.drvPath")
linux_x86_drv=$(nix eval --impure --raw \
  "$flake_source#homeConfigurations.x86_64-linux.activationPackage.drvPath")
printf '%s\n' "$activation_drv" >/tmp/activation.drv
printf '%s\n' "$darwin_arm_drv" >/tmp/aarch64-darwin-activation.drv
printf '%s\n' "$linux_arm_drv" >/tmp/aarch64-linux-activation.drv
printf '%s\n' "$linux_x86_drv" >/tmp/x86_64-linux-activation.drv

printf '%s: building activation package without checkout links\n' "$validation_name"
activation_package=$(nix build --impure --no-link --print-out-paths "$flake_ref.activationPackage")
printf 'activation package: %s\n' "$activation_package"
if [ ! -f "$activation_package/activate" ]; then
  printf 'activation package contents:\n' >&2
  find "$activation_package" -maxdepth 2 -type f -print >&2 || true
  fail 'activation package has no activate script'
fi

activate() {
  "$activation_package/activate" >/tmp/home-activation.log 2>&1 || {
    cat /tmp/home-activation.log >&2
    fail "Home Manager activation failed ($1)"
  }
}

# A collision outside the takeover set must fail before any managed leaf is
# moved. Directory-shaped managed leaves must then be quarantined and replaced.
mkdir -p "$XDG_CONFIG_HOME/git" "$XDG_CONFIG_HOME/nvim/local" \
  "$XDG_CONFIG_HOME/tmux" "$home_dir/.pi/agent" "$XDG_CONFIG_HOME/proton-pass"
printf legacy-zsh >"$home_dir/.zshrc"
printf legacy-nvim >"$XDG_CONFIG_HOME/nvim/init.lua"
printf preserve-nvim >"$XDG_CONFIG_HOME/nvim/local/keep.txt"
printf collision >"$XDG_CONFIG_HOME/git/config"
printf legacy-git >"$home_dir/.gitconfig"
mkdir "$XDG_CONFIG_HOME/tmux/keys.sh"
printf preserve-tmux >"$XDG_CONFIG_HOME/tmux/keys.sh/keep.txt"
printf '{"oauth":"preserve"}\n' >"$home_dir/.pi/agent/auth.json"
printf 'PI_ENV_PRESERVE=yes\n' >"$XDG_CONFIG_HOME/proton-pass/pi.env"

set +e
"$activation_package/activate" >/tmp/home-collision.log 2>&1
collision_status=$?
set -e
[ "$collision_status" -ne 0 ] || fail 'non-forced Git collision unexpectedly activated'
[ -f "$home_dir/.zshrc" ] && [ ! -L "$home_dir/.zshrc" ] ||
  fail 'failed preflight modified a forced shell target'
[ -f "$XDG_CONFIG_HOME/nvim/init.lua" ] && [ ! -L "$XDG_CONFIG_HOME/nvim/init.lua" ] ||
  fail 'failed preflight modified a forced Neovim target'
[ -f "$home_dir/.gitconfig" ] || fail 'failed preflight removed legacy Git config'
rm "$XDG_CONFIG_HOME/git/config"

printf '%s: first disposable activation\n' "$validation_name"
activate first
[ -L "$home_dir/.zshrc" ] || fail 'legacy zsh config was not replaced'
[ -L "$XDG_CONFIG_HOME/nvim/init.lua" ] || fail 'legacy Neovim config was not replaced'
[ -L "$XDG_CONFIG_HOME/tmux/keys.sh" ] || fail 'directory-shaped tmux target was not replaced'
[ -L "$XDG_CONFIG_HOME/git/config" ] || fail 'managed XDG Git config was not linked'
[ ! -e "$home_dir/.gitconfig" ] || fail 'legacy Git config was not removed'
backup_root=$(find "$XDG_STATE_HOME/home-manager/takeover" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -n "$backup_root" ] || fail 'activation did not create a takeover quarantine'
grep -Fx legacy-zsh "$backup_root/.zshrc" >/dev/null ||
  fail 'legacy zsh config was not quarantined'
grep -Fx legacy-nvim "$backup_root/.config/nvim/init.lua" >/dev/null ||
  fail 'legacy Neovim config was not quarantined'
grep -Fx preserve-tmux "$backup_root/.config/tmux/keys.sh/keep.txt" >/dev/null ||
  fail 'directory-shaped tmux target contents were not quarantined'
grep -Fx legacy-git "$backup_root/.gitconfig" >/dev/null ||
  fail 'legacy Git config was not quarantined'
grep -Fx preserve-nvim "$XDG_CONFIG_HOME/nvim/local/keep.txt" >/dev/null ||
  fail 'unmanaged Neovim file was not preserved'
jq -e '.oauth == "preserve"' "$home_dir/.pi/agent/auth.json" >/dev/null ||
  fail 'Pi runtime authentication was not preserved'
grep -Fx PI_ENV_PRESERVE=yes "$XDG_CONFIG_HOME/proton-pass/pi.env" >/dev/null ||
  fail 'Proton Pass runtime environment was not preserved'

nvim_lockfile="$XDG_STATE_HOME/nvim/lazy/lazy-lock.json"
nvim_baseline="$XDG_STATE_HOME/nvim/lazy/managed-lazy-lock.json"
[ -f "$nvim_lockfile" ] || fail 'activation did not seed the writable Lazy lockfile'
[ -f "$nvim_baseline" ] || fail 'activation did not record the managed Lazy baseline'
# Simulate a harmless Lazy update. Activation must not discard a user-modified
# operational lockfile, even when the repository baseline is redeployed.
printf '\n' >>"$nvim_lockfile"
user_lock_hash=$(nix hash file "$nvim_lockfile")

printf '%s: second activation and idempotence check\n' "$validation_name"
first_snapshot=$(find "$home_dir" -mindepth 1 -maxdepth 4 -printf '%P\n' | sort)
activate second
second_snapshot=$(find "$home_dir" -mindepth 1 -maxdepth 4 -printf '%P\n' | sort)
[ "$first_snapshot" = "$second_snapshot" ] || fail 'second activation changed the managed file layout'
grep -Fx preserve-nvim "$XDG_CONFIG_HOME/nvim/local/keep.txt" >/dev/null ||
  fail 'second activation removed an unmanaged Neovim file'
jq -e '.oauth == "preserve"' "$home_dir/.pi/agent/auth.json" >/dev/null ||
  fail 'second activation removed Pi runtime authentication'
grep -Fx PI_ENV_PRESERVE=yes "$XDG_CONFIG_HOME/proton-pass/pi.env" >/dev/null ||
  fail 'second activation removed the Proton Pass runtime environment'
[ "$(nix hash file "$nvim_lockfile")" = "$user_lock_hash" ] ||
  fail 'second activation discarded a user-modified Lazy lockfile'

profile_bin="$home_dir/.nix-profile/bin"
[ -d "$profile_bin" ] || fail 'Home Manager profile bin directory was not created'
export PATH="$home_dir/.local/bin:$profile_bin:$PATH"

printf '%s: checking managed tools and PATH\n' "$validation_name"
for tool in age btm git nvim rg tmux zsh fzf gh lazygit lazydocker uv node gcc g++ make python3 pkg-config ssh pi pass-cli lumen cloudflared wrangler ty keyctl setpriv; do
  command -v "$tool" >/dev/null 2>&1 || fail "managed tool is missing from PATH: $tool"
done

printf '%s: checking OpenSSH MagicDNS aliases\n' "$validation_name"
ssh -G -F "$home_dir/.ssh/config" latte >/tmp/ssh-latte.conf
ssh -G -F "$home_dir/.ssh/config" legion >/tmp/ssh-legion.conf
for host in latte legion; do
  grep -Fx 'hostname '"$host" /tmp/ssh-"$host".conf >/dev/null || fail "SSH hostname is wrong for $host"
  grep -Fx 'user hattajr' /tmp/ssh-"$host".conf >/dev/null || fail "SSH user is wrong for $host"
  grep -Fx 'port 22' /tmp/ssh-"$host".conf >/dev/null || fail "SSH port is wrong for $host"
done

printf '%s: checking zsh startup and Git configuration\n' "$validation_name"
zsh -lic '[[ -n "$EDITOR" ]] && [[ "$EDITOR" = nvim ]] && alias n >/dev/null'
[ -f "$home_dir/.inputrc" ] || fail 'native Readline config was not deployed'
grep -Fx 'set enable-bracketed-paste on' "$home_dir/.inputrc" >/dev/null ||
  fail 'Readline bracketed paste was not enabled'
[ -f "$XDG_CONFIG_HOME/bottom/bottom.toml" ] || fail 'native bottom config was not deployed'
grep -F 'type = "proc"' "$XDG_CONFIG_HOME/bottom/bottom.toml" >/dev/null ||
  fail 'bottom process layout was not configured'
PI_SKIP_PROTON_PASS=1 pi --version >/dev/null || fail 'managed Pi executable did not run'
settings="$home_dir/.pi/agent/settings.json"
[ -f "$settings" ] || fail 'Pi settings were not created'
[ ! -L "$settings" ] || fail 'Pi settings remain a read-only Home Manager symlink'
jq -e '.lastChangelogVersion == "0.0.0"' "$settings" >/dev/null || fail 'Pi changelog marker is missing'
[ -f "$home_dir/.pi/agent/agents/planner.md" ] || fail 'Pi agents were not deployed'
[ -f "$home_dir/.pi/agent/extensions/plan-autoloop.ts" ] || fail 'Pi extensions were not deployed'
[ -f "$home_dir/.pi/agent/extensions/plans-at-autocomplete.ts" ] ||
  fail 'Pi PLANS autocomplete extension was not deployed'
[ -x "$home_dir/.pi/agent/intercepted-commands/python" ] || fail 'Pi command wrappers were not deployed executable'
[ -x "$home_dir/.local/bin/nix-config-setup" ] || fail 'account setup helper was not deployed'
[ -x "$home_dir/.local/bin/bro" ] || fail 'everyday management command was not deployed'
[ -x "$home_dir/.local/bin/devtunnel" ] || fail 'custom dev tunnel command was not deployed'
[ -x "$home_dir/.local/bin/pi-models-sync" ] || fail 'Pi model sync command was not deployed'
[ -x "$home_dir/.local/bin/proton-pass-session" ] || fail 'Proton Pass Linux session helper was not deployed'
[ -f "$home_dir/.config/proton-pass/pi.env.example" ] || fail 'Proton Pass reference example was not deployed'
jq '.enabledModels = []' "$settings" >"$settings.tmp"
mv "$settings.tmp" "$settings"
pi-models-sync >/dev/null 2>&1 || fail 'Pi model sync wrapper failed'
[ "$(jq -c '.enabledModels' "$settings")" = "$(jq -c . "$home_dir/.pi/agent/scoped-models.json")" ] || fail 'Pi model sync did not restore scoped models'
git_editor=$(git config --get core.editor || true)
[ "$git_editor" = vim ] || fail "Git core.editor was not configured (value: $git_editor)"
git config --get-regexp '^alias\.' >/dev/null || fail 'Git aliases were not configured'
[ -L "$XDG_CONFIG_HOME/git/config" ] || fail 'Git declarative config is not a managed symlink'
# Home Manager intentionally emits a literal tilde for Git to expand.
# shellcheck disable=SC2088
git config --get-all include.path | grep -Fx '~/.config/git/identity' >/dev/null ||
  fail 'Git writable identity include was not configured'

printf '%s: checking isolated tmux server\n' "$validation_name"
tmux -L hm-validation -f "$home_dir/.config/tmux/tmux.conf" new-session -d -s validation
# A separate socket proves this test did not attach to a host or shared server.
tmux -L hm-validation has-session -t validation
status_right=$(tmux -L hm-validation show-options -gv status-right)
case "$status_right" in
*'keys.sh not found!'*) fail 'tmux shortcut status widget was not installed with Dracula' ;;
esac
tmux -L hm-validation kill-server

printf '%s: checking Neovim headless startup\n' "$validation_name"
[ "$(jq -c . "$XDG_CONFIG_HOME/nvim/lazy-lock.json")" = "$(jq -c . "$nvim_lockfile")" ] ||
  fail 'seeded Lazy lockfile does not match the managed lockfile'
# Run as an ordinary user so store-backed config writes and permission errors
# cannot be hidden by root's elevated access.
chown 30033:1000 "$home_dir"
chown -R 30033:1000 "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
set +e
nvim_output=$(setpriv --reuid=30033 --regid=1000 --clear-groups \
  env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
  XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
  XDG_CACHE_HOME="$XDG_CACHE_HOME" PATH="$PATH" \
  NIX_CONFIG_TEST_NO_PLUGIN_INSTALL=1 nvim --headless '+qa!' 2>&1)
nvim_status=$?
set -e
[ "$nvim_status" -eq 0 ] || {
  printf '%s\n' "$nvim_output" >&2
  fail 'Neovim headless startup failed'
}
if grep -Eiq 'E5113|Permission denied' <<<"$nvim_output"; then
  printf '%s\n' "$nvim_output" >&2
  fail 'Neovim attempted to write read-only managed configuration'
fi
[ -f "$nvim_lockfile" ] || fail 'Neovim removed its writable Lazy lockfile'
[ ! -L "$nvim_lockfile" ] || fail 'Neovim Lazy lockfile is still a read-only symlink'
setpriv --reuid=30033 --regid=1000 --clear-groups test -w "$nvim_lockfile" ||
  fail 'Neovim Lazy lockfile is not writable by the user'

printf '%s: running credential-free bootstrap and Proton Pass tests\n' "$validation_name"
BOOTSTRAP_REPO_ROOT="$source_root" "$source_root/tests/bootstrap/test-bootstrap.sh"
BRO_TEST_REPO_ROOT="$source_root" "$source_root/tests/bro/test-bro.sh"
BOOTSTRAP_REPO_ROOT="$source_root" "$source_root/tests/proton-pass/test-pi-wrapper.sh"
BOOTSTRAP_REPO_ROOT="$source_root" "$source_root/tests/proton-pass/test-session-wrapper.sh"
BOOTSTRAP_REPO_ROOT="$source_root" "$source_root/tests/proton-pass/test-setup.sh"

printf '%s: checking repeatable activation generation\n' "$validation_name"
second_drv=$(nix eval --impure --raw "$flake_ref.activationPackage.drvPath")
second_package=$(nix build --impure --no-link --print-out-paths "$flake_ref.activationPackage")
[ "$activation_drv" = "$second_drv" ] || fail 'locked inputs produced a different activation derivation'
[ "$activation_package" = "$second_package" ] || fail 'locked inputs produced different activation paths'

printf '%s: PASSED (flake, activation, idempotence, tools, bootstrap, and Proton Pass boundaries)\n' "$validation_name"
