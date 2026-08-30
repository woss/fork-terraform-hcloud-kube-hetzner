#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cleanup_script="$repo_root/scripts/cleanup.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fake_bin="$tmp/bin"
fake_home="$tmp/home"
fake_state="$tmp/state"
root="$tmp/root"
fake_config="$tmp/nonstandard-config/cli.toml"
mkdir -p "$fake_bin" "$fake_home" "${fake_config%/*}" "$fake_state/contexts" "$root"

grep -Eq 'ssh_timeout[[:space:]]*=[[:space:]]*"45s"' "$repo_root/locals.tf" \
  || { echo 'destroy-time ingress cleanup must not retry unreachable SSH for ten minutes' >&2; exit 1; }

cat > "$fake_bin/hcloud" <<'FAKE_HCLOUD'
#!/usr/bin/env bash
set -euo pipefail

state=${FAKE_HCLOUD_STATE:?}
log=${FAKE_HCLOUD_LOG:?}
config=${HCLOUD_CONFIG:?}
[ -z "${HCLOUD_ENDPOINT:-}" ] || { printf 'ambient cloud endpoint reached hcloud\n' >&2; exit 20; }
[ -z "${HETZNER_ENDPOINT:-}" ] || { printf 'ambient Hetzner endpoint reached hcloud\n' >&2; exit 21; }
[ -z "${HCLOUD_DEBUG:-}" ] || { printf 'ambient debug setting reached hcloud\n' >&2; exit 22; }
[ -z "${HCLOUD_DEBUG_FILE:-}" ] || { printf 'ambient debug file reached hcloud\n' >&2; exit 23; }
[ -z "${HCLOUD_QUIET:-}" ] || { printf 'ambient quiet setting reached hcloud\n' >&2; exit 24; }
[ -z "${HCLOUD_POLL_INTERVAL:-}" ] || { printf 'ambient poll interval reached hcloud\n' >&2; exit 25; }

render_config() {
  local name
  {
    printf 'active_context = "%s"\n' "$(cat "$state/active")"
    for token_file in "$state"/contexts/*; do
      [ -f "$token_file" ] || continue
      name=${token_file##*/}
      printf '\n[[contexts]]\n  name = "%s"\n  token = "%s"\n' "$name" "$(cat "$token_file")"
    done
  } > "$config"
}

context=""
endpoint=""
hetzner_endpoint=""
debug=""
debug_file="not-set"
quiet=""
poll_interval=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-experimental-warnings)
      shift
      ;;
    --context)
      context="$2"
      shift 2
      ;;
    --endpoint)
      endpoint="$2"
      shift 2
      ;;
    --hetzner-endpoint)
      hetzner_endpoint="$2"
      shift 2
      ;;
    --debug=*)
      debug="${1#*=}"
      shift
      ;;
    --debug-file=*)
      debug_file="${1#*=}"
      shift
      ;;
    --quiet=*)
      quiet="${1#*=}"
      shift
      ;;
    --poll-interval)
      poll_interval="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

[ "$debug" = "false" ] || { printf 'debug was not disabled by flag\n' >&2; exit 24; }
[ -z "$debug_file" ] || { printf 'debug file was not disabled by flag\n' >&2; exit 25; }
[ "$quiet" = "false" ] || { printf 'quiet was not disabled by flag\n' >&2; exit 26; }
[ "$poll_interval" = "500ms" ] || { printf 'poll interval was not pinned\n' >&2; exit 27; }

resource=${1:-}
action=${2:-}

if [ "$resource" = "version" ]; then
  printf 'hcloud v%s\n' "${FAKE_HCLOUD_VERSION:-1.59.0}"
  exit 0
fi

if [ "$resource" = "context" ]; then
  if [ "$action" = "create" ]; then
    [ "${HCLOUD_TOKEN:-}" = "${FAKE_EXPECTED_HCLOUD_TOKEN:?}" ] || {
      printf 'context create received the wrong token\n' >&2
      exit 30
    }
  else
    [ -z "${HCLOUD_TOKEN:-}" ] || { printf 'ambient token reached context command\n' >&2; exit 30; }
  fi
  case "$action" in
    list)
      for token_file in "$state"/contexts/*; do
        [ -f "$token_file" ] || continue
        name=${token_file##*/}
        printf '%-20s\n' "$name"
      done
      ;;
    active)
      cat "$state/active"
      ;;
    create)
      name=$3
      [ -n "${HCLOUD_TOKEN:-}" ] || exit 31
      printf '%s' "$HCLOUD_TOKEN" > "$state/contexts/$name"
      render_config
      printf 'context create %s\n' "$name" >> "$log"
      ;;
    rename)
      old_name=$3
      new_name=$4
      mv "$state/contexts/$old_name" "$state/contexts/$new_name"
      if [ "$(cat "$state/active")" = "$old_name" ]; then
        printf '%s' "$new_name" > "$state/active"
      fi
      render_config
      printf 'context rename %s %s\n' "$old_name" "$new_name" >> "$log"
      ;;
    use)
      name=$3
      [ -f "$state/contexts/$name" ] || exit 32
      printf '%s' "$name" > "$state/active"
      render_config
      printf 'context use %s\n' "$name" >> "$log"
      ;;
    *) exit 33 ;;
  esac
  exit 0
