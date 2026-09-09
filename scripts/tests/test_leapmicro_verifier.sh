#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/packer-template/scripts/verify-leapmicro-image.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

real_gpg="$(command -v gpg)"
fake_bin="$tmp/bin"
fixtures="$tmp/fixtures"
mkdir -p "$fake_bin" "$fixtures"

cat > "$fake_bin/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

destination=""
input_file=""
config_file=""
no_redirect=0
printf '%s\n' "$@" >> "$KH_WGET_ARGV_LOG"
while (($#)); do
  case "$1" in
    -O)
      destination="$2"
      shift 2
      ;;
    --max-redirect=0)
      no_redirect=1
      shift
      ;;
    --config=*)
      config_file="${1#*=}"
      shift
      ;;
    --input-file=*)
      input_file="${1#*=}"
      shift
      ;;
    --dns-timeout=* | --connect-timeout=* | --read-timeout=* | --waitretry=* | --tries=* | --retry-connrefused | --inet4-only | -q)
      shift
      ;;
    -* )
      echo "unexpected wget option: $1" >&2
      exit 2
      ;;
    *)
      echo "unexpected positional wget argument: $1" >&2
      exit 2
      ;;
  esac
done

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

[[ -n "$destination" && -n "$input_file" ]] || exit 2
[[ "$(file_mode "$input_file")" == 600 ]] || exit 7
if [[ -n "$config_file" ]]; then
  [[ "$(file_mode "$config_file")" == 600 ]] || exit 8
fi
input_count=0
url=""
while IFS= read -r input_url || [[ -n "$input_url" ]]; do
  ((input_count += 1))
  url="$input_url"
done < "$input_file"
((input_count == 1)) || exit 9
[[ -n "$url" ]] || exit 10
[[ "${KH_FORCE_WGET_FAILURE:-0}" == 0 ]] || exit 4
[[ "${KH_REQUIRE_NO_REDIRECT:-0}" == 0 || "$no_redirect" == 1 ]] || exit 6

case "$url" in
  "$KH_IMAGE_URL") cp "$KH_FIXTURE_IMAGE" "$destination" ;;
  "$KH_CHECKSUM_URL") cp "$KH_FIXTURE_CHECKSUM" "$destination" ;;
  "$KH_SIGNATURE_URL") cp "$KH_FIXTURE_SIGNATURE" "$destination" ;;
  *) exit 5 ;;
esac
EOF
chmod 700 "$fake_bin/wget"

make_key() {
  local home="$1"
  local identity="$2"
  local expiry="$3"
  mkdir -m 700 "$home"
  "$real_gpg" --batch --homedir "$home" --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "$identity" rsa2048 sign "$expiry" >/dev/null 2>&1
  "$real_gpg" --batch --homedir "$home" --with-colons --list-keys \
    | awk -F: '$1 == "fpr" { print $10; exit }'
}

valid_home="$tmp/valid-gnupg"
valid_fingerprint="$(make_key "$valid_home" 'Verifier Valid <valid@example.invalid>' 0)"
valid_key="$fixtures/valid-key.asc"
"$real_gpg" --batch --homedir "$valid_home" --armor --export "$valid_fingerprint" > "$valid_key"

other_home="$tmp/other-gnupg"
other_fingerprint="$(make_key "$other_home" 'Verifier Other <other@example.invalid>' 0)"
other_key="$fixtures/other-key.asc"
"$real_gpg" --batch --homedir "$other_home" --armor --export "$other_fingerprint" > "$other_key"

image="$fixtures/appliance.qcow2"
printf 'deterministic Leap Micro fixture\n' > "$image"
image_digest="$(sha256sum "$image" | awk '{ print $1 }')"
checksum="$fixtures/appliance.sha256"
signature="$fixtures/appliance.sha256.asc"

