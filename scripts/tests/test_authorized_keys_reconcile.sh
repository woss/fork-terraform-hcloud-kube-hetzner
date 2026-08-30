#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
reconciler="$repo_root/scripts/reconcile-authorized-keys.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

managed="$tmp/managed"
authorized="$tmp/root/.ssh/authorized_keys"
sidecar="$tmp/root/.ssh/authorized_keys.kube-hetzner"

managed_one='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIManagedOne maintainer@example'
managed_two='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQManagedTwo maintainer@example'
removed_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRemovedOld old@example'
unrelated_key='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIUnrelated operator@example'

mkdir -p "$(dirname "$authorized")"
printf '%s\n%s\n' "$managed_one" "$managed_two" > "$managed"
printf '%s\n' "$removed_key" > "$sidecar"
cat > "$authorized" <<EOF
# Preserve this operator-managed key.
$unrelated_key
command="echo 'Please login as root rather than root.'",no-port-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIManagedOne stale-image
$managed_one
$removed_key
EOF

"$reconciler" "$managed" "$authorized" "$sidecar" false

grep -Fqx '# Preserve this operator-managed key.' "$authorized"
grep -Fqx "$unrelated_key" "$authorized"
grep -Fqx "$managed_one" "$authorized"
grep -Fqx "$managed_two" "$authorized"
[[ "$(grep -Fc 'AAAAC3NzaC1lZDI1NTE5AAAAIManagedOne' "$authorized")" == 1 ]]
if grep -Fq 'Please login as root' "$authorized"; then
  echo 'FAIL: stale forced-command key survived reconciliation' >&2
  exit 1
fi
if grep -Fq 'AAAAC3NzaC1lZDI1NTE5AAAAIRemovedOld' "$authorized"; then
  echo 'FAIL: removed module-managed key survived reconciliation' >&2
  exit 1
fi
cmp -s "$managed" "$sidecar"
[[ "$(stat -f '%Lp' "$authorized" 2>/dev/null || stat -c '%a' "$authorized")" == 600 ]]

"$reconciler" "$managed" "$authorized" "$sidecar" true
cmp -s "$managed" "$authorized"

cp "$managed" "$tmp/invalid-before"
printf '%s\n' 'not-a-public-key' > "$tmp/invalid"
if "$reconciler" "$tmp/invalid" "$authorized" "$sidecar" false; then
  echo 'FAIL: invalid managed key was accepted' >&2
  exit 1
fi
cmp -s "$tmp/invalid-before" "$authorized"

ln -s "$tmp/symlink-target" "$tmp/symlink-authorized"
if "$reconciler" "$managed" "$tmp/symlink-authorized" "$tmp/symlink-sidecar" false; then
  echo 'FAIL: authorized_keys symlink was accepted' >&2
  exit 1
fi

echo 'PASS: managed SSH identities replace stale options, preserve unrelated keys, and support exclusive mode.'
