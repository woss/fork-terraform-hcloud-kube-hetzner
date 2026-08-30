#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template="$repo_root/packer-template/hcloud-leapmicro-snapshots.pkr.hcl"
packer_bin="${PACKER_BIN:-packer}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v "$packer_bin" >/dev/null 2>&1 || fail "Packer is required"

cleanup_script="$(printf 'local.clean_up\n' | "$packer_bin" console \
  -var 'timezone=Europe/Madrid' "$template")"

for required_text in \
  'transactional-update --continue shell' \
  'rm -f /etc/ssh/ssh_host_*' \
  "find /etc/ssh -maxdepth 1 -name 'ssh_host_*'" \
  'rm -f /root/.ssh/authorized_keys /root/.ssh/authorized_keys.kube-hetzner' \
  'SSH authorized keys remain in the persistent root subvolume' \
  'install -m 0644 /dev/null /etc/NetworkManager/NetworkManager.conf' \
  "timezone='Europe/Madrid'" \
  "ln -snf \"\$zoneinfo\" /etc/localtime" \
  "printf '%s\\n' \"\$timezone\" > /etc/timezone"; do
  grep -Fq "$required_text" <<< "$cleanup_script" \
    || fail "rendered transactional cleanup is missing: $required_text"
done

if awk '
  /transactional-update --continue shell/ { inside = 1; next }
  inside && /^[[:space:]]*EOF$/ { inside = 0; next }
  !inside && /rm -(r)?f \/etc\/ssh\/ssh_host_/ { found = 1 }
  END { exit(found ? 0 : 1) }
' <<< "$cleanup_script"; then
  fail "SSH host-key deletion escaped the transactional shell"
fi

if ! awk '
  /transactional-update --continue shell/ { inside = 1; next }
  inside && /^[[:space:]]*EOF$/ { inside = 0; next }
  !inside && /rm -f \/root\/[.]ssh\/authorized_keys/ { found = 1 }
  END { exit(found ? 0 : 1) }
' <<< "$cleanup_script"; then
  fail "persistent /root authorized-key cleanup must run outside the transactional shell"
fi

if grep -Fq 'timedatectl set-timezone' <<< "$cleanup_script"; then
  fail "timezone still relies on a live-overlay systemd mutation"
fi

if grep -Eq '^[[:space:]]*(sleep[^&]*&&[[:space:]]*)?reboot([[:space:]]|$)' <<< "$cleanup_script"; then
  fail "final committed cleanup must not reboot and regenerate SSH host keys"
fi

unsafe_timezone='../../etc/passwd'
if [[ "$unsafe_timezone" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; then
  fail "unsafe timezone traversal input was accepted"
fi

echo "PASS: Leap Micro final image cleanup is transactionally committed without regenerating SSH host keys."
