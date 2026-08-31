#!/usr/bin/env bash

set -o pipefail

PROGRAM_NAME="${0##*/}"
DRY_RUN=1
MODE_WAS_SET=0
ASSUME_YES=0
DELETE_VOLUMES=0
DELETE_SNAPSHOTS=0
DELETE_DNS_ZONES=0
DELETE_STORAGE_BOXES=0
VOLUME_POLICY_WAS_SET=0
SNAPSHOT_POLICY_WAS_SET=0
DNS_ZONE_POLICY_WAS_SET=0
STORAGE_BOX_POLICY_WAS_SET=0
CLUSTER_NAME="${CLUSTER_NAME:-}"
ROOT_HCLOUD_TOKEN=""
ROOT_HCLOUD_TOKEN_SOURCE=""
UNPARSED_HCLOUD_TOKEN_SOURCE=""
SELECTED_HCLOUD_CONTEXT=""
HCLOUD_API_ENDPOINT="https://api.hetzner.cloud/v1"
HETZNER_API_ENDPOINT="https://api.hetzner.com/v1"
DNS_ZONE_INVENTORY_AVAILABLE=0
STORAGE_BOX_INVENTORY_AVAILABLE=0
TF_VAR_FILES=()
HCLOUD_LINES=()
CLEANUP_FAILURES=0

usage() {
  cat <<EOF
Usage: $PROGRAM_NAME [options]

Forcefully remove Hetzner Cloud resources after terraform destroy stalls.
The Hetzner project/context is treated as dedicated to one cluster.

Options:
  --cluster NAME                    Cluster and hcloud context name
  --var-file PATH                   Terraform tfvars file used for this cluster
  --dry-run                         Show the deletion plan (default)
  --execute                         Delete the selected resources
  --include-volumes                 Delete every volume in the context
  --include-snapshots               Delete every snapshot in the context
  --include-dns-zones               Delete every DNS zone in the context
  --include-storage-boxes           Delete every Storage Box in the context
  --include-all-persistent          Enable all four persistent-data options
  --yes                             Skip interactive confirmation
  -h, --help                        Show this help

Authentication is resolved from Terraform inputs: TF_VAR_hcloud_token,
terraform.tfvars(.json), *.auto.tfvars(.json), explicit --var-file values, or
a literal kube.tf assignment. Pass every -var-file used for terraform apply in
the same order. Terraform -var values cannot be discovered; export the same
token as TF_VAR_hcloud_token or put it in a --var-file before cleanup. Ambient
HCloud credentials, endpoints, and debug settings are ignored so they cannot
retarget or record cleanup traffic. The exact token is stored in and activates
a context named after the cluster; a mismatched context is preserved under a
timestamped name.

Examples:
  $PROGRAM_NAME --cluster test13 --dry-run
  $PROGRAM_NAME --cluster test13 --execute --include-volumes
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-no}"
  local answer

  if [ ! -t 0 ]; then
    [ "$default_answer" = "yes" ]
    return
  fi

  if [ "$default_answer" = "yes" ]; then
    read -r -p "$prompt [Y/n] " answer
    case "$answer" in
      ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
      *) return 1 ;;
    esac
  else
    read -r -p "$prompt [y/N] " answer
    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cluster)
      [ "$#" -ge 2 ] || die "--cluster requires a value."
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --cluster=*)
      CLUSTER_NAME="${1#*=}"
      shift
      ;;
    --var-file)
      [ "$#" -ge 2 ] || die "--var-file requires a path."
      TF_VAR_FILES+=("$2")
      shift 2
      ;;
    --var-file=*)
      TF_VAR_FILES+=("${1#*=}")
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      MODE_WAS_SET=1
      shift
      ;;
    --execute)
      DRY_RUN=0
      MODE_WAS_SET=1
      shift
      ;;
    --include-volumes)
      DELETE_VOLUMES=1
      VOLUME_POLICY_WAS_SET=1
      shift
      ;;
    --include-snapshots)
      DELETE_SNAPSHOTS=1
      SNAPSHOT_POLICY_WAS_SET=1
      shift
      ;;
    --include-dns-zones)
      DELETE_DNS_ZONES=1
      DNS_ZONE_POLICY_WAS_SET=1
      shift
      ;;
    --include-storage-boxes)
      DELETE_STORAGE_BOXES=1
      STORAGE_BOX_POLICY_WAS_SET=1
      shift
      ;;
    --include-all-persistent)
      DELETE_VOLUMES=1
      DELETE_SNAPSHOTS=1
      DELETE_DNS_ZONES=1
      DELETE_STORAGE_BOXES=1
      VOLUME_POLICY_WAS_SET=1
      SNAPSHOT_POLICY_WAS_SET=1
      DNS_ZONE_POLICY_WAS_SET=1
      STORAGE_BOX_POLICY_WAS_SET=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      die "Unknown option: $1. Run '$PROGRAM_NAME --help' for usage."
      ;;
  esac
