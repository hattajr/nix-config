#!/usr/bin/env bash
# Start a persistent VM with this working tree mounted for manual installer testing.
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image=${MULTIPASS_INTERACTIVE_IMAGE:-24.04}
instance=${MULTIPASS_INTERACTIVE_INSTANCE:-"nix-config-interactive-${USER:-user}"}
instance=${instance//[^[:alnum:].-]/-}
source_target=/home/ubuntu/source

command -v multipass >/dev/null 2>&1 || {
  printf '%s\n' 'test-interactive: Multipass is required' >&2
  exit 77
}

if ! multipass info "$instance" >/dev/null 2>&1; then
  printf 'test-interactive: launching Ubuntu %s VM %s\n' "$image" "$instance"
  multipass launch "$image" --name "$instance" --cpus 4 --disk 40G --memory 8G
fi

# Multipass requires this guest-side helper before it can create SSHFS mounts.
# Install it proactively so callers never need to perform a manual setup step.
if ! multipass exec "$instance" -- snap list multipass-sshfs >/dev/null 2>&1; then
  multipass exec "$instance" -- sudo snap install multipass-sshfs
fi

# Refresh the mount so uncommitted host changes are immediately available.
multipass umount "$instance:$source_target" >/dev/null 2>&1 || true
multipass mount "$repo_root" "$instance:$source_target"

multipass exec "$instance" -- sudo bash -s <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git jq sudo tar xz-utils
EOF

# The installer validates and clones a Git remote, which would otherwise omit
# uncommitted host changes. Materialize the mounted working tree into a local,
# commit-backed fixture. Later runs add a descendant snapshot so an installed
# checkout can fast-forward normally.
multipass exec "$instance" -- sudo -u ubuntu -H bash -s <<'EOF'
set -euo pipefail
source=/home/ubuntu/source
fixture=/home/ubuntu/nix-config-fixture

if [ ! -d "$fixture/.git" ]; then
  mkdir -p "$fixture"
  git -C "$fixture" init -q -b main
  git -C "$fixture" config user.name "Multipass interactive fixture"
  git -C "$fixture" config user.email "fixture@example.invalid"
fi

find "$fixture" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
(
  cd "$source"
  git ls-files --cached --others --exclude-standard -z |
    tar --null --files-from=- --create --file=- |
    tar --extract --file=- --directory="$fixture"
)
git -C "$fixture" add --all
git -C "$fixture" diff --cached --quiet ||
  git -C "$fixture" commit -qm "interactive snapshot"
EOF

cat <<EOF

test-interactive: current working tree staged in $instance at /home/ubuntu/nix-config-fixture.

Inside the VM, run this interactive local-source installation:

  cd /home/ubuntu/nix-config-fixture
  NIX_CONFIG_REPOSITORY_URL=file:///home/ubuntu/nix-config-fixture \\
    ./scripts/install.sh /home/ubuntu/installed-nix-config

After host edits, run \`make test-interactive\` again to refresh the local fixture,
then rerun the installer command above. The VM is persistent; delete it when finished with:

  multipass delete --purge $instance

EOF

exec multipass shell "$instance"
