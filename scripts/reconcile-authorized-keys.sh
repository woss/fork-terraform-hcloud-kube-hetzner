#!/bin/sh

set -eu

managed_keys="${1:?managed key file is required}"
authorized_keys="${2:-/root/.ssh/authorized_keys}"
sidecar="${3:-/root/.ssh/authorized_keys.kube-hetzner}"
exclusive="${4:-false}"

case "$exclusive" in
  true | false) ;;
  *)
    echo "exclusive must be true or false" >&2
    exit 2
    ;;
esac

[ -f "$managed_keys" ] || {
  echo "managed key file does not exist: $managed_keys" >&2
  exit 1
}
[ ! -L "$authorized_keys" ] || {
  echo "refusing to replace symbolic link: $authorized_keys" >&2
  exit 1
}
[ ! -L "$sidecar" ] || {
  echo "refusing to replace symbolic link: $sidecar" >&2
  exit 1
}

authorized_dir="$(dirname "$authorized_keys")"
sidecar_dir="$(dirname "$sidecar")"
install -d -m 0700 "$authorized_dir"
install -d -m 0700 "$sidecar_dir"

workdir="$(mktemp -d)"
authorized_tmp="${authorized_keys}.tmp.$$"
sidecar_tmp="${sidecar}.tmp.$$"
cleanup() {
  rm -rf "$workdir"
  rm -f "$authorized_tmp" "$sidecar_tmp"
}
trap cleanup EXIT HUP INT TERM

canonical_managed="$workdir/managed"
revoked_identities="$workdir/revoked"
preserved_keys="$workdir/preserved"
reconciled_keys="$workdir/reconciled"

# OpenSSH permits options before the key type. Compare the key type and base64
# body so stale command= restrictions cannot survive on a managed identity.
awk '
function key_id(line, count, field_index, fields) {
  count = split(line, fields, /[[:space:]]+/)
  for (field_index = 1; field_index < count; field_index++) {
    if (fields[field_index] ~ /^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh[.]com)$/ &&
        fields[field_index + 1] ~ /^[A-Za-z0-9+\/=]+$/) {
      return fields[field_index] " " fields[field_index + 1]
    }
  }
  return ""
}
/^[[:space:]]*($|#)/ { next }
{
  identity = key_id($0)
  if (identity == "") {
    print "invalid managed OpenSSH public key: " $0 > "/dev/stderr"
    exit 1
  }
  if (!seen[identity]++) {
    print
  }
}
' "$managed_keys" > "$canonical_managed"

[ -s "$canonical_managed" ] || {
  echo "managed key file contains no valid public keys" >&2
  exit 1
}

cat "$canonical_managed" > "$revoked_identities"
if [ -f "$sidecar" ]; then
  cat "$sidecar" >> "$revoked_identities"
fi

if [ "$exclusive" = "true" ]; then
  cp "$canonical_managed" "$reconciled_keys"
else
  if [ -f "$authorized_keys" ]; then
    awk '
    function key_id(line, count, field_index, fields) {
      count = split(line, fields, /[[:space:]]+/)
      for (field_index = 1; field_index < count; field_index++) {
        if (fields[field_index] ~ /^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh[.]com)$/ &&
            fields[field_index + 1] ~ /^[A-Za-z0-9+\/=]+$/) {
          return fields[field_index] " " fields[field_index + 1]
        }
      }
      return ""
    }
    NR == FNR {
      identity = key_id($0)
      if (identity != "") {
        revoked[identity] = 1
      }
      next
    }
    {
      identity = key_id($0)
      if (identity == "" || !(identity in revoked)) {
        print
      }
    }
    ' "$revoked_identities" "$authorized_keys" > "$preserved_keys"
  else
    : > "$preserved_keys"
  fi

  awk '
  function key_id(line, count, field_index, fields) {
    count = split(line, fields, /[[:space:]]+/)
    for (field_index = 1; field_index < count; field_index++) {
      if (fields[field_index] ~ /^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh[.]com)$/ &&
          fields[field_index + 1] ~ /^[A-Za-z0-9+\/=]+$/) {
        return fields[field_index] " " fields[field_index + 1]
      }
    }
    return ""
  }
  /^[[:space:]]*$/ { next }
  {
    identity = key_id($0)
    if (identity != "") {
      if (!seen_identity[identity]++) {
        print
      }
    } else if (!seen_line[$0]++) {
      print
    }
  }
  ' "$preserved_keys" "$canonical_managed" > "$reconciled_keys"
fi

install -m 0600 "$reconciled_keys" "$authorized_tmp"
install -m 0600 "$canonical_managed" "$sidecar_tmp"
if [ "$(id -u)" -eq 0 ]; then
  chown root:root "$authorized_tmp" "$sidecar_tmp"
fi
mv -f "$authorized_tmp" "$authorized_keys"
mv -f "$sidecar_tmp" "$sidecar"
