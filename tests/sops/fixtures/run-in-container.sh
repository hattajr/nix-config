#!/bin/sh
set -eu
umask 077

fail() {
    printf 'test-sops: FAIL: %s\n' "$1" >&2
    exit 1
}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

authorized_key="$workdir/authorized.txt"
unauthorized_key="$workdir/unauthorized.txt"
plaintext="$workdir/fake.yaml"
encrypted="$workdir/fake.yaml.sops"
decrypted="$workdir/decrypted.yaml"

age-keygen -o "$authorized_key" >/dev/null 2>&1
age-keygen -o "$unauthorized_key" >/dev/null 2>&1
authorized_recipient=$(awk '/^# public key: / { print $4; exit }' "$authorized_key")
[ -n "$authorized_recipient" ] || fail 'authorized age recipient was not generated'

# Generate the marker only inside the disposable container. Never print it.
secret_marker="fake-sops-$(od -An -N16 -t x1 /dev/urandom | tr -d ' \n')"
printf 'test:\n  token: %s\n' "$secret_marker" >"$plaintext"

sops encrypt \
    --input-type yaml \
    --output-type yaml \
    --age "$authorized_recipient" \
    "$plaintext" >"$encrypted"

grep -F -- "$secret_marker" "$encrypted" >/dev/null 2>&1 \
    && fail 'plaintext marker appears in encrypted output'

SOPS_AGE_KEY_FILE="$authorized_key" sops decrypt --input-type yaml --output-type yaml "$encrypted" >"$decrypted"
grep -F -- "$secret_marker" "$decrypted" >/dev/null 2>&1 \
    || fail 'authorized identity did not recover the fake plaintext'

mode=$(stat -c '%a' "$decrypted")
[ "$mode" = 600 ] || fail "decrypted file permissions are $mode, expected 600"

if SOPS_AGE_KEY_FILE="$unauthorized_key" sops decrypt --input-type yaml --output-type yaml "$encrypted" >"$workdir/unauthorized.out" 2>/dev/null; then
    fail 'unauthorized identity decrypted the secret'
fi
[ ! -s "$workdir/unauthorized.out" ] \
    || fail 'unauthorized decryption produced plaintext output'

# The generated marker must not be present in tracked repository content or in
# the Nix store. This catches accidental evaluation/store embedding.
if git -C /source grep -F -- "$secret_marker" -- . >/dev/null 2>&1; then
    fail 'fake plaintext marker appears in Git-facing source content'
fi
if grep -R -F -- "$secret_marker" /nix/store >/dev/null 2>&1; then
    fail 'fake plaintext marker appears in /nix/store'
fi

printf '%s\n' 'test-sops: PASSED (authorized decrypt, unauthorized rejection, permissions, and leak checks)'