fi

[ "$resource" != "config" ] || {
  [ "$action" = "get" ] && [ "${3:-}" = "token" ] || exit 33
  [ -z "${HCLOUD_TOKEN:-}" ] || { printf 'ambient token reached config command\n' >&2; exit 34; }
  [ -n "$context" ] && [ -f "$state/contexts/$context" ] || exit 35
  cat "$state/contexts/$context"
  exit 0
}

[ "$context" = "demo" ] || exit 34
[ "$endpoint" = "https://api.hetzner.cloud/v1" ] || { printf 'cloud endpoint was not pinned\n' >&2; exit 35; }
[ "$hetzner_endpoint" = "https://api.hetzner.com/v1" ] || { printf 'Hetzner endpoint was not pinned\n' >&2; exit 36; }
[ "${HCLOUD_TOKEN:-}" = "${FAKE_EXPECTED_HCLOUD_TOKEN:?}" ] || {
  printf 'API command received the wrong token\n' >&2
  exit 36
}
for argument in "$@"; do
  [ "$argument" != "--help" ] || exit 0
done
if [ "$action" = "list" ]; then
  if [ "${FAKE_HCLOUD_FAIL_RESOURCE:-}" = "$resource" ]; then
    printf 'synthetic %s list failure\n' "$resource" >&2
    exit 35
  fi
  case "$resource" in
    server) [ ! -f "$state/server_present" ] || printf '100   demo-control-plane\n' ;;
    network) [ ! -f "$state/network_present" ] || printf '150   demo-network\n' ;;
    firewall) [ ! -f "$state/firewall_present" ] || printf '200   unrelated-firewall\n' ;;
    volume)
      [ ! -f "$state/volume_present" ] || printf '300   data-volume   100\n'
      [ ! -f "$state/detached_volume_present" ] || printf '301   detached-volume   -\n'
      ;;
    image) [ ! -f "$state/snapshot_present" ] || printf '400   legacy-snapshot   purpose=test\n' ;;
    *) printf '\n' ;;
  esac
  exit 0
fi

if [ "$resource" = "volume" ] && [ "$action" = "delete" ] && [ -f "$state/server_present" ]; then
  printf 'hcloud: volume is still attached to server\n' >&2
  exit 37
fi

printf '%s\n' "$*" >> "$log"
if [ "$action" = "delete" ]; then
  case "$resource" in
    server) rm -f "$state/server_present" ;;
    network) rm -f "$state/network_present" ;;
    firewall) rm -f "$state/firewall_present" ;;
    volume)
      [ "${3:-}" != "300" ] || rm -f "$state/volume_present"
      [ "${3:-}" != "301" ] || rm -f "$state/detached_volume_present"
      ;;
    image) rm -f "$state/snapshot_present" ;;
  esac
fi
FAKE_HCLOUD
chmod +x "$fake_bin/hcloud"

correct_token='correct-token-for-cleanup-tests-1234567890'
wrong_token='wrong-token-for-cleanup-tests-123456789012'
printf '%s' wrong > "$fake_state/active"
printf '%s' "$wrong_token" > "$fake_state/contexts/wrong"
touch "$fake_state/server_present" "$fake_state/network_present" "$fake_state/firewall_present"
touch "$fake_state/volume_present" "$fake_state/detached_volume_present" "$fake_state/snapshot_present"
cat > "$fake_config" <<EOF
active_context = "wrong"

[[contexts]]
  name = "wrong"
  token = "$wrong_token"
EOF
cat > "$root/kube.tf" <<'EOF'
module "kube_hetzner" {
  cluster_name = "demo"
}
EOF
cat > "$root/terraform.tfvars" <<EOF
hcloud_token = "$correct_token"
EOF
cat > "$root/custom.tfvars.json" <<EOF
{
  "hcloud_token": "$correct_token"
}
EOF
cat > "$root/common.tfvars" <<'EOF'
deployment_environment = "test"
EOF

