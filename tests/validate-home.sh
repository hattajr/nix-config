#!/usr/bin/env bash
set -euo pipefail

source_root=/source
home_dir=/home/test
# path: includes newly added files during pre-commit validation; a plain Git
# flake intentionally hides untracked files.
flake_source="path:$source_root"
flake_ref="$flake_source#homeConfigurations.docker-test"

fail() {
  printf 'docker-validation: FAIL: %s\n' "$1" >&2
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

printf '%s\n' 'docker-validation: checking locked flake metadata and evaluation'
# `nix flake check` treats Home Manager's configuration object as a generic
# flake output and rejects its nested `type` attr. Show/eval validates the
# locked flake and synthetic configuration without masking that limitation.
nix flake metadata "$flake_source" >/tmp/flake-metadata.txt
nix flake show "$flake_source" --json >/tmp/flake-show.json
activation_drv=$(nix eval --raw "$flake_ref.activationPackage.drvPath")
darwin_arm_drv=$(nix eval --raw \
  "$flake_source#homeConfigurations.aarch64-darwin.activationPackage.drvPath")
linux_arm_drv=$(nix eval --raw \
  "$flake_source#homeConfigurations.aarch64-linux.activationPackage.drvPath")
linux_x86_drv=$(nix eval --raw \
  "$flake_source#homeConfigurations.x86_64-linux.activationPackage.drvPath")
printf '%s\n' "$activation_drv" >/tmp/activation.drv
printf '%s\n' "$darwin_arm_drv" >/tmp/aarch64-darwin-activation.drv
printf '%s\n' "$linux_arm_drv" >/tmp/aarch64-linux-activation.drv
printf '%s\n' "$linux_x86_drv" >/tmp/x86_64-linux-activation.drv

printf '%s\n' 'docker-validation: building activation package without checkout links'
activation_package=$(nix build --no-link --print-out-paths "$flake_ref.activationPackage")
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

printf '%s\n' 'docker-validation: first disposable activation'
activate first

printf '%s\n' 'docker-validation: second activation and idempotence check'
first_snapshot=$(find "$home_dir" -mindepth 1 -maxdepth 3 -printf '%P\n' | sort)
activate second
second_snapshot=$(find "$home_dir" -mindepth 1 -maxdepth 3 -printf '%P\n' | sort)
[ "$first_snapshot" = "$second_snapshot" ] || fail 'second activation changed the managed file layout'

profile_bin="$home_dir/.nix-profile/bin"
[ -d "$profile_bin" ] || fail 'Home Manager profile bin directory was not created'
export PATH="$home_dir/.local/bin:$profile_bin:$PATH"

printf '%s\n' 'docker-validation: checking managed tools and PATH'
for tool in git nvim rg tmux zsh fzf gh lazygit lazydocker uv node gcc ssh pi pass-cli lumen cloudflared keyctl; do
  command -v "$tool" >/dev/null 2>&1 || fail "managed tool is missing from PATH: $tool"
done

printf '%s\n' 'docker-validation: checking OpenSSH MagicDNS aliases'
ssh -G -F "$home_dir/.ssh/config" latte >/tmp/ssh-latte.conf
ssh -G -F "$home_dir/.ssh/config" legion >/tmp/ssh-legion.conf
for host in latte legion; do
  grep -Fx 'hostname '"$host" /tmp/ssh-"$host".conf >/dev/null || fail "SSH hostname is wrong for $host"
  grep -Fx 'user hattajr' /tmp/ssh-"$host".conf >/dev/null || fail "SSH user is wrong for $host"
  grep -Fx 'port 22' /tmp/ssh-"$host".conf >/dev/null || fail "SSH port is wrong for $host"
done

printf '%s\n' 'docker-validation: checking zsh startup and Git configuration'
zsh -lic '[[ -n "$EDITOR" ]] && [[ "$EDITOR" = nvim ]] && alias n >/dev/null'
pi --version >/dev/null || fail 'managed Pi executable did not run'
settings="$home_dir/.pi/agent/settings.json"
[ -f "$settings" ] || fail 'Pi settings were not created'
[ ! -L "$settings" ] || fail 'Pi settings remain a read-only Home Manager symlink'
jq -e '.lastChangelogVersion == "0.0.0"' "$settings" >/dev/null || fail 'Pi changelog marker is missing'
[ -f "$home_dir/.pi/agent/agents/planner.md" ] || fail 'Pi agents were not deployed'
[ -f "$home_dir/.pi/agent/extensions/plan-autoloop.ts" ] || fail 'Pi extensions were not deployed'
[ -x "$home_dir/.pi/agent/intercepted-commands/python" ] || fail 'Pi command wrappers were not deployed executable'
[ -x "$home_dir/.local/bin/nix-config-setup" ] || fail 'account setup helper was not deployed'
[ -x "$home_dir/.local/bin/proton-pass-session" ] || fail 'Proton Pass Linux session helper was not deployed'
[ -f "$home_dir/.config/proton-pass/pi.env.example" ] || fail 'Proton Pass reference example was not deployed'
[ ! -e "$home_dir/.config/proton-pass/pi.env" ] || fail 'Home Manager materialized the local Proton Pass reference file'
[ ! -e "$home_dir/.pi/agent/auth.json" ] || fail 'Home Manager created or replaced Pi auth state'
jq '.enabledModels = []' "$settings" >"$settings.tmp"
mv "$settings.tmp" "$settings"
pi-models-sync >/dev/null 2>&1 || fail 'Pi model sync wrapper failed'
[ "$(jq -c '.enabledModels' "$settings")" = "$(jq -c . "$home_dir/.pi/agent/scoped-models.json")" ] || fail 'Pi model sync did not restore scoped models'
git_editor=$(git config --get core.editor || true)
[ "$git_editor" = vim ] || fail "Git core.editor was not configured (value: $git_editor)"
git config --get-regexp '^alias\.' >/dev/null || fail 'Git aliases were not configured'

printf '%s\n' 'docker-validation: checking isolated tmux server'
tmux -L hm-validation -f "$home_dir/.config/tmux/tmux.conf" new-session -d -s validation
# A separate socket proves this test did not attach to a host or shared server.
tmux -L hm-validation has-session -t validation
tmux -L hm-validation kill-server

printf '%s\n' 'docker-validation: checking Neovim headless startup'
nvim --headless '+qa!'

printf '%s\n' 'docker-validation: running credential-free bootstrap and Proton Pass tests'
BOOTSTRAP_REPO_ROOT="$source_root" "$source_root/tests/bootstrap/test-bootstrap.sh"
BOOTSTRAP_REPO_ROOT="$source_root" "$source_root/tests/proton-pass/test-pi-wrapper.sh"
BOOTSTRAP_REPO_ROOT="$source_root" "$source_root/tests/proton-pass/test-session-wrapper.sh"
BOOTSTRAP_REPO_ROOT="$source_root" "$source_root/tests/proton-pass/test-setup.sh"

printf '%s\n' 'docker-validation: checking repeatable activation generation'
second_drv=$(nix eval --raw "$flake_ref.activationPackage.drvPath")
second_package=$(nix build --no-link --print-out-paths "$flake_ref.activationPackage")
[ "$activation_drv" = "$second_drv" ] || fail 'locked inputs produced a different activation derivation'
[ "$activation_package" = "$second_package" ] || fail 'locked inputs produced different activation paths'

printf '%s\n' 'docker-validation: PASSED (flake, activation, idempotence, tools, bootstrap, and Proton Pass boundaries)'
