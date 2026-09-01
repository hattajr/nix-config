#!/usr/bin/env bash
# Focused safety checks for bro without a real Nix activation or network.
set -euo pipefail
repo_root=${BRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
bro="$repo_root/scripts/bro"
unset NIX_CONFIG_USERNAME NIX_CONFIG_HOME
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
checkout="$work/checkout"; mockbin="$work/bin"; log="$work/log"
mkdir -p "$checkout" "$mockbin"; : >"$log"
mkdir -p "$checkout/scripts" "$checkout/migration"
cp "$repo_root/scripts/migrate-chezmoi.py" "$checkout/scripts/migrate-chezmoi.py"
cp "$repo_root/migration/chezmoi-af63b22.inventory.json" "$checkout/migration/chezmoi-af63b22.inventory.json"
chmod +x "$checkout/scripts/migrate-chezmoi.py"
ln -s /bin/bash "$mockbin/bash"
git init -q "$checkout"
git -C "$checkout" remote add origin https://github.com/hattajr/nix-config.git
printf '{}\n' >"$checkout/flake.nix"
real_git=$(command -v git)
cat >"$mockbin/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\\n' "\$*" >>"$log"
if [ "\${BRO_GIT_MODE:-}" = sync ]; then
  case "\${3:-}" in
    status|fetch|push) exit 0 ;;
    rev-parse) printf '%s\\n' origin/main; exit 0 ;;
    rev-list)
      case "\${5:-}" in *..HEAD) printf '%s\\n' 1 ;; *) printf '%s\\n' 0 ;; esac
      exit 0
      ;;
  esac
fi
exec "$real_git" "\$@"
EOF
cat >"$mockbin/nix" <<'EOF'
#!/usr/bin/env bash
printf 'nix %s
' "$*" >>"$BRO_LOG"
[ "${1:-}" != --impure ] || shift
case "$1" in
  flake|eval) exit 0 ;;
  build) mkdir -p "$BRO_ACTIVATION"; cat >"$BRO_ACTIVATION/activate" <<'ACTIVATE'
#!/bin/sh
printf 'activation\n' >>"$BRO_LOG"
ACTIVATE
    chmod +x "$BRO_ACTIVATION/activate"; printf '%s\n' "$BRO_ACTIVATION" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$mockbin/git" "$mockbin/nix"
export BRO_LOG="$log" BRO_ACTIVATION="$work/activation" BRO_REPOSITORY="$checkout" CHEZMOI_SOURCE="$work/no-chezmoi"
apply_home="$work/apply-home"
mkdir -p "$apply_home/.nix-profile/bin" "$apply_home/.config/tmux"
printf '%s\n' '# test configuration' >"$apply_home/.config/tmux/tmux.conf"
cat >"$apply_home/.nix-profile/bin/tmux" <<'EOF'
#!/bin/sh
printf 'tmux %s\n' "$*" >>"$BRO_LOG"
EOF
chmod +x "$apply_home/.nix-profile/bin/tmux"
env -u NIX_CONFIG_USERNAME -u NIX_CONFIG_HOME \
  HOME="$apply_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" apply >/dev/null
grep -q '^activation$' "$log"
grep -Fq 'nix eval --impure --raw' "$log" || {
  echo 'bro test: apply did not evaluate the active user identity impurely' >&2
  exit 1
}
grep -Fq 'nix build --impure --no-link' "$log" || {
  echo 'bro test: apply did not build with the active user identity' >&2
  exit 1
}
grep -Eq '^tmux source-file .*/\.config/tmux/tmux\.conf$' "$log" || {
  echo 'bro test: apply did not reload an active managed tmux server' >&2
  exit 1
}
grep -q 'reloaded active tmux configuration' <(env -u NIX_CONFIG_USERNAME -u NIX_CONFIG_HOME \
  HOME="$apply_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" apply) || {
  echo 'bro test: apply did not report tmux configuration reload' >&2
  exit 1
}
! grep -Eq '^git .* (fetch|push)($| )' "$log" || { echo 'bro test: apply used Git network operation' >&2; exit 1; }
: >"$log"
printf dirty >"$checkout/dirty"
if PATH="$mockbin:$PATH" "$bro" sync >/dev/null 2>&1; then echo 'bro test: dirty sync succeeded' >&2; exit 1; fi
! grep -q '^git .* fetch' "$log" || { echo 'bro test: dirty sync fetched' >&2; exit 1; }
if PATH="$mockbin:$PATH" "$bro" health >/dev/null 2>&1; then
  echo 'bro test: health accepted missing managed tmux/configuration' >&2
  exit 1
fi
rm "$checkout/dirty"
: >"$log"
BRO_GIT_MODE=sync PATH="$mockbin:$PATH" "$bro" sync >/dev/null
! grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: ordinary sync pushed' >&2; exit 1; }
grep -q 'use bro sync --push' <(BRO_GIT_MODE=sync PATH="$mockbin:$PATH" "$bro" sync) || {
  echo 'bro test: ahead sync did not explain explicit push' >&2
  exit 1
}
: >"$log"
BRO_GIT_MODE=sync PATH="$mockbin:$PATH" "$bro" sync --push >/dev/null
grep -Eq '^git .* push($| )' "$log" || { echo 'bro test: sync --push did not push' >&2; exit 1; }