export HOME="$fake_home"
export PATH="$fake_bin:$PATH"
export HCLOUD_CONFIG="$fake_config"
export HCLOUD_TOKEN='poisoned-ambient-token-must-not-be-used'
export HCLOUD_ENDPOINT='https://attacker.invalid/v1'
export HETZNER_ENDPOINT='https://attacker.invalid/hetzner/v1'
export HCLOUD_DEBUG=1
export HCLOUD_DEBUG_FILE="$tmp/poisoned-debug.log"
export HCLOUD_QUIET=1
export HCLOUD_POLL_INTERVAL=1h
export TF_VAR_hcloud_token="$wrong_token"
export FAKE_HCLOUD_STATE="$fake_state"
export FAKE_HCLOUD_LOG="$tmp/hcloud.log"
export FAKE_EXPECTED_HCLOUD_TOKEN="$correct_token"
: > "$FAKE_HCLOUD_LOG"

"$cleanup_script" --help > "$tmp/help.log"
grep -Fq -- '--execute' "$tmp/help.log"
grep -Fq -- '--var-file' "$tmp/help.log"
grep -Fq -- '--include-all-persistent' "$tmp/help.log"

if (
  cd "$root"
  FAKE_HCLOUD_VERSION=1.58.0 "$cleanup_script" --cluster demo --dry-run --yes
) > "$tmp/old-hcloud.log" 2>&1; then
  echo 'cleanup accepted an unsupported hcloud version' >&2
  exit 1
fi
grep -Fq 'hcloud >= 1.59.0 is required; found 1.58.0' "$tmp/old-hcloud.log"

(
  cd "$root"
  "$cleanup_script" --cluster demo --var-file common.tfvars --var-file custom.tfvars.json --dry-run --yes
) > "$tmp/dry-run.log"

grep -Fq "Created hcloud context 'demo' from custom.tfvars.json (--var-file)." "$tmp/dry-run.log"
grep -Fq 'Context:  demo (active)' "$tmp/dry-run.log"
grep -Fq '100   demo-control-plane' "$tmp/dry-run.log"
grep -Fq '200   unrelated-firewall' "$tmp/dry-run.log"
grep -Fq '400   legacy-snapshot' "$tmp/dry-run.log"
grep -Fq 'Token:    custom.tfvars.json (--var-file)' "$tmp/dry-run.log"
grep -Fq 'including unrelated or unlabeled resources' "$tmp/dry-run.log"
grep -Fq 'Dry run complete. Nothing was deleted.' "$tmp/dry-run.log"
if grep -Eq '^Delete ' "$tmp/dry-run.log"; then
  echo 'dry run executed a deletion' >&2
  exit 1
fi
if grep -Eq 'Delete [^ ]+ +$|not found: *$' "$tmp/dry-run.log"; then
  echo 'empty hcloud output became a fake resource' >&2
  exit 1
fi
[ "$(cat "$fake_state/active")" = demo ]
[ "$(cat "$fake_state/contexts/demo")" = "$correct_token" ]

: > "$FAKE_HCLOUD_LOG"
if (
  cd "$root"
  "$cleanup_script" --cluster demo --execute
) > "$tmp/noninteractive-confirmation.log" 2>&1; then
  echo 'non-interactive execute did not require --yes' >&2
  exit 1
fi
grep -Fq -- '--execute in a non-interactive shell requires --yes' "$tmp/noninteractive-confirmation.log"
if grep -Eq '(^| )delete( |$)' "$FAKE_HCLOUD_LOG"; then
  echo 'cleanup mutated resources before non-interactive confirmation' >&2
  exit 1
fi

: > "$FAKE_HCLOUD_LOG"
(
  cd "$root"
  "$cleanup_script" --cluster demo --execute --yes
) > "$tmp/execute.log"
grep -Fq 'server disable-protection 100 delete' "$FAKE_HCLOUD_LOG"
grep -Fq 'server delete 100' "$FAKE_HCLOUD_LOG"
grep -Fq 'network disable-protection 150 delete' "$FAKE_HCLOUD_LOG"
grep -Fq 'firewall delete 200' "$FAKE_HCLOUD_LOG"
grep -Fq 'No selected resources remain.' "$tmp/execute.log"
grep -Fq 'Cleanup completed in context demo.' "$tmp/execute.log"

