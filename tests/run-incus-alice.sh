#!/usr/bin/env bash
# Real installer regression: existing user-profile Nix is discovered while absent from PATH.
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image=${INCUS_ALICE_IMAGE:-images:ubuntu/24.04}
base=${INCUS_ALICE_BASE:-nix-config-alice-base}
snapshot=${INCUS_ALICE_SNAPSHOT:-single-user-nix-v1}
instance="nix-config-alice-${USER:-user}-$$"; instance=${instance//[^[:alnum:].-]/-}

command -v incus >/dev/null || { echo 'incus-alice-validation: Incus is required' >&2; exit 77; }
incus info >/dev/null || { echo 'incus-alice-validation: run incus admin init first' >&2; exit 77; }
cleanup() { incus delete --force "$instance" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

if ! incus info "$base/snapshots/$snapshot" >/dev/null 2>&1; then
  incus info "$base" >/dev/null 2>&1 || {
    echo "incus-alice-validation: creating $base from $image"
    incus launch "$image" "$base"
    incus config set "$base" security.nesting=true
    "$repo_root/tests/incus/prepare-single-user-alice.sh" "$base"
    incus stop "$base"
  }
  incus snapshot create "$base" "$snapshot"
fi

incus copy "$base/snapshots/$snapshot" "$instance"
incus start "$instance"
# Copy only tracked/non-ignored source files; this deliberately excludes .env.
incus exec "$instance" -- install -d -o alice -g alice /home/alice/source
(
  cd "$repo_root"
  git ls-files --cached --others --exclude-standard -z | \
    tar --null --files-from=- --create --file=-
) | incus exec "$instance" -- tar --extract --file=- --directory /home/alice/source
incus exec "$instance" -- chown -R alice:alice /home/alice/source
incus exec "$instance" -- su - alice -s /bin/bash -c '
  cd /home/alice/source
  git init -q
  git config user.name incus-fixture
  git config user.email incus-fixture@example.invalid
  git add . && git commit -qm fixture
'
incus exec "$instance" -- su - alice -s /bin/bash -c '
  set -euo pipefail
  export HOME=/home/alice USER=alice LOGNAME=alice
  # Simulate the reported shell: Nix exists only after install.sh sources nix.sh.
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  ! command -v nix
  NIX_CONFIG_REPOSITORY_URL=file:///home/alice/source NIX_CONFIG_APPLY=no \
    /home/alice/source/scripts/install.sh /home/alice/installed-nix-config
' | tee /tmp/incus-alice-validation.log
grep -Fq 'Using existing Nix installation' /tmp/incus-alice-validation.log
! grep -Eq 'downloading the official multi-user installer|--daemon' /tmp/incus-alice-validation.log
echo 'incus-alice-validation: PASSED (real alice single-user Nix reuse)'
