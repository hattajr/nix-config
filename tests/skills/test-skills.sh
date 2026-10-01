#!/usr/bin/env bash
# Evaluate real Home Manager mappings with newly created skills, and exercise
# the real takeover hook in a disposable home without activating the host.
set -euo pipefail

repo_root=${SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture="$work/repo"
mkdir -p "$fixture"
cp "$repo_root/flake.nix" "$repo_root/flake.lock" "$fixture/"
for directory in bin config home lib scripts; do
  cp -R "$repo_root/$directory" "$fixture/"
done

# Directory placement must be enough: no module edits for any new skill.
mkdir -p "$fixture/config/agents/skills/new-shared/references" \
  "$fixture/config/pi/agent/skills/new-pi" \
  "$fixture/config/claude/skills/new-claude"
for collection in agents/skills/new-shared pi/agent/skills/new-pi claude/skills/new-claude; do
  name=${collection##*/}
  printf '%s\n' '---' "name: $name" 'description: Skill deployment fixture.' '---' \
    >"$fixture/config/$collection/SKILL.md"
done
printf 'reference content\n' >"$fixture/config/agents/skills/new-shared/references/guide.md"

case "$(uname -s):$(uname -m)" in
Darwin:arm64 | Darwin:aarch64) native=aarch64-darwin ;;
Linux:arm64 | Linux:aarch64) native=aarch64-linux ;;
Linux:x86_64 | Linux:amd64) native=x86_64-linux ;;
*) printf 'skills: unsupported platform\n' >&2; exit 1 ;;
esac
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}experimental-features = nix-command flakes"
configuration="path:$fixture#homeConfigurations.\"$native\".config"
nix eval --json "$configuration.home.file" --apply \
  'files: builtins.mapAttrs (_: file: { inherit (file) force; source = toString file.source; }) files' \
  >"$work/files.json"

fail() { printf 'skills: FAIL: %s\n' "$1" >&2; exit 1; }
shared_source() {
  local relative=$1 pi_source claude_source
  pi_source=$(jq -er --arg key ".pi/agent/skills/$relative" '.[$key] | select(.force) | .source' "$work/files.json")
  claude_source=$(jq -er --arg key ".claude/skills/$relative" '.[$key] | select(.force) | .source' "$work/files.json")
  [ "$pi_source" = "$claude_source" ] || fail "agents use different sources for $relative"
  cmp "$fixture/config/agents/skills/$relative" "$pi_source" || fail "incorrect content for $relative"
}
# Check every existing shared leaf, plus the new skill and its reference.
while IFS= read -r source; do
  shared_source "${source#"$fixture/config/agents/skills/"}"
done < <(find "$fixture/config/agents/skills" -type f)
jq -e '
  has(".pi/agent/skills/new-pi/SKILL.md") and
  (has(".claude/skills/new-pi/SKILL.md") | not) and
  has(".claude/skills/new-claude/SKILL.md") and
  (has(".pi/agent/skills/new-claude/SKILL.md") | not) and
  (has(".claude/skills/design-md-import/SKILL.md") | not) and
  (has(".claude/skills/grill-me/SKILL.md") | not) and
  (has(".claude/skills/web-browser/SKILL.md") | not) and
  (has(".claude/skills") | not) and (has(".pi/agent/skills") | not)
' "$work/files.json" >/dev/null || fail 'skill isolation or leaf-only ownership failed'

nix eval --raw "$configuration.home.activation.overwriteManagedLeaves.data" >"$work/takeover.sh"
home="$work/home"
mkdir -p "$home/.claude/skills/new-shared/SKILL.md" \
  "$home/.claude/skills/synced" "$home/.claude/skills/local-only" \
  "$home/.claude/skills/new-claude" "$home/.pi/agent/skills/new-shared"
printf 'legacy directory\n' >"$home/.claude/skills/new-shared/SKILL.md/keep.txt"
printf 'legacy Claude skill\n' >"$home/.claude/skills/new-claude/SKILL.md"
printf 'legacy Pi skill\n' >"$home/.pi/agent/skills/new-shared/SKILL.md"
printf 'preserve sync\n' >"$home/.claude/skills/synced/keep.txt"
printf 'preserve local\n' >"$home/.claude/skills/local-only/SKILL.md"
printf 'preserve auth\n' >"$home/.pi/agent/auth.json"
printf 'preserve extra\n' >"$home/.claude/skills/new-shared/local.txt"

HOME="$home" XDG_STATE_HOME="$home/.local/state" bash "$work/takeover.sh"
backup=$(find "$home/.local/state/home-manager/takeover" -mindepth 1 -maxdepth 1 -type d)
[ -n "$backup" ] || fail 'collisions were not quarantined'
grep -Fx 'legacy directory' "$backup/.claude/skills/new-shared/SKILL.md/keep.txt" >/dev/null
grep -Fx 'legacy Claude skill' "$backup/.claude/skills/new-claude/SKILL.md" >/dev/null
grep -Fx 'legacy Pi skill' "$backup/.pi/agent/skills/new-shared/SKILL.md" >/dev/null
[ ! -e "$home/.claude/skills/new-shared/SKILL.md" ] || fail 'collision still occupies the managed leaf'

# Simulate the store-backed link created after takeover. A repeat hook removes
# managed symlinks without making another backup; unrelated files remain intact.
source=$(jq -r '.[".claude/skills/new-shared/SKILL.md"].source' "$work/files.json")
ln -s "$source" "$home/.claude/skills/new-shared/SKILL.md"
HOME="$home" XDG_STATE_HOME="$home/.local/state" bash "$work/takeover.sh"
[ "$(find "$home/.local/state/home-manager/takeover" -mindepth 1 -maxdepth 1 -type d)" = "$backup" ] ||
  fail 'repeat takeover created another backup'
grep -Fx 'preserve sync' "$home/.claude/skills/synced/keep.txt" >/dev/null
grep -Fx 'preserve local' "$home/.claude/skills/local-only/SKILL.md" >/dev/null
grep -Fx 'preserve auth' "$home/.pi/agent/auth.json" >/dev/null
grep -Fx 'preserve extra' "$home/.claude/skills/new-shared/local.txt" >/dev/null
printf 'skills: PASSED (new skills, shared references, isolation, collision backups, runtime preservation)\n'