: > "$FAKE_HCLOUD_LOG"
pty_execute="cd '$root' && exec '$cleanup_script' --cluster demo --execute --yes"
pty_status=0
if script --version >/dev/null 2>&1; then
  script -q -e -c "$pty_execute" /dev/null </dev/null > "$tmp/pty-yes.log" || pty_status=$?
else
  script -q -e /dev/null /bin/bash -c "$pty_execute" </dev/null > "$tmp/pty-yes.log" || pty_status=$?
fi
if [ "$pty_status" -ne 0 ]; then
  cat "$tmp/pty-yes.log" >&2
  echo 'cleanup failed under a pseudo-terminal with --yes' >&2
  exit 1
fi
grep -Fq 'Mode:                 EXECUTE' "$tmp/pty-yes.log"
grep -Fq 'Cleanup completed in context demo.' "$tmp/pty-yes.log"
if grep -Eq 'Execute deletion now|Delete all ' "$tmp/pty-yes.log"; then
  echo '--yes prompted for persistent data in an interactive terminal' >&2
  exit 1
fi

pty_dry_run="cd '$root' && exec '$cleanup_script' --cluster demo --yes"
pty_status=0
if script --version >/dev/null 2>&1; then
  script -q -e -c "$pty_dry_run" /dev/null </dev/null > "$tmp/pty-dry-run.log" || pty_status=$?
else
  script -q -e /dev/null /bin/bash -c "$pty_dry_run" </dev/null > "$tmp/pty-dry-run.log" || pty_status=$?
fi
if [ "$pty_status" -ne 0 ]; then
  cat "$tmp/pty-dry-run.log" >&2
  echo 'cleanup failed to default to a dry run under --yes' >&2
  exit 1
fi
grep -Fq 'Mode:                 DRY RUN' "$tmp/pty-dry-run.log"
grep -Fq 'Dry run complete. Nothing was deleted.' "$tmp/pty-dry-run.log"
if grep -Eq 'Execute deletion now|Delete all ' "$tmp/pty-dry-run.log"; then
  echo '--yes prompted under a pseudo-terminal without an explicit mode' >&2
  exit 1
fi

: > "$FAKE_HCLOUD_LOG"
touch "$fake_state/server_present"
(
  cd "$root"
  "$cleanup_script" --cluster demo --execute --include-volumes --include-snapshots --yes
) > "$tmp/persistent-delete.log"
grep -Fq 'volume delete 300' "$FAKE_HCLOUD_LOG"
grep -Fq 'volume delete 301' "$FAKE_HCLOUD_LOG"
server_delete_line=$(grep -nF 'server delete 100' "$FAKE_HCLOUD_LOG" | cut -d: -f1)
volume_delete_line=$(grep -nF 'volume delete 300' "$FAKE_HCLOUD_LOG" | cut -d: -f1)
[ "$server_delete_line" -lt "$volume_delete_line" ] || {
  echo 'cleanup must delete servers before their attached volumes' >&2
  exit 1
}
grep -Fq 'image disable-protection 400 delete' "$FAKE_HCLOUD_LOG"
grep -Fq 'image delete 400' "$FAKE_HCLOUD_LOG"
grep -Fq 'No selected resources remain.' "$tmp/persistent-delete.log"

printf '%s' "$wrong_token" > "$fake_state/contexts/demo"
cat > "$fake_config" <<EOF
active_context = "demo"

[[contexts]]
  name = "demo"
  token = "$wrong_token"
EOF
: > "$FAKE_HCLOUD_LOG"
(
  cd "$root"
  "$cleanup_script" --cluster demo --dry-run --yes
) > "$tmp/replaced-context.log" 2>&1
grep -Fq "Context 'demo' exists with a different token" "$tmp/replaced-context.log" || {
  cat "$tmp/replaced-context.log" >&2
  printf '%s\n' 'contexts seen by fake hcloud:' >&2
  env -u HCLOUD_TOKEN -u HCLOUD_CONTEXT -u HCLOUD_ENDPOINT -u HETZNER_ENDPOINT \
    -u HCLOUD_DEBUG -u HCLOUD_DEBUG_FILE -u HCLOUD_QUIET -u HCLOUD_POLL_INTERVAL \
    hcloud --debug=false --debug-file="" --quiet=false --poll-interval 500ms context list \
    -o noheader -o 'columns=name' >&2 || true
  echo 'cleanup did not detect a mismatched named context' >&2
  exit 1
}
grep -Fq 'context rename demo demo-previous-' "$FAKE_HCLOUD_LOG"
[ "$(cat "$fake_state/contexts/demo")" = "$correct_token" ]