done

[ "$#" -eq 0 ] || die "Unexpected positional argument: $1"
command -v hcloud >/dev/null 2>&1 || die "hcloud CLI is required. Install it with 'brew install hcloud'."

HCLOUD_VERSION_OUTPUT=$(env -u HCLOUD_TOKEN -u HCLOUD_CONTEXT -u HCLOUD_ENDPOINT -u HETZNER_ENDPOINT \
  -u HCLOUD_DEBUG -u HCLOUD_DEBUG_FILE -u HCLOUD_QUIET -u HCLOUD_POLL_INTERVAL \
  hcloud --debug=false --debug-file="" --quiet=false --poll-interval 500ms version 2>/dev/null || true)
if [[ "$HCLOUD_VERSION_OUTPUT" =~ ^hcloud[[:space:]]+v([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  HCLOUD_VERSION_MAJOR="${BASH_REMATCH[1]}"
  HCLOUD_VERSION_MINOR="${BASH_REMATCH[2]}"
  HCLOUD_VERSION_PATCH="${BASH_REMATCH[3]}"
else
  die "Could not determine the hcloud CLI version. hcloud >= 1.59.0 is required."
fi
if [ "$HCLOUD_VERSION_MAJOR" -lt 1 ] || { [ "$HCLOUD_VERSION_MAJOR" -eq 1 ] && [ "$HCLOUD_VERSION_MINOR" -lt 59 ]; }; then
  die "hcloud >= 1.59.0 is required; found $HCLOUD_VERSION_MAJOR.$HCLOUD_VERSION_MINOR.$HCLOUD_VERSION_PATCH. Update the hcloud CLI before cleanup."
fi

if [ -z "$CLUSTER_NAME" ]; then
  GUESSED_CLUSTER_NAME=$(sed -n 's/^[[:space:]]*cluster_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' kube.tf 2>/dev/null | head -n 1)
  if [ -n "$GUESSED_CLUSTER_NAME" ] && [ -t 0 ]; then
    printf "Detected cluster '%s' in kube.tf.\n" "$GUESSED_CLUSTER_NAME"
    read -r -p "Cluster name [$GUESSED_CLUSTER_NAME]: " CLUSTER_NAME
    CLUSTER_NAME="${CLUSTER_NAME:-$GUESSED_CLUSTER_NAME}"
  elif [ -n "$GUESSED_CLUSTER_NAME" ]; then
    CLUSTER_NAME="$GUESSED_CLUSTER_NAME"
  elif [ -t 0 ]; then
    read -r -p "Cluster name: " CLUSTER_NAME
  fi
fi

[ -n "$CLUSTER_NAME" ] || die "Cluster name is required. Use --cluster NAME or run from a root containing kube.tf."
if ! [[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "Cluster name may contain only letters, numbers, dots, underscores, and hyphens."
fi

extract_literal_token() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -nE 's@^[[:space:]]*hcloud_token[[:space:]]*=[[:space:]]*"([A-Za-z0-9._-]{20,})"[[:space:]]*((#|//).*)?$@\1@p' "$file" | tail -n 1
}

extract_json_literal_token() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -nE 's/.*"hcloud_token"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]{20,})".*/\1/p' "$file" | tail -n 1
}

extract_token_from_var_file() {
  case "$1" in
    *.json) extract_json_literal_token "$1" ;;
    *) extract_literal_token "$1" ;;
  esac
}

token_assignment_present() {
  case "$1" in
    *.json) grep -Eq '"hcloud_token"[[:space:]]*:' "$1" ;;
    *) grep -Eq '^[[:space:]]*hcloud_token[[:space:]]*=' "$1" ;;
  esac
}