sign_checksum() {
  local home="$1"
  local fingerprint="$2"
  "$real_gpg" --batch --yes --homedir "$home" --pinentry-mode loopback --passphrase '' \
    --armor --detach-sign --local-user "$fingerprint" --output "$signature" "$checksum"
}

set_checksum() {
  local filename="$1"
  local digest="${2:-$image_digest}"
  printf '%s  %s\n' "$digest" "$filename" > "$checksum"
  sign_checksum "$valid_home" "$valid_fingerprint"
}

test_version=6.2
test_arch=x86_64
custom_image=1
sidecars_explicit=1
expected_digest="$image_digest"
signing_key="$valid_key"
signing_fingerprint="$valid_fingerprint"
authorization_header=""
force_wget_failure=0
require_no_redirect=0
append_gpg_status=""
test_path="$fake_bin:$PATH"
wget_argv_log="$tmp/wget-argv.log"
: > "$wget_argv_log"
chmod 600 "$wget_argv_log"
image_url=https://mirror.example.invalid/appliance.qcow2
checksum_url=https://mirror.example.invalid/appliance.qcow2.sha256
signature_url=https://mirror.example.invalid/appliance.qcow2.sha256.asc
case_number=0
last_failure_log=""

invoke_verifier() {
  case_number=$((case_number + 1))
  local work="$tmp/case-$case_number"
  mkdir "$work"
  (
    cd "$work"
    env \
      PATH="$test_path" \
      REAL_GPG="$real_gpg" \
      KH_IMAGE_URL="$image_url" \
      KH_CHECKSUM_URL="$checksum_url" \
      KH_SIGNATURE_URL="$signature_url" \
      KH_FIXTURE_IMAGE="$image" \
      KH_FIXTURE_CHECKSUM="$checksum" \
      KH_FIXTURE_SIGNATURE="$signature" \
      KH_WGET_ARGV_LOG="$wget_argv_log" \
      KH_FORCE_WGET_FAILURE="$force_wget_failure" \
      KH_REQUIRE_NO_REDIRECT="$require_no_redirect" \
      KH_APPEND_GPG_STATUS="$append_gpg_status" \
      IMAGE_URL="$image_url" \
      CHECKSUM_URL="$checksum_url" \
      SIGNATURE_URL="$signature_url" \
      EXPECTED_IMAGE_ARCH="$test_arch" \
      EXPECTED_LEAP_MICRO_VERSION="$test_version" \
      EXPECTED_IMAGE_SHA256="$expected_digest" \
      CUSTOM_IMAGE="$custom_image" \
      SIDECAR_URLS_EXPLICIT="$sidecars_explicit" \
      VERIFIED_IMAGE_PATH="$work/verified-appliance.qcow2" \
      MIRROR_AUTHORIZATION_HEADER="$authorization_header" \
      OPENSUSE_SIGNING_KEY_FILE="$signing_key" \
      OPENSUSE_SIGNING_KEY_FINGERPRINT="$signing_fingerprint" \
      "$verifier"
  )
}

expect_success() {
  local label="$1"
  local log="$tmp/success-$case_number.log"
  if ! invoke_verifier > "$log" 2>&1; then
    echo "FAIL: $label" >&2
    cat "$log" >&2
    exit 1
  fi
  echo "PASS: $label"
}

expect_failure() {
  local label="$1"
  local pattern="$2"
  local log="$tmp/failure-$case_number.log"
  last_failure_log="$log"
  if invoke_verifier > "$log" 2>&1; then
    echo "FAIL: $label unexpectedly succeeded" >&2
    exit 1
  fi
  if ! grep -Eq "$pattern" "$log"; then
    echo "FAIL: $label returned the wrong error" >&2
    cat "$log" >&2
    exit 1
  fi
  echo "PASS: $label"
}

