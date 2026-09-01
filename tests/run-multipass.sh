#!/usr/bin/env bash
# Full end-to-end validation in a disposable Ubuntu VM.
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image=${MULTIPASS_VALIDATION_IMAGE:-24.04}
instance="nix-config-validation-${USER:-user}-$$"
instance=${instance//[^[:alnum:].-]/-}

command -v multipass >/dev/null 2>&1 || {
  printf '%s\n' 'multipass-validation: Multipass is required' >&2
  exit 77
}

archive=$(mktemp "$HOME/nix-config-source.XXXXXX.tar")
chmod 0600 "$archive"

cleanup() {
  rm -f "$archive"
  multipass delete --purge "$instance" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Send only project files; no local credentials, ignored files, or host mounts
# enter the VM.
(
  cd "$repo_root"
  while IFS= read -r -d '' path; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    printf '%s\0' "$path"
  done < <(git ls-files --cached --others --exclude-standard -z) |
    tar --null --files-from=- --create --file="$archive"
)

printf 'multipass-validation: launching Ubuntu %s VM\n' "$image"
multipass launch "$image" --name "$instance" --cpus 4 --disk 40G --memory 8G
multipass transfer "$archive" "$instance:/tmp/nix-config-source.tar"

multipass exec "$instance" -- sudo bash -euxc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl git jq sudo tar xz-utils
  install -d -o ubuntu -g ubuntu /home/ubuntu/source
  tar --extract --file=/tmp/nix-config-source.tar --directory=/home/ubuntu/source
  chown -R ubuntu:ubuntu /home/ubuntu/source
'

printf '%s\n' 'multipass-validation: running curl installer and takeover checks'
multipass exec "$instance" -- sudo -u ubuntu -H \
  /home/ubuntu/source/tests/multipass/validate-installer.sh

printf '%s\n' 'multipass-validation: running activation and installer regression suite'
multipass exec "$instance" -- sudo bash -c '
  set -euo pipefail
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  export SOURCE_ROOT=/home/ubuntu/source
  export VALIDATION_NAME=multipass-validation
  exec /home/ubuntu/source/tests/validate-home.sh
'

printf '%s\n' 'multipass-validation: PASSED (Ubuntu VM, curl installer, and Home Manager activation)'