consider_var_file() {
  local file="$1"
  local source_label="$2"
  local candidate

  [ -f "$file" ] || return 0
  candidate=$(extract_token_from_var_file "$file")
  if [ -n "$candidate" ]; then
    ROOT_HCLOUD_TOKEN="$candidate"
    ROOT_HCLOUD_TOKEN_SOURCE="$source_label"
    UNPARSED_HCLOUD_TOKEN_SOURCE=""
  elif token_assignment_present "$file"; then
    ROOT_HCLOUD_TOKEN=""
    ROOT_HCLOUD_TOKEN_SOURCE=""
    UNPARSED_HCLOUD_TOKEN_SOURCE="$source_label"
  fi
}

resolve_root_hcloud_token() {
  local file
  local candidate

  if [ -n "${TF_VAR_hcloud_token:-}" ]; then
    ROOT_HCLOUD_TOKEN="$TF_VAR_hcloud_token"
    ROOT_HCLOUD_TOKEN_SOURCE="TF_VAR_hcloud_token"
  fi

  for file in terraform.tfvars terraform.tfvars.json; do
    consider_var_file "$file" "$file"
  done

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    consider_var_file "$file" "${file#./}"
  done < <(find . -maxdepth 1 \( -name '*.auto.tfvars' -o -name '*.auto.tfvars.json' \) -print | LC_ALL=C sort)

  for file in "${TF_VAR_FILES[@]}"; do
    [ -f "$file" ] || die "Terraform variable file not found: $file"
    consider_var_file "$file" "$file (--var-file)"
  done

  [ -z "$UNPARSED_HCLOUD_TOKEN_SOURCE" ] \
    || die "The highest-precedence hcloud_token assignment in $UNPARSED_HCLOUD_TOKEN_SOURCE is not a literal string. Refusing to fall back to a different project token."

  if [ -z "$ROOT_HCLOUD_TOKEN" ]; then
    candidate=$(extract_literal_token kube.tf)
    if [ -n "$candidate" ]; then
      ROOT_HCLOUD_TOKEN="$candidate"
      ROOT_HCLOUD_TOKEN_SOURCE="kube.tf"
    fi
  fi
}

hcloud_context_cli() {
  env -u HCLOUD_TOKEN -u HCLOUD_CONTEXT -u HCLOUD_ENDPOINT -u HETZNER_ENDPOINT \
    -u HCLOUD_DEBUG -u HCLOUD_DEBUG_FILE -u HCLOUD_QUIET -u HCLOUD_POLL_INTERVAL \
    hcloud --debug=false --debug-file="" --quiet=false --poll-interval 500ms "$@"
}

context_exists() {
  hcloud_context_cli context list -o noheader -o 'columns=name' 2>/dev/null \
    | sed 's/[[:space:]]*$//' \
    | grep -Fx "$1" >/dev/null
}

context_token() {
  local wanted_context="$1"
  hcloud_context_cli --context "$wanted_context" config get token --allow-sensitive 2>/dev/null
}

