#!/usr/bin/env bash
set -Eeuo pipefail

# Create linked clones of an existing Tailmox template through the Proxmox API.
# Credentials can be supplied through environment variables or entered at the
# prompts. The token secret is kept out of curl's command-line arguments.

usage() {
  cat <<EOF
Usage: $0 --api-url URL --node NODE [OPTIONS]

Required:
  --api-url URL       Proxmox base URL, for example https://pve4.example.ts.net
  --node NODE         Target Proxmox node name

Options:
  --template VALUE    Source template VM ID or name (default: tailmox-template)
  --count N           Number of VMs to create (default: 3)
  --name-prefix P     VM name prefix (default: tailmox)
  --storage NAME      Target image storage (default: template storage)
  --bridge NAME       Replace net0 with a VirtIO adapter on this bridge
  --full              Create full clones instead of linked clones
  --start             Start each VM after cloning
  --task-timeout SEC  Maximum wait for each Proxmox task (default: 3600)
  --insecure          Skip TLS certificate verification
  --help              Show this help

Credentials:
  Set PVE_API_TOKEN_ID to USER@REALM!TOKEN_ID and PVE_API_TOKEN_SECRET to the
  token secret, or enter them when prompted.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_positive_integer() {
  local label="$1"
  local value="$2"

  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$label must be a positive integer"
}

API_URL=""
NODE=""
TEMPLATE="tailmox-template"
COUNT="3"
NAME_PREFIX="tailmox"
STORAGE=""
BRIDGE=""
FULL_CLONE="0"
START_VMS=false
TASK_TIMEOUT="3600"
INSECURE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-url)
      [[ $# -ge 2 ]] || die "--api-url requires a value"
      API_URL="${2%/}"
      shift 2
      ;;
    --node)
      [[ $# -ge 2 ]] || die "--node requires a value"
      NODE="$2"
      shift 2
      ;;
    --template)
      [[ $# -ge 2 ]] || die "--template requires a value"
      TEMPLATE="$2"
      shift 2
      ;;
    --count)
      [[ $# -ge 2 ]] || die "--count requires a value"
      COUNT="$2"
      shift 2
      ;;
    --name-prefix)
      [[ $# -ge 2 ]] || die "--name-prefix requires a value"
      NAME_PREFIX="$2"
      shift 2
      ;;
    --storage)
      [[ $# -ge 2 ]] || die "--storage requires a value"
      STORAGE="$2"
      shift 2
      ;;
    --bridge)
      [[ $# -ge 2 ]] || die "--bridge requires a value"
      BRIDGE="$2"
      shift 2
      ;;
    --full)
      FULL_CLONE="1"
      shift
      ;;
    --start)
      START_VMS=true
      shift
      ;;
    --task-timeout)
      [[ $# -ge 2 ]] || die "--task-timeout requires a value"
      TASK_TIMEOUT="$2"
      shift 2
      ;;
    --insecure)
      INSECURE=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_command curl
require_command jq
require_command mktemp

[[ "$API_URL" == https://* ]] || die "--api-url must be an HTTPS URL"
[[ -n "$NODE" ]] || die "--node is required"
[[ -n "$TEMPLATE" ]] || die "--template cannot be empty"
[[ -n "$NAME_PREFIX" ]] || die "--name-prefix cannot be empty"
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "--node contains unsupported characters"
[[ "$NAME_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "--name-prefix contains unsupported characters"
if [[ "$FULL_CLONE" == "0" && -n "$STORAGE" ]]; then
  die "--storage can only be used with --full; linked clones inherit template storage"
fi
if [[ -n "$STORAGE" && ! "$STORAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "--storage contains unsupported characters"
fi
if [[ -n "$BRIDGE" && ! "$BRIDGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "--bridge contains unsupported characters"
fi
require_positive_integer "--count" "$COUNT"
require_positive_integer "--task-timeout" "$TASK_TIMEOUT"

PVE_API_TOKEN_ID="${PVE_API_TOKEN_ID:-}"
PVE_API_TOKEN_SECRET="${PVE_API_TOKEN_SECRET:-}"

if [[ -z "$PVE_API_TOKEN_ID" ]]; then
  [[ -t 0 ]] ||
    die "Set PVE_API_TOKEN_ID when running without an interactive terminal"
  read -r -p "Proxmox API token ID (USER@REALM!TOKEN_ID): " PVE_API_TOKEN_ID ||
    die "Unable to read the API token ID"
fi
if [[ -z "$PVE_API_TOKEN_SECRET" ]]; then
  [[ -t 0 ]] ||
    die "Set PVE_API_TOKEN_SECRET when running without an interactive terminal"
  read -r -s -p "Proxmox API token secret: " PVE_API_TOKEN_SECRET ||
    die "Unable to read the API token secret"
  echo
fi

[[ "$PVE_API_TOKEN_ID" == *@*!* ]] ||
  die "Token ID must use the format USER@REALM!TOKEN_ID"
[[ -n "$PVE_API_TOKEN_SECRET" ]] || die "Token secret cannot be empty"
[[ "$PVE_API_TOKEN_ID" != *$'\n'* && "$PVE_API_TOKEN_SECRET" != *$'\n'* ]] ||
  die "API credentials cannot contain newlines"

AUTH_CONFIG=$(mktemp /tmp/tailmox-pve-api.XXXXXX)
chmod 600 "$AUTH_CONFIG"
cleanup() {
  rm -f "$AUTH_CONFIG"
}
trap cleanup EXIT
printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' \
  "$PVE_API_TOKEN_ID" "$PVE_API_TOKEN_SECRET" >"$AUTH_CONFIG"
unset PVE_API_TOKEN_SECRET

CURL_ARGS=(
  --silent
  --show-error
  --fail-with-body
  --connect-timeout 10
  --max-time 60
  --config "$AUTH_CONFIG"
)
if [[ "$INSECURE" == true ]]; then
  CURL_ARGS+=(--insecure)
fi

api_request() {
  local method="$1"
  local path="$2"
  shift 2

  curl \
    "${CURL_ARGS[@]}" \
    --request "$method" \
    "$API_URL/api2/json$path" \
    "$@"
}

wait_for_task() {
  local task_node="$1"
  local upid="$2"
  local response
  local status
  local exit_status
  local deadline=$((SECONDS + TASK_TIMEOUT))

  while true; do
    if (( SECONDS >= deadline )); then
      die "Timed out after $TASK_TIMEOUT seconds waiting for Proxmox task $upid"
    fi

    response=$(api_request GET "/nodes/$task_node/tasks/$upid/status")
    status=$(jq -er '.data.status' <<<"$response") ||
      die "Proxmox returned an invalid task status response"

    if [[ "$status" == "stopped" ]]; then
      exit_status=$(jq -r '.data.exitstatus // "unknown"' <<<"$response")
      [[ "$exit_status" == "OK" ]] ||
        die "Proxmox task failed with status: $exit_status"
      return 0
    fi

    sleep 1
  done
}

echo "Checking Proxmox API access and target node..."
NODES_RESPONSE=$(api_request GET "/nodes")
jq -e --arg node "$NODE" \
  '.data[] | select(.node == $node and .status == "online")' \
  <<<"$NODES_RESPONSE" >/dev/null ||
  die "Node '$NODE' was not found or is not online"

RESOURCES_RESPONSE=$(api_request GET "/cluster/resources?type=vm")
if [[ "$TEMPLATE" =~ ^[0-9]+$ ]]; then
  TEMPLATE_MATCHES=$(
    jq -ec --argjson vmid "$TEMPLATE" \
      '[.data[] | select(.type == "qemu" and .template == 1 and .vmid == $vmid)]' \
      <<<"$RESOURCES_RESPONSE"
  ) || die "Proxmox returned invalid cluster resource data"
else
  TEMPLATE_MATCHES=$(
    jq -ec --arg name "$TEMPLATE" \
      '[.data[] | select(.type == "qemu" and .template == 1 and .name == $name)]' \
      <<<"$RESOURCES_RESPONSE"
  ) || die "Proxmox returned invalid cluster resource data"
fi

TEMPLATE_MATCH_COUNT=$(jq -er 'length' <<<"$TEMPLATE_MATCHES")
if [[ "$TEMPLATE_MATCH_COUNT" -eq 0 ]]; then
  die "QEMU template '$TEMPLATE' was not found"
elif [[ "$TEMPLATE_MATCH_COUNT" -gt 1 ]]; then
  die "More than one QEMU template is named '$TEMPLATE'; use a VM ID"
fi

TEMPLATE_DETAILS=$(jq -ec '.[0]' <<<"$TEMPLATE_MATCHES")
TEMPLATE_VMID=$(jq -er '.vmid' <<<"$TEMPLATE_DETAILS")
TEMPLATE_NODE=$(jq -er '.node' <<<"$TEMPLATE_DETAILS")

if [[ -n "$STORAGE" ]]; then
  STORAGES_RESPONSE=$(api_request GET "/nodes/$NODE/storage")
  jq -e --arg storage "$STORAGE" '
    .data[]
    | select(
        .storage == $storage
        and .active == 1
        and ((.content | split(",")) | index("images"))
      )
  ' <<<"$STORAGES_RESPONSE" >/dev/null ||
    die "Storage '$STORAGE' is not active for VM images on node '$NODE'"
fi

if [[ -n "$BRIDGE" ]]; then
  NETWORK_RESPONSE=$(api_request GET "/nodes/$NODE/network")
  jq -e --arg bridge "$BRIDGE" \
    '.data[] | select(.iface == $bridge and .type == "bridge")' \
    <<<"$NETWORK_RESPONSE" >/dev/null ||
    die "Network bridge '$BRIDGE' was not found on node '$NODE'"
fi

for ((index = 1; index <= COUNT; index++)); do
  VM_NAME="${NAME_PREFIX}${index}"
  if jq -e --arg name "$VM_NAME" '.data[] | select(.name == $name)' \
    <<<"$RESOURCES_RESPONSE" >/dev/null; then
    die "A VM named '$VM_NAME' already exists"
  fi
done

for ((index = 1; index <= COUNT; index++)); do
  VM_NAME="${NAME_PREFIX}${index}"

  NEXT_ID_RESPONSE=$(api_request GET "/cluster/nextid")
  VMID=$(jq -er '.data | tonumber' <<<"$NEXT_ID_RESPONSE") ||
    die "Proxmox did not return a valid next VM ID"

  echo "Cloning template $TEMPLATE_VMID to VM $VMID ($VM_NAME)..."
  CLONE_ARGS=(
    --data-urlencode "newid=$VMID"
    --data-urlencode "name=$VM_NAME"
    --data-urlencode "target=$NODE"
    --data-urlencode "full=$FULL_CLONE"
  )
  if [[ -n "$STORAGE" ]]; then
    CLONE_ARGS+=(--data-urlencode "storage=$STORAGE")
  fi

  CLONE_RESPONSE=$(
    api_request POST "/nodes/$TEMPLATE_NODE/qemu/$TEMPLATE_VMID/clone" "${CLONE_ARGS[@]}"
  )
  CLONE_UPID=$(jq -er '.data' <<<"$CLONE_RESPONSE") ||
    die "Proxmox did not return a task ID for VM $VMID"
  wait_for_task "$TEMPLATE_NODE" "$CLONE_UPID"

  if [[ -n "$BRIDGE" ]]; then
    CONFIG_RESPONSE=$(
      api_request PUT "/nodes/$NODE/qemu/$VMID/config" \
        --data-urlencode "net0=virtio,bridge=$BRIDGE"
    )
    CONFIG_UPID=$(jq -r '.data // empty' <<<"$CONFIG_RESPONSE")
    if [[ -n "$CONFIG_UPID" ]]; then
      wait_for_task "$NODE" "$CONFIG_UPID"
    fi
  fi

  if [[ "$START_VMS" == true ]]; then
    START_RESPONSE=$(api_request POST "/nodes/$NODE/qemu/$VMID/status/start")
    START_UPID=$(jq -er '.data' <<<"$START_RESPONSE") ||
      die "Proxmox did not return a start task ID for VM $VMID"
    wait_for_task "$NODE" "$START_UPID"
  fi

  echo "Created VM $VMID ($VM_NAME)."
done

echo "Created $COUNT VM(s) successfully."