auth_home="$work/auth-home"
mkdir -p "$auth_home/.local/bin"
cat >"$auth_home/.local/bin/nix-config-setup" <<'EOF'
#!/bin/sh
printf 'setup %s\n' "$*" >>"$BRO_LOG"
EOF
cat >"$auth_home/.local/bin/proton-pass-session" <<'EOF'
#!/bin/sh
printf 'proton %s\n' "$*" >>"$BRO_LOG"
EOF
chmod +x "$auth_home/.local/bin/nix-config-setup" "$auth_home/.local/bin/proton-pass-session"
: >"$log"
HOME="$auth_home" PATH="$mockbin:$PATH" "$bro" auth
grep -Fq "proton $auth_home/.local/bin/nix-config-setup" "$log" || {
  echo 'bro test: Linux auth did not use Proton Pass session' >&2
  exit 1
}
rm "$auth_home/.local/bin/proton-pass-session"
: >"$log"
HOME="$auth_home" PATH="$mockbin:$PATH" "$bro" auth
grep -q '^setup ' "$log" || { echo 'bro test: auth fallback did not run setup' >&2; exit 1; }
migration_home="$work/migration-home"
mkdir -p "$migration_home"
: >"$log"
HOME="$migration_home" PATH="$mockbin:$PATH" "$bro" migration status | grep -Fq 'no ChezMoi migration transaction' || {
  echo 'bro test: migration status did not reach the migration tool' >&2; exit 1
}
if HOME="$migration_home" PATH="$mockbin:$PATH" "$bro" migration resume >/dev/null 2>&1; then
  echo 'bro test: migration resume accepted an unapproved transaction' >&2; exit 1
fi
HOME="$migration_home" PATH="$mockbin:$PATH" "$bro" migration legacy >/dev/null

# A completed migration is terminal: successful bro apply records it once, and
# later applies/plan/execute leave it complete without a false warning.
reference_source="$work/chezmoi-reference"
completed_home="$work/completed-home"
completed_state="$work/completed-state"
completed_digest=fixture-complete
mkdir -p "$reference_source" "$completed_home/.nix-profile/bin" "$completed_home/.config/tmux" \
  "$completed_state/nix-config/migrations/chezmoi-v1/transactions/$completed_digest"
printf '%s\n' '# fixture takeover guard' >"$reference_source/.chezmoiignore"
guard_digest=$(sha256sum "$reference_source/.chezmoiignore" | awk '{ print $1 }')
printf '%s\n' "$completed_digest" >"$completed_state/nix-config/migrations/chezmoi-v1/current"
printf '{"state":"activation-pending","digest":"%s","guardDigest":"%s"}\n' "$completed_digest" "$guard_digest" \
  >"$completed_state/nix-config/migrations/chezmoi-v1/transactions/$completed_digest/result.json"
printf '%s\n' previous-ignore >"$completed_state/nix-config/migrations/chezmoi-v1/transactions/$completed_digest/chezmoiignore.before"
printf '%s\n' '# test configuration' >"$completed_home/.config/tmux/tmux.conf"
cp "$apply_home/.nix-profile/bin/tmux" "$completed_home/.nix-profile/bin/tmux"
CHEZMOI_SOURCE="$reference_source" XDG_STATE_HOME="$completed_state" HOME="$completed_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" apply >/dev/null
CHEZMOI_SOURCE="$reference_source" XDG_STATE_HOME="$completed_state" HOME="$completed_home" PATH="$mockbin:$PATH" "$checkout/scripts/migrate-chezmoi.py" --source "$reference_source" status | grep -Fq '"state": "complete"' || {
  echo 'bro test: successful apply did not record complete migration state' >&2; exit 1
}
completed_rerun=$(CHEZMOI_SOURCE="$reference_source" XDG_STATE_HOME="$completed_state" HOME="$completed_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" apply 2>&1)
! grep -Eq 'nix-migration: ERROR|bro: WARN: Home Manager activated but migration completion' <<<"$completed_rerun" || {
  echo 'bro test: completed migration rerun emitted false completion warning' >&2; exit 1
}
completed_health=$(CHEZMOI_SOURCE="$reference_source" XDG_STATE_HOME="$completed_state" HOME="$completed_home" USER=apply-user PATH="$mockbin:$PATH" "$bro" health 2>&1 || true)
grep -Fq 'OK: ChezMoi migration completed' <<<"$completed_health" || {
  echo 'bro test: health rejected completed migration state' >&2; exit 1
}

unresolved_source="$work/chezmoi-source"
mkdir "$unresolved_source"
health_output=$(CHEZMOI_SOURCE="$unresolved_source" HOME="$migration_home" PATH="$mockbin:$PATH" "$bro" health 2>&1 || true)
grep -Fq 'CORE FAIL: ChezMoi migration is unresolved' <<<"$health_output" || {
  echo 'bro test: health did not report unresolved ChezMoi migration' >&2; exit 1
}

echo 'bro test: PASSED (apply safety, sync push boundary, auth wrapper, migration commands, dirty refusal, health)'