source_roots="$tmp/token-source-roots"
mkdir -p "$source_roots/hcl-comment" "$source_roots/auto-order" "$source_roots/symlink-auto" \
  "$source_roots/default-json" "$source_roots/unparsed"
for source_root in "$source_roots"/*; do
  cp "$root/kube.tf" "$source_root/kube.tf"
done

printf 'hcloud_token = "%s" // production project\n' "$correct_token" > "$source_roots/hcl-comment/terraform.tfvars"
(
  cd "$source_roots/hcl-comment"
  "$cleanup_script" --cluster demo --dry-run --yes
) > "$tmp/hcl-comment.log"
grep -Fq 'Token:    terraform.tfvars' "$tmp/hcl-comment.log"

printf 'hcloud_token = "%s"\n' "$wrong_token" > "$source_roots/auto-order/10.auto.tfvars"
printf '{"hcloud_token":"%s"}\n' "$correct_token" > "$source_roots/auto-order/20.auto.tfvars.json"
(
  cd "$source_roots/auto-order"
  "$cleanup_script" --cluster demo --dry-run --yes
) > "$tmp/auto-order.log"
grep -Fq 'Token:    20.auto.tfvars.json' "$tmp/auto-order.log"

printf 'hcloud_token = "%s"\n' "$correct_token" > "$tmp/symlink-secret.tfvars"
ln -s "$tmp/symlink-secret.tfvars" "$source_roots/symlink-auto/30.auto.tfvars"
(
  cd "$source_roots/symlink-auto"
  "$cleanup_script" --cluster demo --dry-run --yes
) > "$tmp/symlink-auto.log"
grep -Fq 'Token:    30.auto.tfvars' "$tmp/symlink-auto.log"

printf '{\n  "hcloud_token": "%s"\n}\n' "$correct_token" > "$source_roots/default-json/terraform.tfvars.json"
(
  cd "$source_roots/default-json"
  "$cleanup_script" --cluster demo --dry-run --yes
) > "$tmp/default-json.log"
grep -Fq 'Token:    terraform.tfvars.json' "$tmp/default-json.log"

printf 'hcloud_token = trimspace("%s")\n' "$correct_token" > "$source_roots/unparsed/terraform.tfvars"
if (
  cd "$source_roots/unparsed"
  "$cleanup_script" --cluster demo --dry-run --yes
) > "$tmp/unparsed-token.log" 2>&1; then
  echo 'cleanup fell back after finding an unparsed higher-precedence token' >&2
  exit 1
fi
grep -Fq 'highest-precedence hcloud_token assignment in terraform.tfvars is not a literal string' "$tmp/unparsed-token.log"

: > "$FAKE_HCLOUD_LOG"
(
  cd "$root"
  FAKE_HCLOUD_FAIL_RESOURCE=zone "$cleanup_script" --cluster demo --dry-run --yes
) > "$tmp/optional-list-failure.log" 2>&1
grep -Fq 'DNS zones could not be inventoried; they will remain untouched.' "$tmp/optional-list-failure.log"

: > "$FAKE_HCLOUD_LOG"
if (
  cd "$root"
  FAKE_HCLOUD_FAIL_RESOURCE=zone "$cleanup_script" --cluster demo --execute --include-dns-zones --yes
) > "$tmp/selected-list-failure.log" 2>&1; then
  echo 'cleanup accepted deletion of a persistent class it could not inventory' >&2
  exit 1
fi
grep -Fq 'DNS zone deletion was requested, but DNS zones could not be inventoried.' "$tmp/selected-list-failure.log"
if grep -Eq '(^| )delete( |$)' "$FAKE_HCLOUD_LOG"; then
  echo 'cleanup mutated resources after a selected persistent inventory failed' >&2
  exit 1
fi

: > "$FAKE_HCLOUD_LOG"
if (
  cd "$root"
  FAKE_HCLOUD_FAIL_RESOURCE=network "$cleanup_script" --cluster demo --execute --yes
) > "$tmp/list-failure.log" 2>&1; then
  echo 'cleanup accepted a failed resource inventory' >&2
  exit 1
fi
grep -Fq 'failed to list networks in context demo. No deletion was attempted.' "$tmp/list-failure.log"
if grep -Eq '(^| )delete( |$)' "$FAKE_HCLOUD_LOG"; then
  echo 'cleanup mutated resources after a failed inventory' >&2
  exit 1
fi

echo 'PASS: cleanup pins the Terraform token, activates its exact context, inventories project-wide resources, and fails closed.'