create_cluster_context() {
  local existing_token=""
  local preserved_context

  [ -n "$ROOT_HCLOUD_TOKEN" ] || die "No authoritative hcloud token was resolved for cluster '$CLUSTER_NAME'."

  if context_exists "$CLUSTER_NAME"; then
    existing_token=$(context_token "$CLUSTER_NAME" || true)
    if [ "$existing_token" != "$ROOT_HCLOUD_TOKEN" ]; then
      warn "Context '$CLUSTER_NAME' exists with a different token than $ROOT_HCLOUD_TOKEN_SOURCE."
      if [ "$ASSUME_YES" -ne 1 ] && ! prompt_yes_no "Preserve it under a timestamped name and replace it?" "no"; then
        die "Refusing to use a context whose token does not match the Terraform root."
      fi
      preserved_context="${CLUSTER_NAME}-previous-$(date +%Y%m%d%H%M%S)-$$"
      hcloud_context_cli context rename "$CLUSTER_NAME" "$preserved_context" >/dev/null \
        || die "Could not preserve the existing context as '$preserved_context'."
      printf "Preserved the previous context as '%s'.\n" "$preserved_context"
    else
      return
    fi
  fi

  env -u HCLOUD_CONTEXT -u HCLOUD_ENDPOINT -u HETZNER_ENDPOINT -u HCLOUD_DEBUG -u HCLOUD_DEBUG_FILE \
    -u HCLOUD_QUIET -u HCLOUD_POLL_INTERVAL HCLOUD_TOKEN="$ROOT_HCLOUD_TOKEN" \
    hcloud --debug=false --debug-file="" --quiet=false --poll-interval 500ms \
    context create "$CLUSTER_NAME" --token-from-env >/dev/null \
    || die "Could not create hcloud context '$CLUSTER_NAME' from $ROOT_HCLOUD_TOKEN_SOURCE."
  printf "Created hcloud context '%s' from %s.\n" "$CLUSTER_NAME" "$ROOT_HCLOUD_TOKEN_SOURCE"
}

resolve_root_hcloud_token
if [ -n "$ROOT_HCLOUD_TOKEN" ]; then
  create_cluster_context
elif context_exists "$CLUSTER_NAME"; then
  ROOT_HCLOUD_TOKEN=$(context_token "$CLUSTER_NAME" || true)
  [ -n "$ROOT_HCLOUD_TOKEN" ] || die "Could not read the token from hcloud context '$CLUSTER_NAME'."
  ROOT_HCLOUD_TOKEN_SOURCE="hcloud context '$CLUSTER_NAME' (no Terraform token found)"
else
  die "Context '$CLUSTER_NAME' does not exist and no Terraform hcloud token was found. Set TF_VAR_hcloud_token or a literal hcloud_token in terraform.tfvars."
fi

hcloud_context_cli context use "$CLUSTER_NAME" >/dev/null || die "Could not activate hcloud context '$CLUSTER_NAME'."
SELECTED_HCLOUD_CONTEXT=$(hcloud_context_cli context active 2>/dev/null || true)
[ "$SELECTED_HCLOUD_CONTEXT" = "$CLUSTER_NAME" ] || die "hcloud activated '$SELECTED_HCLOUD_CONTEXT' instead of '$CLUSTER_NAME'."

hcloud_cli() {
  env -u HCLOUD_CONTEXT -u HCLOUD_ENDPOINT -u HETZNER_ENDPOINT -u HCLOUD_DEBUG -u HCLOUD_DEBUG_FILE \
    -u HCLOUD_QUIET -u HCLOUD_POLL_INTERVAL HCLOUD_TOKEN="$ROOT_HCLOUD_TOKEN" \
    hcloud --no-experimental-warnings --debug=false --debug-file="" --quiet=false --poll-interval 500ms \
    --endpoint "$HCLOUD_API_ENDPOINT" --hetzner-endpoint "$HETZNER_API_ENDPOINT" \
    --context "$SELECTED_HCLOUD_CONTEXT" "$@"
}

collect_hcloud_lines() {
  local description="$1"
  shift
  local output
  local line

  if ! output=$(hcloud_cli "$@"); then
    printf 'Error: failed to list %s in context %s. No deletion was attempted.\n' "$description" "$SELECTED_HCLOUD_CONTEXT" >&2
    return 1
  fi

  HCLOUD_LINES=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && HCLOUD_LINES+=("$line")
  done <<< "$output"
  return 0
}