# Current official aliases are accepted only at their exact version-bound URLs.
custom_image=0
sidecars_explicit=0
expected_digest="$image_digest"
image_url=https://download.opensuse.org/distribution/leap-micro/6.2/appliances/openSUSE-Leap-Micro.x86_64-Default-qcow.qcow2
checksum_url="$image_url.sha256"
signature_url="$image_url.sha256.asc"
set_checksum openSUSE-Leap-Micro.x86_64-Default-qcow.qcow2
expect_success "current official x86_64 alias"

# Leap Micro 6.1 sidecars name their concrete build rather than the URL alias.
test_version=6.1
test_arch=aarch64
expected_digest="$image_digest"
image_url=https://download.opensuse.org/distribution/leap-micro/6.1/appliances/openSUSE-Leap-Micro.aarch64-Default-qcow.qcow2
checksum_url="$image_url.sha256"
signature_url="$image_url.sha256.asc"
set_checksum openSUSE-Leap-Micro.aarch64-6.1-Default-qcow-Build5.7.qcow2
expect_success "historical ARM versioned build filename"

custom_image=1
sidecars_explicit=1
test_version=6.2
test_arch=x86_64
expected_digest="$image_digest"
authorization_header='Bearer fixture-token'
require_no_redirect=1
image_url='https://mirror.example.invalid/appliance.qcow2?image-token'
checksum_url='https://mirror.example.invalid/appliance.qcow2.sha256?checksum-token'
signature_url='https://mirror.example.invalid/appliance.qcow2.sha256.asc?signature-token'
set_checksum openSUSE-Leap-Micro.x86_64-6.2-Default-qcow-Build12.9.qcow2
: > "$wget_argv_log"
expect_success "custom mirror with explicit query URLs, auth header, and digest pin"
cmp "$image" "$tmp/case-$case_number/verified-appliance.qcow2" \
  || { echo 'FAIL: verifier did not write the signed versioned image to the fixed output path' >&2; exit 1; }
for query_token in image-token checksum-token signature-token; do
  if grep -Fq "$query_token" "$wget_argv_log"; then
    echo "FAIL: query token leaked into wget process argv" >&2
    exit 1
  fi
done
authorization_header=""
require_no_redirect=0

image_url='http://mirror.example.invalid/appliance.qcow2?plaintext-query-token'
checksum_url=https://mirror.example.invalid/appliance.qcow2.sha256
signature_url=https://mirror.example.invalid/appliance.qcow2.sha256.asc
: > "$wget_argv_log"
expect_failure "query-bearing mirror URL rejects plaintext HTTP" 'query-bearing IMAGE_URL must use HTTPS'
[[ ! -s "$wget_argv_log" ]] || { echo 'FAIL: wget ran for a plaintext query URL' >&2; exit 1; }

image_url=$'https://mirror.example.invalid/appliance.qcow2?first\nsecond'
: > "$wget_argv_log"
expect_failure "URL rejects line feeds" 'IMAGE_URL must not contain control characters'
[[ ! -s "$wget_argv_log" ]] || { echo 'FAIL: wget ran for a URL containing a line feed' >&2; exit 1; }

image_url=$'https://mirror.example.invalid/appliance.qcow2?first\rsecond'
: > "$wget_argv_log"
expect_failure "URL rejects carriage returns" 'IMAGE_URL must not contain control characters'
[[ ! -s "$wget_argv_log" ]] || { echo 'FAIL: wget ran for a URL containing a carriage return' >&2; exit 1; }

image_url=$'https://mirror.example.invalid/appliance.qcow2?first\tsecond'
: > "$wget_argv_log"
expect_failure "URL rejects other control characters" 'IMAGE_URL must not contain control characters'
[[ ! -s "$wget_argv_log" ]] || { echo 'FAIL: wget ran for a URL containing a control character' >&2; exit 1; }

image_url=https://mirror.example.invalid/appliance.qcow2
checksum_url=https://mirror.example.invalid/appliance.qcow2.sha256
signature_url=https://mirror.example.invalid/appliance.qcow2.sha256.asc
expected_digest=""
expect_failure "custom mirror without an independent digest pin" 'requires a reviewed 64-character'
expected_digest="$image_digest"

