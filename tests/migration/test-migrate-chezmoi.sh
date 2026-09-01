#!/usr/bin/env bash
# Hermetic ChezMoi takeover test. It never reads the operator's source or .env.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/scripts/migrate-chezmoi.py"
chezmoi_bin=${CHEZMOI_BIN:-$(command -v chezmoi || true)}
[ -x "$script" ] || { echo 'migration test: migration script is not executable' >&2; exit 1; }
[ -n "$chezmoi_bin" ] || { echo 'migration test: chezmoi is required (set CHEZMOI_BIN)' >&2; exit 1; }
"$repo_root/scripts/validate-migration-ownership.py" | grep -Fq 'canonical paths mapped' || {
  echo 'migration test: ownership manifest is incomplete' >&2; exit 1
}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
home="$workdir/home"; source="$workdir/source"; state="$workdir/state"; inventory="$workdir/inventory.json"
mkdir -p "$home" "$source/dot_config/nvim"
printf 'old git config\n' >"$source/dot_gitconfig"
printf 'old nvim config\n' >"$source/dot_config/nvim/init.lua"
printf 'old unmanaged\n' >"$source/dot_unmanaged"
git -C "$source" init -q
git -C "$source" config user.name fixture
git -C "$source" config user.email fixture@example.invalid
git -C "$source" add . && git -C "$source" commit -qm fixture
commit=$(git -C "$source" rev-parse HEAD)
printf '{"schema":1,"sourceCommit":"%s","items":[{"path":".gitconfig","owner":"home-manager","treatment":"take-over"},{"path":".config/nvim/init.lua","owner":"home-manager","treatment":"take-over"}]}' "$commit" >"$inventory"

# Real ChezMoi establishes the legacy state in an isolated plaintext fixture.
HOME="$home" "$chezmoi_bin" --source "$source" --destination "$home" apply
[ "$(<"$home/.gitconfig")" = 'old git config' ] || { echo 'migration test: fixture apply failed' >&2; exit 1; }

plan=$(XDG_STATE_HOME="$state" "$script" --inventory "$inventory" --home "$home" --source "$source" plan)
digest=$(awk '/plan digest/ { print $NF }' <<<"$plan")
[ -n "$digest" ] || { echo 'migration test: plan returned no digest' >&2; exit 1; }
XDG_STATE_HOME="$state" "$script" --inventory "$inventory" --home "$home" --source "$source" execute --digest "$digest" >/dev/null
[ ! -e "$home/.gitconfig" ] && [ ! -e "$home/.config/nvim/init.lua" ] || { echo 'migration test: takeover did not clear collisions' >&2; exit 1; }

# Stand in for Home Manager output, then prove a later real ChezMoi apply
# cannot restore takeover paths while an unrelated legacy path still updates.
printf 'home-manager git\n' >"$home/.gitconfig"
printf 'home-manager nvim\n' >"$home/.config/nvim/init.lua"
printf 'updated unmanaged\n' >"$source/dot_unmanaged"
HOME="$home" "$chezmoi_bin" --source "$source" --destination "$home" apply
[ "$(<"$home/.gitconfig")" = 'home-manager git' ] || { echo 'migration test: ChezMoi overwrote .gitconfig' >&2; exit 1; }
[ "$(<"$home/.config/nvim/init.lua")" = 'home-manager nvim' ] || { echo 'migration test: ChezMoi overwrote Neovim config' >&2; exit 1; }
[ "$(<"$home/.unmanaged")" = 'updated unmanaged' ] || { echo 'migration test: guard blocked unmanaged file' >&2; exit 1; }
grep -Fq '# BEGIN nix-config Home Manager takeover' "$source/.chezmoiignore" || { echo 'migration test: takeover guard missing' >&2; exit 1; }

# A modified guard fails closed before a later activation can be trusted.
printf '# tampered\n' >>"$source/.chezmoiignore"
if XDG_STATE_HOME="$state" "$script" --inventory "$inventory" --home "$home" --source "$source" status >/dev/null 2>&1; then
  echo 'migration test: altered guard unexpectedly passed status' >&2; exit 1
fi
printf '%s\n' 'migration test: PASSED (hermetic real ChezMoi overlap guard)'