collect_hcloud_lines "servers" server list -o noheader -o 'columns=id,name' || exit 1
SERVERS=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "load balancers" load-balancer list -o noheader -o 'columns=id,name' || exit 1
LOAD_BALANCERS=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "networks" network list -o noheader -o 'columns=id,name' || exit 1
NETWORKS=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "firewalls" firewall list -o noheader -o 'columns=id,name' || exit 1
FIREWALLS=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "SSH keys" ssh-key list -o noheader -o 'columns=id,name' || exit 1
SSH_KEYS=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "placement groups" placement-group list -o noheader -o 'columns=id,name' || exit 1
PLACEMENT_GROUPS=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "floating IPs" floating-ip list -o noheader -o 'columns=id,name' || exit 1
FLOATING_IPS=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "primary IPs" primary-ip list -o noheader -o 'columns=id,name' || exit 1
PRIMARY_IPS=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "certificates" certificate list -o noheader -o 'columns=id,name,type' || exit 1
CERTIFICATES=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "volumes" volume list -o noheader -o 'columns=id,name,server' || exit 1
VOLUMES=("${HCLOUD_LINES[@]}")
collect_hcloud_lines "snapshots" image list --type snapshot -o noheader -o 'columns=id,description,labels' || exit 1
SNAPSHOTS=("${HCLOUD_LINES[@]}")
DNS_ZONES=()
if hcloud_cli zone list --help >/dev/null 2>&1; then
  if collect_hcloud_lines "DNS zones" zone list -o noheader -o 'columns=id,name'; then
    DNS_ZONES=("${HCLOUD_LINES[@]}")
    DNS_ZONE_INVENTORY_AVAILABLE=1
  else
    warn "DNS zones could not be inventoried; they will remain untouched."
  fi
else
  warn "This hcloud version cannot inventory DNS zones; they will remain untouched."
fi
STORAGE_BOXES=()
if hcloud_cli storage-box list --help >/dev/null 2>&1; then
  if collect_hcloud_lines "Storage Boxes" storage-box list -o noheader -o 'columns=id,name'; then
    STORAGE_BOXES=("${HCLOUD_LINES[@]}")
    STORAGE_BOX_INVENTORY_AVAILABLE=1
  else
    warn "Storage Boxes could not be inventoried; they will remain untouched."
  fi
else
  warn "This hcloud version cannot inventory Storage Boxes; they will remain untouched."
fi

if [ "$DELETE_DNS_ZONES" -eq 1 ] && [ "$DNS_ZONE_INVENTORY_AVAILABLE" -ne 1 ]; then
  die "DNS zone deletion was requested, but DNS zones could not be inventoried. No deletion was attempted."
fi
if [ "$DELETE_STORAGE_BOXES" -eq 1 ] && [ "$STORAGE_BOX_INVENTORY_AVAILABLE" -ne 1 ]; then
  die "Storage Box deletion was requested, but Storage Boxes could not be inventoried. No deletion was attempted."
fi

print_group() {
  local label="$1"
  shift
  [ "$#" -gt 0 ] || return
  printf '\n%s (%d)\n' "$label" "$#"
  local entry
  for entry in "$@"; do
    printf '  %s\n' "$entry"
  done
}

printf '\nKube-Hetzner force cleanup\n'
printf '%s\n' '============================'
printf 'Cluster:  %s\n' "$CLUSTER_NAME"
printf 'Context:  %s (active)\n' "$SELECTED_HCLOUD_CONTEXT"
printf 'Token:    %s\n' "$ROOT_HCLOUD_TOKEN_SOURCE"
printf 'Scope:    entire Hetzner project represented by this context\n'

print_group "Servers" "${SERVERS[@]}"
print_group "Load balancers" "${LOAD_BALANCERS[@]}"
print_group "Networks" "${NETWORKS[@]}"
print_group "Firewalls" "${FIREWALLS[@]}"
print_group "SSH keys" "${SSH_KEYS[@]}"
print_group "Placement groups" "${PLACEMENT_GROUPS[@]}"
print_group "Floating IPs" "${FLOATING_IPS[@]}"
print_group "Primary IPs" "${PRIMARY_IPS[@]}"
print_group "Certificates" "${CERTIFICATES[@]}"
print_group "Volumes" "${VOLUMES[@]}"
print_group "Snapshots" "${SNAPSHOTS[@]}"
print_group "DNS zones" "${DNS_ZONES[@]}"
print_group "Storage Boxes" "${STORAGE_BOXES[@]}"