authorization_header='Bearer fixture-token'
image_url=http://mirror.example.invalid/appliance.qcow2
checksum_url=http://mirror.example.invalid/appliance.qcow2.sha256
signature_url=http://mirror.example.invalid/appliance.qcow2.sha256.asc
expect_failure "authenticated mirror rejects plaintext HTTP" 'must use HTTPS'

image_url=https://image.example.invalid/appliance.qcow2
checksum_url=https://checksum.example.invalid/appliance.qcow2.sha256
signature_url=https://image.example.invalid/appliance.qcow2.sha256.asc
expect_failure "authenticated mirror rejects cross-origin sidecars" 'must use the same origin'
authorization_header=""
image_url=https://mirror.example.invalid/appliance.qcow2
checksum_url=https://mirror.example.invalid/appliance.qcow2.sha256
signature_url=https://mirror.example.invalid/appliance.qcow2.sha256.asc

set_checksum openSUSE-Leap-Micro.x86_64-6.2-Base-qcow-Build12.9.qcow2
expect_failure "wrong appliance flavor" 'exactly one safe'

set_checksum openSUSE-Leap-Micro.x86_64-6.1-Default-qcow-Build5.7.qcow2
expect_failure "wrong appliance version" 'exactly one safe'

set_checksum openSUSE-Leap-Micro.x86_64-6x2-Default-qcow-Build5.7.qcow2
expect_failure "version separator must be a literal dot" 'exactly one safe'

set_checksum openSUSE-Leap-Micro.aarch64-6.2-Default-qcow-Build12.9.qcow2
expect_failure "wrong appliance architecture" 'exactly one safe'

set_checksum ../openSUSE-Leap-Micro.x86_64-6.2-Default-qcow-Build12.9.qcow2
expect_failure "path traversal filename" 'exactly one safe'

set_checksum openSUSE-Leap-Micro.x86_64-6.2-Default-qcow-Build5..7.qcow2
expect_failure "malformed build with repeated dots" 'exactly one safe'

set_checksum openSUSE-Leap-Micro.x86_64-6.2-Default-qcow-Build5..qcow2
expect_failure "malformed build with trailing dots" 'exactly one safe'

printf '%s  %s\n%s  %s\n' \
  "$image_digest" openSUSE-Leap-Micro.x86_64-Default-qcow.qcow2 \
  "$image_digest" openSUSE-Leap-Micro.x86_64-6.2-Default-qcow-Build12.9.qcow2 > "$checksum"
sign_checksum "$valid_home" "$valid_fingerprint"
expect_failure "duplicate matching checksum records" 'exactly one safe'

set_checksum openSUSE-Leap-Micro.x86_64-Default-qcow.qcow2 "$(printf '0%.0s' {1..64})"
expect_failure "signed checksum disagrees with reviewed digest pin" 'reviewed SHA-256 digest pin'

set_checksum openSUSE-Leap-Micro.x86_64-Default-qcow.qcow2
sign_checksum "$other_home" "$other_fingerprint"
expect_failure "signature from an unpinned key" 'signature verification failed'

sign_checksum "$valid_home" "$valid_fingerprint"
extra_key_bundle="$fixtures/extra-key-bundle.asc"
cat "$valid_key" "$other_key" > "$extra_key_bundle"
signing_key="$extra_key_bundle"
expect_failure "trust bundle with an extra primary key" 'exactly one primary key'
signing_key="$valid_key"

expired_home="$tmp/expired-gnupg"
mkdir -m 700 "$expired_home"
"$real_gpg" --batch --homedir "$expired_home" --faked-system-time 20200101T000000 \
  --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Verifier Expired <expired@example.invalid>' rsa2048 sign 1d >/dev/null 2>&1
expired_fingerprint="$("$real_gpg" --batch --homedir "$expired_home" --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
expired_key="$fixtures/expired-key.asc"
"$real_gpg" --batch --homedir "$expired_home" --armor --export "$expired_fingerprint" > "$expired_key"
"$real_gpg" --batch --yes --homedir "$expired_home" --faked-system-time 20200101T010000 \
  --pinentry-mode loopback --passphrase '' --armor --detach-sign \
  --local-user "$expired_fingerprint" --output "$signature" "$checksum"
signing_key="$expired_key"
signing_fingerprint="$expired_fingerprint"
expect_failure "expired signing key" 'expired'
signing_key="$valid_key"
signing_fingerprint="$valid_fingerprint"
sign_checksum "$valid_home" "$valid_fingerprint"

status_bin="$tmp/status-bin"
mkdir "$status_bin"
cp "$fake_bin/wget" "$status_bin/wget"
cat > "$status_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_GPG" "$@"
if [[ " $* " == *" --status-fd "* && -n "${KH_APPEND_GPG_STATUS:-}" ]]; then
  echo "[GNUPG:] $KH_APPEND_GPG_STATUS"
fi
EOF
chmod 700 "$status_bin/gpg" "$status_bin/wget"
test_path="$status_bin:$PATH"
append_gpg_status='REVKEYSIG 0000000000000000 synthetic-revocation-fixture'
expect_failure "revoked signature status" 'non-allowlisted GPG status'
append_gpg_status='EXPSIG 0000000000000000 synthetic-expired-signature-fixture'
expect_failure "expired signature status" 'non-allowlisted GPG status'
append_gpg_status='NOT_A_REAL_STATUS synthetic-unknown-status-fixture'
expect_failure "unknown signature status" 'non-allowlisted GPG status'
append_gpg_status="VALIDSIG $valid_fingerprint 2026-08-08 4102444800 0 4 0 1 10 00 $valid_fingerprint"
expect_failure "signature with a future creation time" 'exactly one current VALIDSIG'
append_gpg_status="VALIDSIG $valid_fingerprint 2026-08-08 1700000000 1700000001 4 0 1 10 00 $valid_fingerprint"
expect_failure "signature with an expired lifetime" 'exactly one current VALIDSIG'
append_gpg_status=""
test_path="$fake_bin:$PATH"

image_url='https://user:supersecret@mirror.example.invalid/appliance.qcow2'
checksum_url=https://mirror.example.invalid/checksum
signature_url=https://mirror.example.invalid/signature
expect_failure "URL userinfo credentials are rejected" 'must not contain credentials'
! grep -q supersecret "$last_failure_log" || { echo 'FAIL: URL credential leaked to output' >&2; exit 1; }

image_url='https://mirror.example.invalid/appliance.qcow2?private-query-token'
checksum_url='https://mirror.example.invalid/appliance.qcow2?private-query-token.sha256'
signature_url='https://mirror.example.invalid/appliance.qcow2?private-query-token.sha256.asc'
sidecars_explicit=0
expect_failure "query URL requires explicit sidecars" 'requires explicit checksum and signature URLs'
! grep -q private-query-token "$last_failure_log" || { echo 'FAIL: query credential leaked to output' >&2; exit 1; }

sidecars_explicit=1
image_url=https://mirror.example.invalid/appliance.qcow2
checksum_url=https://mirror.example.invalid/appliance.qcow2.sha256
signature_url=https://mirror.example.invalid/appliance.qcow2.sha256.asc
authorization_header='Bearer authorization-secret'
force_wget_failure=1
set_checksum openSUSE-Leap-Micro.x86_64-Default-qcow.qcow2
expect_failure "download failure is sanitized" 'failed to download signed appliance checksum'
! grep -q authorization-secret "$last_failure_log" || { echo 'FAIL: authorization header leaked to output' >&2; exit 1; }

echo 'All Leap Micro verifier fixtures passed.'