printf '\nWarning\n'
printf '%s\n' '-------'
printf 'This context is treated as dedicated to cluster %s.\n' "$CLUSTER_NAME"
printf 'Every listed runtime resource will be deleted, including unrelated or unlabeled resources.\n'
printf 'Volumes, snapshots, DNS zones, and Storage Boxes are persistent data and require explicit inclusion.\n'
printf 'The --yes option skips the final typed confirmation; use it only in controlled automation.\n'

if [ "$MODE_WAS_SET" -eq 0 ] && [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
  if prompt_yes_no "Execute deletion now? Select no for a dry run." "no"; then
    DRY_RUN=0
  fi
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
  if [ "$VOLUME_POLICY_WAS_SET" -eq 0 ] && [ "${#VOLUMES[@]}" -gt 0 ] && prompt_yes_no "Delete all volumes?" "no"; then
    DELETE_VOLUMES=1
  fi
  if [ "$SNAPSHOT_POLICY_WAS_SET" -eq 0 ] && [ "${#SNAPSHOTS[@]}" -gt 0 ] && prompt_yes_no "Delete all snapshots?" "no"; then
    DELETE_SNAPSHOTS=1
  fi
  if [ "$DNS_ZONE_POLICY_WAS_SET" -eq 0 ] && [ "${#DNS_ZONES[@]}" -gt 0 ] && prompt_yes_no "Delete all DNS zones?" "no"; then
    DELETE_DNS_ZONES=1
  fi
  if [ "$STORAGE_BOX_POLICY_WAS_SET" -eq 0 ] && [ "${#STORAGE_BOXES[@]}" -gt 0 ] && prompt_yes_no "Delete all Storage Boxes?" "no"; then
    DELETE_STORAGE_BOXES=1
  fi
fi

printf '\nDeletion plan\n'
printf '%s\n' '-------------'
printf 'Mode:                 %s\n' "$([ "$DRY_RUN" -eq 1 ] && printf 'DRY RUN' || printf 'EXECUTE')"
printf 'Runtime resources:    DELETE ALL LISTED\n'
printf 'Volumes:              %s\n' "$([ "$DELETE_VOLUMES" -eq 1 ] && printf 'DELETE' || printf 'KEEP')"
printf 'Snapshots:            %s\n' "$([ "$DELETE_SNAPSHOTS" -eq 1 ] && printf 'DELETE' || printf 'KEEP')"
printf 'DNS zones:            %s\n' "$([ "$DELETE_DNS_ZONES" -eq 1 ] && printf 'DELETE' || printf 'KEEP')"
printf 'Storage Boxes:        %s\n' "$([ "$DELETE_STORAGE_BOXES" -eq 1 ] && printf 'DELETE' || printf 'KEEP')"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\nDry run complete. Nothing was deleted. Re-run with --execute when the plan is correct.\n'
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  [ -t 0 ] || die "--execute in a non-interactive shell requires --yes."
  printf '\nType the cluster name to confirm deletion from context %s: ' "$SELECTED_HCLOUD_CONTEXT"
  read -r confirmation
  [ "$confirmation" = "$CLUSTER_NAME" ] || die "Confirmation did not match '$CLUSTER_NAME'. Nothing was deleted."
fi

resource_id() {
  printf '%s\n' "$1" | awk '{ print $1 }'
}

run_hcloud_mutation() {
  local description="$1"
  shift
  local output

  if output=$(hcloud_cli "$@" 2>&1); then
    [ -n "$output" ] && printf '  %s\n' "$output"
    return 0
  fi
  if printf '%s\n' "$output" | grep -Ei 'not found|already (disabled|deleted)' >/dev/null; then
    printf '  Already gone: %s\n' "$description"
    return 0
  fi
  printf '  Failed: %s\n  %s\n' "$description" "$output" >&2
  CLEANUP_FAILURES=$((CLEANUP_FAILURES + 1))
  return 1
}

delete_entries() {
  local label="$1"
  local resource="$2"
  local protection="$3"
  shift 3
  local entry
  local id

  for entry in "$@"; do
    id=$(resource_id "$entry")
    [ -n "$id" ] || continue
    printf 'Delete %s %s\n' "$label" "$id"
    if [ "$protection" = "yes" ]; then
      run_hcloud_mutation "$label $id protection" "$resource" disable-protection "$id" delete || true
    fi
    run_hcloud_mutation "$label $id" "$resource" delete "$id" || true
  done
}

printf '\nDeleting resources\n'
printf '%s\n' '------------------'
delete_entries "server" server yes "${SERVERS[@]}"
delete_entries "load balancer" load-balancer yes "${LOAD_BALANCERS[@]}"
if [ "$DELETE_VOLUMES" -eq 1 ]; then
  delete_entries "volume" volume yes "${VOLUMES[@]}"
fi
delete_entries "primary IP" primary-ip yes "${PRIMARY_IPS[@]}"
delete_entries "floating IP" floating-ip yes "${FLOATING_IPS[@]}"
delete_entries "placement group" placement-group no "${PLACEMENT_GROUPS[@]}"
delete_entries "network" network yes "${NETWORKS[@]}"
delete_entries "firewall" firewall no "${FIREWALLS[@]}"
delete_entries "certificate" certificate no "${CERTIFICATES[@]}"
delete_entries "SSH key" ssh-key no "${SSH_KEYS[@]}"

if [ "$DELETE_SNAPSHOTS" -eq 1 ]; then
  delete_entries "snapshot" image yes "${SNAPSHOTS[@]}"
fi
if [ "$DELETE_DNS_ZONES" -eq 1 ]; then
  delete_entries "DNS zone" zone yes "${DNS_ZONES[@]}"
fi
if [ "$DELETE_STORAGE_BOXES" -eq 1 ]; then
  delete_entries "Storage Box" storage-box yes "${STORAGE_BOXES[@]}"
fi

VERIFY_FAILURES=0
verify_absent() {
  local description="$1"
  shift
  collect_hcloud_lines "$description" "$@" || {
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    return
  }
  if [ "${#HCLOUD_LINES[@]}" -gt 0 ]; then
    printf 'Remaining %s:\n' "$description" >&2
    printf '  %s\n' "${HCLOUD_LINES[@]}" >&2
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
}

printf '\nVerifying cleanup\n'
printf '%s\n' '-----------------'
verify_absent "servers" server list -o noheader -o 'columns=id,name'
verify_absent "load balancers" load-balancer list -o noheader -o 'columns=id,name'
verify_absent "networks" network list -o noheader -o 'columns=id,name'
verify_absent "firewalls" firewall list -o noheader -o 'columns=id,name'
verify_absent "SSH keys" ssh-key list -o noheader -o 'columns=id,name'
verify_absent "placement groups" placement-group list -o noheader -o 'columns=id,name'
verify_absent "floating IPs" floating-ip list -o noheader -o 'columns=id,name'
verify_absent "primary IPs" primary-ip list -o noheader -o 'columns=id,name'
verify_absent "certificates" certificate list -o noheader -o 'columns=id,name,type'
if [ "$DELETE_VOLUMES" -eq 1 ]; then
  verify_absent "volumes" volume list -o noheader -o 'columns=id,name,server'
fi
if [ "$DELETE_SNAPSHOTS" -eq 1 ]; then
  verify_absent "snapshots" image list --type snapshot -o noheader -o 'columns=id,description,labels'
fi
if [ "$DELETE_DNS_ZONES" -eq 1 ]; then
  verify_absent "DNS zones" zone list -o noheader -o 'columns=id,name'
fi
if [ "$DELETE_STORAGE_BOXES" -eq 1 ]; then
  verify_absent "Storage Boxes" storage-box list -o noheader -o 'columns=id,name'
fi

[ "$VERIFY_FAILURES" -eq 0 ] || die "$VERIFY_FAILURES resource class(es) still contain selected resources after cleanup."
if [ "$CLEANUP_FAILURES" -gt 0 ]; then
  warn "$CLEANUP_FAILURES operation(s) reported errors, but the final inventory confirms that no selected resources remain."
fi
printf 'No selected resources remain.\n'
printf '\nCleanup completed in context %s.\n' "$SELECTED_HCLOUD_CONTEXT"
printf 'Re-run terraform destroy so Terraform can remove stale state entries, then use a dry run to review any intentionally preserved persistent data.\n'
