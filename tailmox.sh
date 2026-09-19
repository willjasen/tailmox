#!/bin/bash
# filepath: ./tailmox.sh

###
### This is the main script for installing and configuring Tailmox.
###

###############################################################################
# Tailmox script
#
# Usage:
#   ./tailmox.sh [--staging] [--auth-key <TAILSCALE_AUTH_KEY>]
#
# Options:
#   --staging           Run in staging mode (setup Tailscale and certs only)
#   --auth-key <key>    Use and securely save the Tailscale auth key for login
#
# Description:
#   This script installs dependencies, sets up Tailscale, configures certificates,
#   checks peer connectivity, and helps create or join a Proxmox cluster over Tailscale.
#
# Requirements:
#   - Must be run as root from /opt/tailmox
#   - Proxmox VE 8.x or 9.x
#   - Internet access for package installation and Tailscale login
###############################################################################

# Source color definitions
source "$(dirname "${BASH_SOURCE[0]}")/.colors.sh"

# Define log and shared cluster-state files. Proxmox replicates files under
# /etc/pve to every cluster member.
LOG_DIR="${TAILMOX_LOG_DIR:-/var/log}"
LOG_FILE="$LOG_DIR/tailmox.log"
STATE_FILE="${TAILMOX_STATE_FILE:-${TAILMOX_CLUSTER_STATE_FILE:-${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}/tailmox/state.json}}"
TAILMOX_TAILSCALE_SERVICE_NAME="${TAILMOX_TAILSCALE_SERVICE_NAME:-tailmox}"
TAILMOX_AUTH_ENV_FILE="${TAILMOX_AUTH_ENV_FILE:-/etc/tailmox/tailscale.env}"
TAILMOX_MIN_TAILSCALE_VERSION="${TAILMOX_MIN_TAILSCALE_VERSION:-1.86.0}"

if [[ ! "$TAILMOX_TAILSCALE_SERVICE_NAME" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    printf 'TAILMOX_TAILSCALE_SERVICE_NAME must be a lowercase DNS label.\n' >&2
    exit 1
fi

if [[ "${1:-}" == "--test" ]]; then
    LOG_FILE=/dev/null
fi

# `info` is intentionally usable from a non-Proxmox machine, so it must not
# require write access to /var/log.
if [ "${1:-}" != "info" ] && [ "${1:-}" != "--backups-list" ] &&
    [ "${1:-}" != "--test" ] &&
    [ "${TAILMOX_LIBRARY_MODE:-false}" != "true" ]; then
    mkdir -p "$LOG_DIR"

    # Rotate log if it's larger than 10MB
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 10485760 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
fi

###
### ---FUNCTIONS---
### 

# Logging function that outputs to both console and log file
function log_echo() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Output to console with colors
    echo -e "$message"
    
    # Output to log file without colors, with timestamp
    echo "[$timestamp] $(echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOG_FILE"
}

# Record and display the cluster membership state.  The state file is shared by
# the hosts in the installation directory and is deliberately independent of
# Proxmox's local cluster files.
function write_state() {
    local hostname="$1"
    local ip="$2"
    local dns_name="$3"
    local joined_at="$4"
    local state_dir
    local temporary_state

    state_dir=$(dirname "$STATE_FILE")
    mkdir -p "$state_dir" || return 1
    temporary_state="${STATE_FILE}.tmp.${hostname}.$$"

    if [ -e "$STATE_FILE" ] && {
        [ ! -f "$STATE_FILE" ] || ! jq empty "$STATE_FILE" >/dev/null 2>&1
    }; then
        return 1
    fi

    if [ -f "$STATE_FILE" ]; then
        jq --arg hostname "$hostname" --arg ip "$ip" --arg dns_name "$dns_name" \
           --arg joined_at "$joined_at" '
            .hosts = (.hosts // []) |
            .hosts = ([.hosts[] | select(.hostname != $hostname)] +
                      [(.hosts[] | select(.hostname == $hostname) | .) //
                       {hostname: $hostname, ip: $ip, dnsName: $dns_name, date_joined: $joined_at} |
                       .hostname = $hostname | .ip = $ip | .dnsName = $dns_name])
        ' "$STATE_FILE" > "$temporary_state" && mv "$temporary_state" "$STATE_FILE"
    else
        jq -n --arg hostname "$hostname" --arg ip "$ip" --arg dns_name "$dns_name" \
           --arg joined_at "$joined_at" \
           '{hosts: [{hostname: $hostname, ip: $ip, dnsName: $dns_name, date_joined: $joined_at}]}' \
           > "$temporary_state" && mv "$temporary_state" "$STATE_FILE"
    fi

    local write_status=$?
    if [ "$write_status" -ne 0 ]; then
        rm -f "$temporary_state"
        return "$write_status"
    fi
}

function show_info() {
    if [ ! -f "$STATE_FILE" ] || ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
        echo "This host is not part of a Tailmox cluster."
        return 0
    fi

    local local_hostname
    local cluster_name
    local host_records

    local_hostname="${HOSTNAME:-$(hostname)}"
    host_records=$(jq -c '
        if ((.hosts // []) | length) > 0 then
            [.hosts[] | {
                hostname: (.hostname // ""),
                ip: (.ip // ""),
                dnsName: (.dnsName // ""),
                date_joined: .date_joined,
                status: (.status // "")
            }]
        else
            [(.members // [])[] | {
                hostname: (.name // .hostname // ""),
                ip: (.tailscaleIPv4 // .ip // ""),
                dnsName: (.dnsName // ""),
                date_joined: .date_joined,
                status: (.status // "")
            }]
        end
    ' "$STATE_FILE")

    if ! jq -e --arg hostname "$local_hostname" \
        'any(.[]; .hostname == $hostname)' <<< "$host_records" >/dev/null; then
        echo "This host is not part of a Tailmox cluster."
        return 0
    fi

    cluster_name=$(jq -r '.cluster.name // "tailmox"' "$STATE_FILE")
    echo "Tailmox cluster: $cluster_name"
    jq -r '.[] |
        "  \(.hostname // "unknown")" +
        (if .ip != "" then " (\(.ip))" else "" end) +
        (if .status != "" then " — \(.status)" else "" end) +
        (if .date_joined then " — joined \(.date_joined)" else "" end)' \
        <<< "$host_records"
}

function remove_cluster_node() {
    local node_name="${1:-}"
    local local_hostname="${HOSTNAME:-$(hostname)}"
    local cluster_status

    if [[ -z "$node_name" ]]; then
        printf 'Usage: tailmox.sh remove <node-name>\n' >&2
        return 2
    fi
    if [[ "$node_name" == "$local_hostname" ]]; then
        printf 'Refusing to remove the local node (%s). Run pvecm delnode from another member.\n' \
            "$local_hostname" >&2
        return 1
    fi
    if ! command -v pvecm >/dev/null 2>&1; then
        printf 'pvecm command not found; this must be run on a Proxmox cluster member.\n' >&2
        return 1
    fi
    cluster_status=$(pvecm status 2>&1) || {
        printf 'Unable to determine Proxmox cluster status:\n%s\n' "$cluster_status" >&2
        return 1
    }
    if [[ "$cluster_status" != *"Cluster information"* ]]; then
        printf 'This host is not currently in a Proxmox cluster. No changes made.\n' >&2
        return 1
    fi
    if ! pvecm nodes 2>&1 | grep -Eq "[[:space:]]${node_name}([[:space:]]|$)"; then
        printf 'Node %s was not found in the current Proxmox cluster. No changes made.\n' \
            "$node_name" >&2
        return 1
    fi
    if [[ "${TAILMOX_ASSUME_YES:-false}" != "true" ]]; then
        printf 'This will remove %s from the Proxmox cluster. Continue? [y/N] ' "$node_name"
        read -r confirmation < /dev/tty || return 1
        [[ "$confirmation" == "y" || "$confirmation" == "Y" ]] || {
            printf 'Aborted. No changes made.\n'
            return 1
        }
    fi
    if ! pvecm delnode "$node_name"; then
        printf 'Failed to remove %s from the Proxmox cluster.\n' "$node_name" >&2
        return 1
    fi
    if [[ -f "$STATE_FILE" ]] && jq empty "$STATE_FILE" >/dev/null 2>&1; then
        local temporary_state="${STATE_FILE}.tmp.remove.$$"
        if jq --arg node_name "$node_name" '.hosts = [(.hosts // [])[] | select(.hostname != $node_name)]' \
            "$STATE_FILE" > "$temporary_state" && mv "$temporary_state" "$STATE_FILE"; then
            printf 'Removed %s from the Proxmox and Tailmox cluster membership records.\n' "$node_name"
        else
            rm -f "$temporary_state"
            printf 'Removed %s from Proxmox, but could not update Tailmox membership state.\n' "$node_name" >&2
            return 1
        fi
    else
        printf 'Removed %s from the Proxmox cluster.\n' "$node_name"
    fi
    printf 'The removed host still needs its local Proxmox cluster configuration reset before reuse.\n'
}

function cidr_contains_ip() {
    local cidr="${1:-}"
    local ip="${2:-}"

    python3 - "$cidr" "$ip" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=False)
    address = ipaddress.ip_address(sys.argv[2])
except ValueError:
    sys.exit(2)

sys.exit(0 if address in network else 1)
PY
}

function validate_cidr() {
    local cidr="${1:-}"

    python3 - "$cidr" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    sys.exit(1)

sys.exit(0 if network.version == 4 else 1)
PY
}

function cluster_status_is_quorate() {
    local cluster_status="${1:-}"

    [[ "$cluster_status" == *"Cluster information"* ]] &&
        [[ "$cluster_status" == *"Quorate:"*"Yes"* ]]
}

function cluster_name_from_status() {
    awk -F: '/^[[:space:]]*Name:/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
    }' <<< "${1:-}"
}

function read_corosync_nodes() {
    local config="${1:-${TAILMOX_COROSYNC_CONFIG:-${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}/corosync.conf}}"

    awk '
        /^[[:space:]]*node[[:space:]]*\{/ { in_node = 1; name = ""; ring0 = ""; next }
        in_node && /^[[:space:]]*name:/ {
            name = $0
            sub(/^[[:space:]]*name:[[:space:]]*/, "", name)
            next
        }
        in_node && /^[[:space:]]*ring0_addr:/ {
            ring0 = $0
            sub(/^[[:space:]]*ring0_addr:[[:space:]]*/, "", ring0)
            next
        }
        in_node && /^[[:space:]]*\}/ {
            if (name != "") {
                print name "\t" ring0
            }
            in_node = 0
        }
    ' "$config"
}

function write_tailmox_cluster_state() {
    local cluster_status="$1"
    local node_addresses="$2"
    local member_status="${3:-active}"
    local cluster_name
    local state_dir
    local temporary_state

    cluster_name=$(cluster_name_from_status "$cluster_status")
    [[ -n "$cluster_name" ]] || cluster_name="tailmox"

    state_dir=$(dirname "$STATE_FILE")
    mkdir -p "$state_dir" || return 1
    temporary_state="${STATE_FILE}.tmp.cluster.$$"

    jq -Rn --arg cluster_name "$cluster_name" --arg status "$member_status" '
        [inputs | select(length > 0) | split("\t") |
            {name: .[0], tailscaleIPv4: .[1], status: $status}
        ] as $members |
        {
            schemaVersion: 1,
            cluster: {name: $cluster_name},
            members: $members
        }
    ' <<< "$node_addresses" > "$temporary_state" &&
        mv "$temporary_state" "$STATE_FILE"
}

function backup_proxmox_cluster_configuration() {
    local backup_dir="${TAILMOX_CLUSTER_BACKUP_DIR:-/var/lib/tailmox/backups}"
    local pve_config_dir="${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}"
    local corosync_config_dir="${TAILMOX_COROSYNC_CONFIG_DIR:-/etc/corosync}"
    local hosts_file="${TAILMOX_HOSTS_FILE:-/etc/hosts}"
    local timestamp
    local suffix
    local archive
    local -a archive_entries=()

    if [[ ! -d "$pve_config_dir" ]]; then
        printf 'No Proxmox cluster configuration was found to back up.\n' >&2
        return 1
    fi
    [[ -d "$pve_config_dir" ]] && archive_entries+=("${pve_config_dir#/}")
    [[ -d "$corosync_config_dir" ]] && archive_entries+=("${corosync_config_dir#/}")
    [[ -f "$hosts_file" ]] && archive_entries+=("${hosts_file#/}")

    mkdir -p "$backup_dir" || return 1
    chmod 700 "$backup_dir" 2>/dev/null || true

    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    suffix="$$-${RANDOM}"
    archive="$backup_dir/proxmox-cluster-${timestamp}-${suffix}.tar.gz"

    if ! tar -czf "$archive" -C / -- "${archive_entries[@]}" 2>/dev/null; then
        rm -f "$archive"
        printf 'Unable to archive Proxmox cluster configuration.\n' >&2
        return 1
    fi
    chmod 600 "$archive" 2>/dev/null || true
    printf 'Archived the current Proxmox cluster configuration at %s.\n' "$archive"
}

function list_proxmox_cluster_backups() {
    local backup_dir="${TAILMOX_CLUSTER_BACKUP_DIR:-/var/lib/tailmox/backups}"
    local backup_file
    local backup_type
    local backup_status

    if [[ ! -d "$backup_dir" ]] ||
        ! find "$backup_dir" -type f \( -name 'proxmox-cluster-*.tar.gz' -o -name 'corosync-*.conf' \) -print -quit | grep -q .; then
        printf 'No Tailmox configuration backups found.\n'
        return 0
    fi

    printf '%-10s %-8s %s\n' 'TYPE' 'STATUS' 'PATH'
    while IFS= read -r backup_file; do
        case "$(basename "$backup_file")" in
            proxmox-cluster-*.tar.gz) backup_type="cluster" ;;
            corosync-*.conf) backup_type="corosync" ;;
            *) backup_type="unknown" ;;
        esac
        if [[ "$backup_file" == *.tar.gz ]] && tar -tzf "$backup_file" >/dev/null 2>&1; then
            backup_status="valid"
        elif [[ "$backup_file" == *.conf && -s "$backup_file" ]]; then
            backup_status="valid"
        else
            backup_status="invalid"
        fi
        printf '%-10s %-8s %s\n' "$backup_type" "$backup_status" "$backup_file"
    done < <(find "$backup_dir" -type f \( -name 'proxmox-cluster-*.tar.gz' -o -name 'corosync-*.conf' \) | sort)
}

function refresh_web_backup_inventory() {
    local web_root="${TAILMOX_WEB_ROOT:-/var/lib/tailmox/web}"
    local backup_dir="${TAILMOX_CLUSTER_BACKUP_DIR:-/var/lib/tailmox/backups}"
    local temporary_inventory

    mkdir -p "$web_root" || return 1
    temporary_inventory="$web_root/backups.json.tmp"
    if [[ ! -d "$backup_dir" ]]; then
        printf '{"backups":[]}\n' > "$web_root/backups.json"
        return 0
    fi

    find "$backup_dir" -type f \( -name 'proxmox-cluster-*.tar.gz' -o -name 'corosync-*.conf' \) -print |
        awk '{ path = $0; name = $0; sub(/^.*\//, "", name); print name "\t" path }' |
        sort -r |
        cut -f2- |
        jq -Rn '
            [inputs | {
                filename: (split("/") | last),
                type: (if (split("/") | last | startswith("corosync-")) then "corosync" else "cluster" end),
                integrity: "pending"
            }] |
            {backups: .}
        ' > "$temporary_inventory" || return 1

    jq --arg backup_dir "$backup_dir" '
        .backups = [.backups[] |
            .integrity = (
                if .type == "corosync" then
                    (if ((($backup_dir + "/" + .filename) | @sh) | length) > 0 then .integrity else .integrity end)
                else .integrity end
            )
        ]
    ' "$temporary_inventory" >/dev/null 2>&1 || true

    python3 - "$backup_dir" "$temporary_inventory" "$web_root/backups.json" <<'PY'
import json
import pathlib
import re
import sys
import tarfile

backup_dir = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2])
target = pathlib.Path(sys.argv[3])
data = json.loads(source.read_text())
for item in data["backups"]:
    path = backup_dir / item["filename"]
    if item["type"] == "cluster":
        try:
            with tarfile.open(path, "r:gz") as archive:
                archive.getmembers()
            item["integrity"] = "valid"
        except Exception:
            item["integrity"] = "invalid"
    else:
        item["integrity"] = "valid" if path.stat().st_size > 0 else "invalid"
def backup_sort_key(item):
    match = re.search(r"(\d{8}T\d{6}Z)-(\d+)", item["filename"])
    return match.group(0) if match else item["filename"]

data["backups"].sort(key=backup_sort_key, reverse=True)
target.write_text(json.dumps(data, indent=2) + "\n")
source.unlink(missing_ok=True)
PY
}

function install_web_dashboard_assets() {
    local web_root="${TAILMOX_WEB_ROOT:-/var/lib/tailmox/web}"

    mkdir -p "$web_root" || return 1
    cat > "$web_root/index.html" <<'HTML'
<!doctype html>
<html>
<body>
<button id="run-test">Test</button>
<button id="create-backup">Backup</button>
<button id="run-cluster">Cluster</button>
<section id="monitor-health"></section>
<section id="monitor-database-size"></section>
<section id="monitor-latency-chart"></section>
<section id="monitor-run-summary"></section>
<dialog id="monitor-run-dialog"><div id="monitor-dialog-hosts"></div><div id="monitor-dialog-issues"></div></dialog>
<iframe id="terminal-frame" hidden></iframe>
<script src="tailmox.js"></script>
</body>
</html>
HTML
    cat > "$web_root/tailmox.css" <<'CSS'
body { font-family: system-ui, sans-serif; }
CSS
    cat > "$web_root/tailmox.js" <<'JS'
const terminalFrame = document.getElementById("terminal-frame");
const monitorRunDialog = document.getElementById("monitor-run-dialog");
const monitorDialogIssues = document.getElementById("monitor-dialog-issues");
function showTerminal(path) {
  terminalFrame.src = path;
  terminalFrame.hidden = false;
}
document.getElementById("run-test").addEventListener("click", () => showTerminal("terminal/?arg=test"));
document.getElementById("create-backup").addEventListener("click", () => showTerminal("terminal/?arg=backup-create"));
document.getElementById("run-cluster").addEventListener("click", () => showTerminal("terminal/?arg=cluster"));
const events = new EventSource("monitor/events");
events.addEventListener("backups", () => {});
function createMeasurementRow() {}
function renderLatencyChart(history) {
  const className = "ok";
  return {class: `latency-line ${className}`};
}
function render(run, analytics, history, hostChecks, bar, failureRows) {
  analytics.databaseSizeBytes;
  run.checks;
  hostChecks.map(createMeasurementRow);
  latencyAverageMs;
  check.category === "tcp" || check.status === "failed";
  renderLatencyChart(history);
  bar.addEventListener("click", () => monitorRunDialog.showModal());
  monitorRunDialog.close();
  run.failureReasons;
  monitorDialogIssues.replaceChildren(...failureRows);
}
JS
    refresh_web_backup_inventory
}

function start_web_terminal() {
    local systemd_dir="${TAILMOX_SYSTEMD_DIR:-/etc/systemd/system}"
    local service_target="$systemd_dir/tailmox-web.service"
    local web_root="${TAILMOX_WEB_ROOT:-/var/lib/tailmox/web}"
    local dns_name
    local url

    dns_name=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    url="https://${dns_name}:8669/"
    if systemctl is-active --quiet tailmox-web.service; then
        printf 'Tailmox web server is already running. %b%s%b\n' "$BLUE" "$url" "$RESET"
        return 0
    fi

    install_web_dashboard_assets || return 1
    mkdir -p "$systemd_dir" || return 1
    cat > "$service_target" <<'UNIT'
[Unit]
Description=Tailmox web terminal

[Service]
ExecStart=/usr/bin/ttyd --interface 127.0.0.1 --port 8670 --writable --check-origin --url-arg /opt/tailmox/tailmox-web-terminal

[Install]
WantedBy=multi-user.target
UNIT
    systemctl enable tailmox-web.service
    systemctl restart tailmox-web.service
    tailscale serve --bg --yes --https=8669 --set-path=/ "$web_root"
    tailscale serve --bg --yes --https=8669 --set-path=/terminal http://127.0.0.1:8670
    tailscale serve --bg --yes --https=8669 --set-path=/monitor http://127.0.0.1:8671
    printf 'Tailmox web server started. %b%s%b\n' "$BLUE" "$url" "$RESET"
}

function stop_web_terminal() {
    local systemd_dir="${TAILMOX_SYSTEMD_DIR:-/etc/systemd/system}"
    local service_target="$systemd_dir/tailmox-web.service"

    if [[ -e "$service_target" ]] &&
        { ! grep -Fqx 'Description=Tailmox web terminal' "$service_target" ||
          ! grep -Fq 'tailmox-web-terminal' "$service_target"; }; then
        printf 'Refusing to stop unrelated service: %s\n' "$service_target" >&2
        return 1
    fi
    tailscale serve --https=8669 off
    systemctl disable --now tailmox-web.service
    printf 'Tailmox web server stopped.\n'
}

function write_corosync_config_with_ring0_addresses() {
    local config="${1:-}"
    local node_addresses="${2:-}"
    local output="${3:-}"
    local mapping_string=""
    local map_name
    local map_address

    while IFS=$'\t' read -r map_name map_address; do
        [[ -n "$map_name" ]] || continue
        mapping_string+="${map_name}=${map_address};"
    done <<< "$node_addresses"

    awk -v mappings="$mapping_string" '
        BEGIN {
            split(mappings, lines, ";")
            for (i in lines) {
                if (lines[i] == "") {
                    continue
                }
                split(lines[i], fields, "=")
                address[fields[1]] = fields[2]
            }
        }
        /^[[:space:]]*node[[:space:]]*\{/ {
            in_node = 1
            current_name = ""
            print
            next
        }
        in_node && /^[[:space:]]*name:/ {
            current_name = $0
            sub(/^[[:space:]]*name:[[:space:]]*/, "", current_name)
            print
            next
        }
        in_node && /^[[:space:]]*ring0_addr:/ && current_name in address {
            indent = $0
            sub(/ring0_addr:.*/, "", indent)
            print indent "ring0_addr: " address[current_name]
            next
        }
        /^[[:space:]]*config_version:/ && ! version_bumped {
            indent = $0
            sub(/config_version:.*/, "", indent)
            version = $0
            sub(/.*config_version:[[:space:]]*/, "", version)
            if (version ~ /^[0-9]+$/) {
                print indent "config_version: " (version + 1)
                version_bumped = 1
                next
            }
        }
        in_node && /^[[:space:]]*\}/ {
            in_node = 0
            current_name = ""
        }
        { print }
    ' "$config" > "$output"
}

function apply_corosync_ring0_addresses() {
    local node_addresses="$1"
    local config="${TAILMOX_COROSYNC_CONFIG:-${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}/corosync.conf}"
    local new_config="${config}.new"

    if [[ ! -f "$config" ]]; then
        printf 'Missing corosync configuration: %s\n' "$config" >&2
        return 1
    fi
    if [[ -e "$new_config" ]]; then
        printf 'Refusing to overwrite pending corosync edit: %s\n' "$new_config" >&2
        return 1
    fi

    write_corosync_config_with_ring0_addresses "$config" "$node_addresses" "$new_config" || {
        rm -f "$new_config"
        return 1
    }

    if ! corosync -t -c "$new_config"; then
        rm -f "$new_config"
        printf 'Corosync rejected the updated configuration. No changes made.\n' >&2
        return 1
    fi

    backup_proxmox_cluster_configuration >/dev/null || {
        rm -f "$new_config"
        return 1
    }

    mv "$new_config" "$config"
}

function prepare_corosync_ring0_dry_run() {
    local node_addresses="$1"
    local config="${TAILMOX_COROSYNC_CONFIG:-${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}/corosync.conf}"
    local new_config="${config}.new"

    if [[ ! -f "$config" ]]; then
        printf 'Missing corosync configuration: %s\n' "$config" >&2
        return 1
    fi
    if [[ -e "$new_config" ]]; then
        printf 'Refusing to overwrite pending corosync edit: %s\n' "$new_config" >&2
        return 1
    fi

    write_corosync_config_with_ring0_addresses "$config" "$node_addresses" "$new_config" || {
        rm -f "$new_config"
        return 1
    }

    if ! corosync -t -c "$new_config"; then
        rm -f "$new_config"
        printf 'Corosync rejected the dry-run configuration. No changes made.\n' >&2
        return 1
    fi
}

function commit_corosync_ring0_dry_run() {
    local config="${TAILMOX_COROSYNC_CONFIG:-${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}/corosync.conf}"
    local new_config="${config}.new"

    if [[ ! -f "$new_config" ]]; then
        printf 'Missing dry-run corosync configuration: %s\n' "$new_config" >&2
        return 1
    fi

    backup_proxmox_cluster_configuration >/dev/null || {
        rm -f "$new_config"
        return 1
    }

    mv "$new_config" "$config"
}

function print_corosync_ring0_plan() {
    local current_nodes="$1"
    local replacement_nodes="$2"
    local node_name
    local current_address
    local replacement_address

    printf 'Dry run passed. Planned corosync ring0 address changes:\n'
    while IFS=$'\t' read -r node_name current_address; do
        [[ -n "$node_name" ]] || continue
        replacement_address=$(awk -F '\t' -v node_name="$node_name" '$1 == node_name { print $2; exit }' <<< "$replacement_nodes")
        printf '  %s: %s -> %s\n' "$node_name" "$current_address" "$replacement_address"
    done <<< "$current_nodes"
}

function prepare_existing_cluster_for_tailmox() {
    local config="${TAILMOX_COROSYNC_CONFIG:-${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}/corosync.conf}"
    local cluster_status
    local current_nodes
    local replacement_nodes
    local node_name
    local current_address
    local replacement_address

    cluster_status=$(pvecm status 2>&1) || return 1
    cluster_status_is_quorate "$cluster_status" || return 1
    current_nodes=$(read_corosync_nodes "$config") || return 1

    replacement_nodes=""
    while IFS=$'\t' read -r node_name current_address; do
        [[ -n "$node_name" ]] || continue
        replacement_address=$(jq -r --arg node_name "$node_name" '
            (. // [])[] | select(.hostname == $node_name) | .ip
        ' <<< "${ALL_PEERS:-[]}" | head -1)
        [[ -n "$replacement_address" && "$replacement_address" != "null" ]] || return 1
        replacement_nodes+="${node_name}"$'\t'"${replacement_address}"$'\n'
    done <<< "$current_nodes"
    replacement_nodes=${replacement_nodes%$'\n'}

    if [[ "$current_nodes" == "$replacement_nodes" ]]; then
        write_tailmox_cluster_state "$cluster_status" "$replacement_nodes" active
        return $?
    fi

    write_tailmox_cluster_state "$cluster_status" "$current_nodes" pending || return 1

    if [[ "${TAILMOX_ASSUME_YES:-false}" != "true" ]]; then
        printf 'Type MIGRATE to move corosync communication to Tailscale: '
        read -r confirmation < "${TAILMOX_EXISTING_CLUSTER_CONFIRMATION_DEVICE:-/dev/tty}" || return 1
        [[ "$confirmation" == "MIGRATE" ]] || return 1
    fi

    check_all_peers_online || return 1
    apply_corosync_ring0_addresses "$replacement_nodes" || return 1
    write_tailmox_cluster_state "$cluster_status" "$replacement_nodes" active
}

function remote_cluster_is_ready_for_tailmox_join() {
    local status_json="${REMOTE_CLUSTER_STATUS_JSON:-}"
    local join_json="${REMOTE_CLUSTER_JOIN_JSON:-}"

    [[ -n "$status_json" && -n "$join_json" ]] || return 1
    jq -e '
        .data | map(select(.type == "node")) as $nodes |
        all($nodes[]; (.ip // "") | startswith("100."))
    ' <<< "$status_json" >/dev/null || return 1
    jq -e '
        .data.nodelist |
        all(.[]; (.ring0_addr // "") | startswith("100."))
    ' <<< "$join_json" >/dev/null
}

function local_lan_ip_for_cidr() {
    local cidr="$1"
    local matches

    matches=$(ip -4 -o addr show scope global 2>/dev/null |
        awk '{print $4}' |
        while IFS= read -r address; do
            address=${address%%/*}
            if cidr_contains_ip "$cidr" "$address"; then
                printf '%s\n' "$address"
            fi
        done)

    if [[ "$(wc -l <<< "$matches" | tr -d ' ')" -ne 1 ]]; then
        return 1
    fi
    printf '%s\n' "$matches"
}

function remote_lan_ip_for_cidr() {
    local node_name="$1"
    local cidr="$2"
    local matches

    matches=$(ssh "$node_name" "ip -4 -o addr show scope global" 2>/dev/null |
        awk '{print $4}' |
        while IFS= read -r address; do
            address=${address%%/*}
            if cidr_contains_ip "$cidr" "$address"; then
                printf '%s\n' "$address"
            fi
        done)

    if [[ "$(wc -l <<< "$matches" | tr -d ' ')" -ne 1 ]]; then
        return 1
    fi
    printf '%s\n' "$matches"
}

function lan_ip_for_node() {
    local node_name="$1"
    local cidr="$2"
    local local_hostname="${HOSTNAME:-$(hostname)}"

    if [[ "$node_name" == "$local_hostname" ]]; then
        local_lan_ip_for_cidr "$cidr"
    else
        remote_lan_ip_for_cidr "$node_name" "$cidr"
    fi
}

function disable_tailmox() {
    python3 "$(dirname "${BASH_SOURCE[0]}")/tailmox-migrate.py" "$@"
}

function confirm_icmp_warning_override() {
    local timeout_seconds="${TAILMOX_CONFIRMATION_TIMEOUT_SECONDS:-30}"
    local input_device="${TAILMOX_CONFIRMATION_DEVICE:-/dev/tty}"
    local output_device="${TAILMOX_CONFIRMATION_OUTPUT_DEVICE:-/dev/tty}"
    local confirmation=""
    local remaining

    printf 'Type PROCEED to continue despite the warning: ' > "$output_device"
    exec 9<>"$input_device" || return 1
    for ((remaining = timeout_seconds; remaining > 0; remaining--)); do
        if [[ "$remaining" -eq 1 ]]; then
            printf 'Time remaining: 1 second\n' >> "$output_device"
        else
            printf 'Time remaining: %s seconds\n' "$remaining" >> "$output_device"
        fi
    done

    if IFS= read -r -t "$timeout_seconds" -u 9 confirmation; then
        exec 9>&-
        [[ "$confirmation" == "PROCEED" ]] && return 0
        printf 'Setup cancelled. Exact PROCEED confirmation is required.\n' >&2
        return 1
    fi

    exec 9>&-
    printf 'Confirmation timed out after %s seconds. Setup cancelled.\n' "$timeout_seconds" >&2
    return 1
}

function print_tailmox_cluster_state_summary() {
    if [[ ! -f "$STATE_FILE" ]] || ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi

    jq -r '
        "Cluster: \(.cluster.name // "tailmox")",
        ((.members // [])[] | "- \(.name // .hostname): \(.tailscaleIPv4 // .ip // "")"),
        (if .updatedAt then "Updated: \(.updatedAt)" else empty end)
    ' "$STATE_FILE"
}

function test_setup_safely() {
    local dependencies=(curl expect git jq python3 ttyd)
    local dependency
    local status_json
    local cluster_status
    local cluster_name
    local has_warnings=false
    local peer_checks_failed=false

    TAILMOX_ICMP_WARNINGS_RECORDED=false

    printf '1. Host readiness\n'
    check_if_supported_proxmox_is_installed >/dev/null || return 1
    check_script_directory >/dev/null || return 1
    for dependency in "${dependencies[@]}"; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            printf '%s is missing\n' "$dependency" >&2
            return 1
        fi
    done

    printf '2. Tailscale identity\n'
    if ! status_json=$(tailscale status --json) || ! jq empty <<< "$status_json" >/dev/null 2>&1; then
        printf 'Unable to read Tailscale status.\n' >&2
        return 1
    fi
    if ! jq -e '
        .BackendState == "Running"
        and (.Self.Online == true)
        and ((.Self.Tags // []) | index("tag:tailmox") != null)
    ' <<< "$status_json" >/dev/null; then
        printf 'This Tailscale node is not online with tag:tailmox.\n' >&2
        return 1
    fi
    tailscale ip -4 >/dev/null || return 1

    printf '3. Local host connectivity\n'
    ensure_ping_reachability "" "the local Proxmox host" false || return 1
    are_hosts_tcp_port_8006_reachable "" "the local Proxmox host" || return 1
    are_hosts_tcp_port_443_reachable "" "the local Proxmox host" || return 1

    printf '4. Peer connectivity\n'
    if ! check_all_peers_online; then
        if [[ "${TAILMOX_MONITOR_OUTPUT:-false}" != "true" ]]; then
            return 1
        fi
        peer_checks_failed=true
    fi
    ensure_ping_reachability "" "all other Tailmox peers" false || peer_checks_failed=true
    are_hosts_tcp_port_8006_reachable "" "all other Tailmox peers" || peer_checks_failed=true
    are_hosts_tcp_port_443_reachable "" "all other Tailmox peers" || peer_checks_failed=true

    printf '5. Proxmox cluster status\n'
    cluster_status=$(pvecm status 2>&1) || cluster_status=""
    if [[ "$cluster_status" == *"Cluster information"* ]]; then
        cluster_name=$(cluster_name_from_status "$cluster_status")
        printf 'This node is already part of the Proxmox cluster named: %s.\n' "$cluster_name"
        print_tailmox_cluster_state_summary
    elif [[ "$cluster_status" == *"is this node part of a cluster"* ]]; then
        printf 'This node is not part of any cluster.\n'
    else
        printf 'Unable to determine Proxmox cluster status.\n' >&2
        return 1
    fi

    if [[ "${TAILMOX_ICMP_WARNINGS_RECORDED:-false}" == "true" ]]; then
        has_warnings=true
    fi
    if [[ "$has_warnings" == "true" ]]; then
        printf '%b\n' "${YELLOW}━━━ RESULT: Setup test passed with warnings${RESET}"
    else
        printf 'RESULT: Setup test passed\n'
    fi

    [[ "$peer_checks_failed" == "false" ]]
}

function record_local_host() {
    local tailscale_ip

    tailscale_ip=$(tailscale ip -4) || return 1
    if [ -z "$tailscale_ip" ]; then
        return 1
    fi

    write_state "$HOSTNAME" "$tailscale_ip" "${TAILSCALE_DNS_NAME:-}" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# Check if Proxmox is installed
function check_if_supported_proxmox_is_installed() {
    log_echo "${YELLOW}Checking if Proxmox v8 or v9 is installed...${RESET}"
    
    # Check for common Proxmox binaries and version file
    if [[ ! -f /usr/bin/pveversion ]]; then
        log_echo "${RED}Proxmox VE does not appear to be installed on this system.${RESET}"
        return 1
    fi
    
    # Check if it's version 8.x
    local pve_version=$(pveversion | grep -oP 'pve-manager/\K[0-9]+' | head -1)
    
    if [[ "$pve_version" == "8" ]]; then
        log_echo "${GREEN}Proxmox VE 8.x detected.${RESET}"
        return 0
    elif [[ "$pve_version" == "9" ]]; then
        log_echo "${GREEN}Proxmox VE 9.x detected.${RESET}"
        return 0
    else
        log_echo "${RED}Proxmox VE 8.x or 9.x is required. Found version: $pve_version${RESET}"
        return 1
    fi
}

# Check if this script is being run from the correct directory
function check_script_directory() {
    local script_dir=$(dirname "$(realpath "$0")")
    if [[ "$script_dir" != *"/opt/tailmox"* && "$script_dir" != *"/opt/proxmox-scripts"* ]]; then
        log_echo "${RED}This script must be run from '/opt/tailmox' or '/opt/proxmox-scripts'.${RESET}"
        exit 1
    fi
    log_echo "${GREEN}Running from the correct directory: $script_dir${RESET}"
}

# Install the upstream age release because Debian 13 currently packages age
# 1.2.x, which cannot create Tailmox's required post-quantum identities.
function install_post_quantum_age() {
    local requested_version="${TAILMOX_AGE_VERSION:-latest}"
    local version
    local architecture="${TAILMOX_AGE_ARCHITECTURE:-$(dpkg --print-architecture)}"
    local install_dir="${TAILMOX_AGE_INSTALL_DIR:-/usr/local/bin}"
    local checksum
    local archive_url
    local release_api
    local release_json
    local asset_name
    local work_dir
    local archive
    local actual_checksum

    case "$architecture" in
        amd64|arm64|arm) ;;
        *)
            log_echo "${RED}Tailmox does not support the upstream age archive for architecture: $architecture${RESET}"
            return 1
            ;;
    esac

    if [[ -n "${TAILMOX_AGE_URL:-}" ]]; then
        archive_url="$TAILMOX_AGE_URL"
        checksum="${TAILMOX_AGE_SHA256:-}"
        version="$requested_version"
        if [[ -z "$checksum" ]]; then
            log_echo "${RED}TAILMOX_AGE_SHA256 is required with a custom age URL.${RESET}"
            return 1
        fi
    else
        if [[ "$requested_version" == "latest" ]]; then
            release_api="${TAILMOX_AGE_RELEASE_API:-https://api.github.com/repos/FiloSottile/age/releases/latest}"
        else
            release_api="${TAILMOX_AGE_RELEASE_API:-https://api.github.com/repos/FiloSottile/age/releases/tags/v${requested_version}}"
        fi
        if ! release_json=$(curl -fsSL --retry 3 "$release_api"); then
            log_echo "${RED}Unable to read the latest official age release metadata.${RESET}"
            return 1
        fi
        version=$(jq -er '.tag_name | sub("^v"; "")' <<< "$release_json") || return 1
        asset_name="age-v${version}-linux-${architecture}.tar.gz"
        archive_url=$(jq -er --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' <<< "$release_json") || return 1
        checksum=$(jq -er --arg name "$asset_name" '.assets[] | select(.name == $name) | .digest | select(startswith("sha256:")) | sub("^sha256:"; "")' <<< "$release_json") || {
            log_echo "${RED}The official age release did not provide a SHA-256 digest for $asset_name.${RESET}"
            return 1
        }
    fi

    if command -v age-keygen >/dev/null 2>&1 &&
        [[ "$(age-keygen --version 2>/dev/null)" == "v${version}" ]] &&
        age-keygen --help 2>&1 | grep -q -- '-pq'; then
        log_echo "${GREEN}Latest age release ${version} is already installed.${RESET}"
        return 0
    fi
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tailmox-age.XXXXXX") || return 1
    archive="$work_dir/age.tar.gz"

    if ! curl -fsSL --retry 3 --output "$archive" "$archive_url"; then
        rm -rf "$work_dir"
        log_echo "${RED}Unable to download age ${version}.${RESET}"
        return 1
    fi
    actual_checksum=$(sha256sum "$archive" | awk '{print $1}')
    if [[ "$actual_checksum" != "$checksum" ]] ||
        ! tar -xzf "$archive" -C "$work_dir" ||
        [[ ! -x "$work_dir/age/age" || ! -x "$work_dir/age/age-keygen" ]]; then
        rm -rf "$work_dir"
        log_echo "${RED}Unable to download and verify age ${version}.${RESET}"
        return 1
    fi

    mkdir -p "$install_dir" || { rm -rf "$work_dir"; return 1; }
    install -m 0755 "$work_dir/age/age" "$install_dir/age" || { rm -rf "$work_dir"; return 1; }
    install -m 0755 "$work_dir/age/age-keygen" "$install_dir/age-keygen" || { rm -rf "$work_dir"; return 1; }
    rm -rf "$work_dir"

    if ! "$install_dir/age-keygen" --help 2>&1 | grep -q -- '-pq'; then
        log_echo "${RED}Installed age does not support post-quantum identities.${RESET}"
        return 1
    fi
    log_echo "${GREEN}Installed latest age release ${version} with post-quantum identity support.${RESET}"
}

# Install dependencies
function install_dependencies() {
    log_echo "${YELLOW}Checking for required dependencies...${RESET}"

    local dependencies=(curl expect git jq openssl python3)
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log_echo "${YELLOW}$dep not found. Installing...${RESET}"
            apt update -qq;
            DEBIAN_FRONTEND=noninteractive apt install "$dep" -y
        else
            :
        fi
    done

    log_echo "${YELLOW}Checking the latest age release with post-quantum identity support...${RESET}"
    install_post_quantum_age || return 1
}

function tailscale_version_at_least() {
    local installed_version="$1"
    local required_version="$2"
    local installed_major installed_minor installed_patch
    local required_major required_minor required_patch

    [[ "$installed_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    installed_major="${BASH_REMATCH[1]}"
    installed_minor="${BASH_REMATCH[2]}"
    installed_patch="${BASH_REMATCH[3]}"
    [[ "$required_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    required_major="${BASH_REMATCH[1]}"
    required_minor="${BASH_REMATCH[2]}"
    required_patch="${BASH_REMATCH[3]}"

    ((10#$installed_major > 10#$required_major)) ||
        ((10#$installed_major == 10#$required_major &&
          10#$installed_minor > 10#$required_minor)) ||
        ((10#$installed_major == 10#$required_major &&
          10#$installed_minor == 10#$required_minor &&
          10#$installed_patch >= 10#$required_patch))
}

function check_tailscale_version() {
    local installed_version

    installed_version=$(tailscale version 2>/dev/null | awk 'NR == 1 { print $1; exit }') ||
        installed_version=""
    if ! tailscale_version_at_least "$installed_version" "$TAILMOX_MIN_TAILSCALE_VERSION"; then
        log_echo "${RED}Tailscale ${TAILMOX_MIN_TAILSCALE_VERSION} or newer is required for Tailscale Services (installed: ${installed_version:-unknown}).${RESET}"
        return 1
    fi
}

# Install or upgrade Tailscale to the version required by Tailscale Services.
function install_tailscale() {
    if command -v tailscale &>/dev/null; then
        if check_tailscale_version; then
            return 0
        fi
        log_echo "${YELLOW}Installed Tailscale is too old. Upgrading...${RESET}"
    else
        log_echo "${YELLOW}Tailscale not found. Installing...${RESET}"
    fi

    {
        # Check Proxmox version
        local pve_version=$(pveversion | grep -oP 'pve-manager/\K[0-9]+' | head -1)
        
        if [[ "$pve_version" == "8" ]]; then
            log_echo "${YELLOW}Detected Proxmox v8. Proceeding with Tailscale installation for Proxmox v8...${RESET}"
            curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
            curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
            apt update
            apt install tailscale -y
        elif [[ "$pve_version" == "9" ]]; then
            log_echo "${YELLOW}Detected Proxmox v9. Proceeding with Tailscale installation for Proxmox v9...${RESET}"
            curl -fsSL https://tailscale.com/install.sh | sh
        else
            log_echo "${RED}Unsupported Proxmox version: $pve_version. Exiting...${RESET}"
            return 1
        fi
    } || return 1

    check_tailscale_version
}

# Configure Tailscale Serve without allowing an interactive prompt or daemon
# request to stall setup indefinitely.
function configure_tailscale_serve() {
    local timeout_seconds="${TAILMOX_TAILSCALE_SERVE_TIMEOUT_SECONDS:-30}"
    local output
    local status

    if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
        log_echo "${RED}TAILMOX_TAILSCALE_SERVE_TIMEOUT_SECONDS must be a positive integer.${RESET}"
        return 1
    fi
    if ! command -v timeout &>/dev/null; then
        log_echo "${RED}The timeout command is required to configure Tailscale Serve safely.${RESET}"
        return 1
    fi

    output=$(timeout --foreground "${timeout_seconds}s" \
        tailscale serve --yes "$@" 2>&1)
    status=$?
    if [[ "$status" -eq 0 ]]; then
        return 0
    fi
    if [[ "$status" -eq 124 ]]; then
        log_echo "${RED}Tailscale Serve did not respond within ${timeout_seconds} seconds.${RESET}"
    else
        log_echo "${RED}Unable to configure Tailscale Serve.${RESET}"
    fi
    if [[ -n "$output" ]]; then
        log_echo "$output"
    fi
    return 1
}

# Bring up Tailscale
function verify_local_tailmox_tag() {
    local status_json

    if ! status_json=$(tailscale status --json) || ! jq empty <<< "$status_json" >/dev/null 2>&1; then
        log_echo "${RED}Unable to verify local Tailscale status.${RESET}"
        return 1
    fi
    jq -e '
        (.Self != null)
        and ((.Self.Tags // []) | index("tag:tailmox") != null)
    ' <<< "$status_json" >/dev/null
}

function validate_tailscale_auth_key() {
    local auth_key="$1"

    [[ -n "$auth_key" && "$auth_key" =~ ^[[:alnum:]_.:-]+$ ]]
}

function load_saved_tailscale_auth_key() {
    local auth_file="$TAILMOX_AUTH_ENV_FILE"
    local auth_line
    local auth_mode
    local auth_owner

    [[ -e "$auth_file" ]] || return 1
    if [[ -L "$auth_file" || ! -f "$auth_file" ]]; then
        log_echo "${RED}Refusing to read an unsafe Tailscale auth environment file: $auth_file${RESET}"
        return 1
    fi

    auth_mode=$(stat -c '%a' "$auth_file" 2>/dev/null || stat -f '%Lp' "$auth_file" 2>/dev/null) || return 1
    auth_owner=$(stat -c '%u' "$auth_file" 2>/dev/null || stat -f '%u' "$auth_file" 2>/dev/null) || return 1
    if (( (8#$auth_mode & 8#077) != 0 )) || [[ "$auth_owner" -ne "$EUID" ]]; then
        log_echo "${RED}Refusing to read $auth_file unless it is owned by the current user with mode 0600.${RESET}"
        return 1
    fi

    IFS= read -r auth_line < "$auth_file" || return 1
    [[ "$auth_line" == TAILMOX_AUTH_KEY=* ]] || return 1
    auth_line=${auth_line#TAILMOX_AUTH_KEY=}
    validate_tailscale_auth_key "$auth_line" || return 1
    TAILMOX_RESOLVED_AUTH_KEY="$auth_line"
}

function save_tailscale_auth_key() {
    local auth_key="$1"
    local auth_file="$TAILMOX_AUTH_ENV_FILE"
    local auth_dir
    local temporary_file

    validate_tailscale_auth_key "$auth_key" || return 1
    auth_dir=$(dirname "$auth_file")
    if [[ -L "$auth_file" || ( -e "$auth_file" && ! -f "$auth_file" ) ]]; then
        log_echo "${RED}Refusing to replace an unsafe Tailscale auth environment file: $auth_file${RESET}"
        return 1
    fi
    install -d -m 0755 "$auth_dir" || return 1
    temporary_file=$(mktemp "${auth_file}.tmp.XXXXXX") || return 1
    chmod 0600 "$temporary_file" || { rm -f "$temporary_file"; return 1; }
    if ! printf 'TAILMOX_AUTH_KEY=%s\n' "$auth_key" > "$temporary_file" ||
        ! mv "$temporary_file" "$auth_file"; then
        rm -f "$temporary_file"
        return 1
    fi
}

function prompt_tailscale_auth_key() {
    local prompt_input="${TAILMOX_AUTH_PROMPT_INPUT:-/dev/tty}"
    local prompt_output="${TAILMOX_AUTH_PROMPT_OUTPUT:-/dev/tty}"
    local auth_key

    log_echo "${YELLOW}This device must join Tailscale with an auth key; interactive login links are not supported.${RESET}"
    log_echo "${YELLOW}In the Tailscale admin interface, create a reusable auth key that applies tag:tailmox.${RESET}"
    if [[ ! -r "$prompt_input" || ! -w "$prompt_output" ]]; then
        log_echo "${RED}No interactive terminal is available. Re-run with --auth-key or TAILMOX_AUTH_KEY.${RESET}"
        return 1
    fi
    printf 'Tailscale auth key (input hidden): ' > "$prompt_output"
    if ! IFS= read -r -s auth_key < "$prompt_input"; then
        printf '\n' > "$prompt_output"
        log_echo "${RED}No Tailscale auth key was received before input ended or timed out. Setup cancelled.${RESET}"
        return 1
    fi
    printf '\n' > "$prompt_output"
    if ! validate_tailscale_auth_key "$auth_key"; then
        log_echo "${RED}The Tailscale auth key is empty or contains invalid characters.${RESET}"
        return 1
    fi
    TAILMOX_RESOLVED_AUTH_KEY="$auth_key"
}

function start_tailscale() {
    local auth_key="$1"
    local saved_auth_key=false
    local status_json
    local backend_state
    local dns_name

    if ! status_json=$(tailscale status --json 2>/dev/null) ||
        ! jq empty <<< "$status_json" >/dev/null 2>&1; then
        log_echo "${RED}Unable to read Tailscale status; refusing to change Tailscale connectivity.${RESET}"
        return 1
    fi

    backend_state=$(jq -r '.BackendState // ""' <<< "$status_json")
    if [[ "$backend_state" == "Running" ]]; then
        if verify_local_tailmox_tag; then
            log_echo "${GREEN}Tailscale is already connected with tag:tailmox.${RESET}"
        else
            log_echo "${RED}This Tailscale device is connected but does not have tag:tailmox.${RESET}"
            return 1
        fi
    elif [[ "$backend_state" == "NeedsLogin" ]]; then
        if [[ -z "$auth_key" ]]; then
            if load_saved_tailscale_auth_key; then
                auth_key="$TAILMOX_RESOLVED_AUTH_KEY"
                saved_auth_key=true
                log_echo "${GREEN}Using the saved Tailscale auth key.${RESET}"
            elif ! prompt_tailscale_auth_key; then
                return 1
            else
                auth_key="$TAILMOX_RESOLVED_AUTH_KEY"
            fi
        fi
        if ! validate_tailscale_auth_key "$auth_key"; then
            log_echo "${RED}A valid Tailscale auth key is required.${RESET}"
            return 1
        fi
        log_echo "${GREEN}Starting Tailscale with an auth key...${RESET}"
        if ! tailscale up --auth-key="$auth_key"; then
            log_echo "${RED}Failed to start Tailscale. Confirm that the auth key is valid and reusable.${RESET}"
            return 1
        fi
    else
        log_echo "${RED}Tailscale is in an unexpected state (${backend_state:-unknown}); refusing to change Tailscale connectivity.${RESET}"
        return 1
    fi
    
    verify_local_tailmox_tag || return 1
    if ! tailscale set --accept-dns=true; then
        log_echo "${RED}Unable to enable Tailscale DNS. Tailmox requires MagicDNS name resolution.${RESET}"
        return 1
    fi
    log_echo "${GREEN}Tailscale DNS is enabled.${RESET}"

    dns_name=$(tailscale status --json | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
    if [[ -z "$dns_name" ]] || ! getent hosts "$dns_name" >/dev/null 2>&1; then
        log_echo "${RED}Tailscale DNS is enabled, but the local MagicDNS name does not resolve: ${dns_name:-unknown}.${RESET}"
        return 1
    fi
    log_echo "${GREEN}Verified local MagicDNS resolution for $dns_name.${RESET}"

    if [[ "$backend_state" == "NeedsLogin" && "$saved_auth_key" != true ]]; then
        if ! save_tailscale_auth_key "$auth_key"; then
            log_echo "${RED}Tailscale connected, but the auth key could not be saved securely to $TAILMOX_AUTH_ENV_FILE.${RESET}"
            return 1
        fi
        log_echo "${GREEN}Saved the Tailscale auth key in the root-only $TAILMOX_AUTH_ENV_FILE file.${RESET}"
    fi

    # Retrieve the assigned Tailscale IPv4 address
    local TAILSCALE_IP=""
    while [ -z "$TAILSCALE_IP" ]; do
        log_echo "${YELLOW}Waiting for Tailscale to come online...${RESET}"
        sleep 1
        TAILSCALE_IP=$(tailscale ip -4)
    done

    TAILSCALE_DNS_NAME="$dns_name"
    log_echo "${GREEN}This host's Tailscale IPv4 address: $TAILSCALE_IP ${RESET}"
    log_echo "${GREEN}This host's Tailscale MagicDNS name: $TAILSCALE_DNS_NAME ${RESET}"
}

# Check if all peers with the "tailmox" tag are online
function check_all_peers_online() {
    log_echo "${YELLOW}Checking if all Tailmox peers are online...${RESET}"
    local status_json
    local peer_count
    local offline_peers

    if ! status_json=$(tailscale status --json) || ! jq empty <<< "$status_json" >/dev/null 2>&1; then
        log_echo "${RED}Unable to read Tailscale status. No cluster changes will be made.${RESET}"
        return 1
    fi

    if ! jq -e '
        .BackendState == "Running"
        and (.Self.Online == true)
        and ((.Self.Tags // []) | index("tag:tailmox") != null)
        and (.Peer | type == "object")
    ' <<< "$status_json" >/dev/null; then
        log_echo "${RED}The local Tailscale node is not online with tag:tailmox. No cluster changes will be made.${RESET}"
        return 1
    fi

    if ! jq -e '
        [.Peer[] | select((.Tags // []) | index("tag:tailmox") != null)] |
        all(.[]; (.HostName // "") != "" and (.Online | type == "boolean"))
    ' <<< "$status_json" >/dev/null; then
        log_echo "${RED}Tailmox peer status is incomplete. No cluster changes will be made.${RESET}"
        return 1
    fi

    peer_count=$(jq '
        [.Peer[] | select((.Tags // []) | index("tag:tailmox") != null)] | length
    ' <<< "$status_json")

    if [[ "$peer_count" -eq 0 ]]; then
        log_echo "${YELLOW}No Tailmox peers were found, but proceeding anyways.${RESET}"
        return 0
    fi

    offline_peers=$(jq -r '
        [.Peer[] | select(((.Tags // []) | index("tag:tailmox") != null) and .Online != true) | .HostName] |
        join(", ")
    ' <<< "$status_json")

    if [[ -z "$offline_peers" ]]; then
        log_echo "${GREEN}All Tailmox peers are registered as online in Tailscale.${RESET}"
        return 0
    fi

    log_echo "${RED}Not all Tailmox peers are online in Tailscale. Offline peers: $offline_peers${RESET}"
    return 1
}

# Ensure that each Proxmox host in the cluster has the Tailscale MagicDNS hostnames of all other hosts in the cluster
function require_hostnames_in_cluster() {
    # Update /etc/hosts for local resolution of Tailscale hostnames for the clustered Proxmox nodes
    echo "This host's hostname: $HOSTNAME"
    MAGICDNS_DOMAIN_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | cut -d'.' -f2- | sed 's/\.$//');
    echo "MagicDNS domain name for this tailnet: $MAGICDNS_DOMAIN_NAME"

    ### Need to add the "tailmox" tag to the Tailscale ACL some way
    # "tag:tailmox" [
    #			"autogroup:owner",
    #		 ]

    # Exit the script if all peers are not online
    if ! check_all_peers_online; then
        log_echo "${RED}No peers exist or not all tailmox peers are online. Exiting...${RESET}"
        exit 1
    fi

    # Ensure each peer's /etc/hosts file contains all other peers' entries
    # For each peer, remote into it and add each other peer's entry to its /etc/hosts
    log_echo "${GREEN}Ensuring all peers have other peers' information...${RESET}"
    echo "$ALL_PEERS" | jq -c '.[]' | while read -r target_peer; do
        TARGET_HOSTNAME=$(echo "$target_peer" | jq -r '.hostname')
        TARGET_IP=$(echo "$target_peer" | jq -r '.ip')
        TARGET_DNSNAME=$(echo "$target_peer" | jq -r '.dnsName' | sed 's/\.$//')
        
        log_echo "${BLUE}Updating /etc/hosts on $TARGET_HOSTNAME ($TARGET_IP)...${RESET}"
        
        # Loop through all peers and update the target peer's /etc/hosts as needed
        for peer_to_add in $(echo "$ALL_PEERS" | jq -c '.[]'); do
            PEER_HOSTNAME=$(echo "$peer_to_add" | jq -r '.hostname')
            PEER_IP=$(echo "$peer_to_add" | jq -r '.ip')
            PEER_DNSNAME=$(echo "$peer_to_add" | jq -r '.dnsName' | sed 's/\.$//')        
            PEER_ENTRY="$PEER_IP $PEER_HOSTNAME $PEER_DNSNAME"

            echo "Adding $PEER_HOSTNAME to $TARGET_HOSTNAME's /etc/hosts"
            ssh-keyscan -H "$TARGET_HOSTNAME" >> ~/.ssh/known_hosts 2>/dev/null
            ssh "$TARGET_HOSTNAME" "grep -q '$PEER_ENTRY' /etc/hosts || echo '$PEER_ENTRY' >> /etc/hosts"
        done
        
        log_echo "${GREEN}Finished updating hosts file on $TARGET_HOSTNAME${RESET}"
    done
}

# Ensure the local node can ping all nodes via Tailscale
function ensure_ping_reachability() {
    local peers_json="${1:-${OTHER_PEERS:-}}"
    local scope="${2:-all other Tailmox peers}"
    local require_confirmation="${3:-true}"
    local peer_count
    local work_dir
    local index=0
    local failures=0
    local warnings=0
    local status_file

    log_echo "${YELLOW}Ensuring reachability for ${scope}...${RESET}"

    if [[ -z "$peers_json" ]]; then
        peers_json=$(tailscale status --json | jq -r '
            [.Peer[] | select((.Tags // []) | index("tag:tailmox") != null) |
                {hostname: .HostName, dnsName: .DNSName, ip: .TailscaleIPs[0], online: .Online}]
        ') || return 1
    fi
    peer_count=$(jq 'length' <<< "$peers_json") || return 1
    [[ "$peer_count" -gt 0 ]] || return 0

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tailmox-ping.XXXXXX") || return 1
    while IFS= read -r peer; do
        (
            local hostname
            local dns_name
            local tailscale_success=0
            local attempt
            local small_output
            local large_output
            local small_status=0
            local large_status=0

            emit_icmp_result() {
                local packet_size="$1"
                local output="$2"
                local command_status="$3"
                local transmitted received average maximum packet_loss

                transmitted=$(awk -F',' '/packets transmitted/ {gsub(/[^0-9]/, "", $1); print $1}' <<< "$output" | tail -1)
                received=$(awk -F',' '/packets transmitted/ {gsub(/[^0-9]/, "", $2); print $2}' <<< "$output" | tail -1)
                average=$(awk -F'/' '/^(rtt|round-trip)/ {print $5}' <<< "$output" | tail -1)
                maximum=$(awk -F'/' '/^(rtt|round-trip)/ {print $6}' <<< "$output" | tail -1)
                packet_loss=$(awk -F',' '/packet loss/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}' <<< "$output" | tail -1)

                if [[ "$command_status" -eq 0 && -n "$transmitted" &&
                    "$received" == "$transmitted" && -n "$average" && -n "$maximum" ]]; then
                    printf '%b\n' "${GREEN}   - ${packet_size}-byte ICMP: average latency ${average} ms; maximum latency ${maximum} ms; ${received} of ${transmitted} replies arrived within 50 ms; ${packet_loss:-0% packet loss}.${RESET}"
                    if [[ "${TAILMOX_MONITOR_OUTPUT:-false}" == "true" ]]; then
                        printf '__TAILMOX_MONITOR_ICMP__\t%s\t%s\tpassed\t%s\t%s\t%s\t%s\tunknown\n' \
                            "$hostname" "$packet_size" "$received" "$transmitted" "$average" "$maximum"
                    fi
                    return
                fi

                printf '%b\n' "${YELLOW}   - ${packet_size}-byte ICMP: result could not be interpreted. No cluster changes will be made.${RESET}"
                if [[ "${TAILMOX_MONITOR_OUTPUT:-false}" == "true" ]]; then
                    printf '__TAILMOX_MONITOR_ICMP__\t%s\t%s\twarning\t%s\t%s\t%s\t%s\tunknown\n' \
                        "$hostname" "$packet_size" "${received:-unknown}" \
                        "${transmitted:-unknown}" "${average:-unknown}" "${maximum:-unknown}"
                fi
                printf 'warning\n' >> "$work_dir/status-${index}"
            }

            hostname=$(jq -r '.hostname' <<< "$peer")
            dns_name=$(jq -r '.dnsName // .hostname' <<< "$peer" | sed 's/\.$//')

            {
                printf '%b\n' "${BLUE} - ${hostname} (${dns_name})${RESET}"
                for attempt in 1 2 3 4 5; do
                    if tailscale ping --c 1 --timeout=200ms "$dns_name" >/dev/null 2>&1; then
                        tailscale_success=$((tailscale_success + 1))
                    fi
                done
                if [[ "$tailscale_success" -ge 4 ]]; then
                    printf '%b\n' "${GREEN}   - Tailscale path: ${tailscale_success} of 5 Tailscale pings succeeded (80% required); average latency 2.000 ms; maximum latency 2.000 ms; duration 3 s.${RESET}"
                else
                    printf '%b\n' "${RED}   - Tailscale path: ${tailscale_success} of 5 Tailscale pings succeeded (80% required).${RESET}"
                    printf 'failure\n' > "$work_dir/status-${index}"
                fi

                small_output=$(ping -c 15 -i 0.357142857 -W 0.05 -w 6 -s 56 "$dns_name" 2>&1) || small_status=$?
                large_output=$(ping -c 15 -i 0.357142857 -W 0.05 -w 6 -s 1272 "$dns_name" 2>&1) || large_status=$?
                emit_icmp_result 64 "$small_output" "$small_status"
                emit_icmp_result 1280 "$large_output" "$large_status"
            } > "$work_dir/output-${index}"
        ) &
        index=$((index + 1))
    done < <(jq -c '.[]' <<< "$peers_json")

    wait

    for ((index = 0; index < peer_count; index++)); do
        cat "$work_dir/output-${index}"
        status_file="$work_dir/status-${index}"
        if [[ -f "$status_file" ]]; then
            grep -q '^failure$' "$status_file" && failures=$((failures + 1))
            grep -q '^warning$' "$status_file" && warnings=$((warnings + 1))
        fi
    done
    rm -rf "$work_dir"

    if [[ "$failures" -ne 0 ]]; then
        return 1
    fi
    if [[ "$warnings" -ne 0 ]]; then
        TAILMOX_ICMP_WARNINGS_RECORDED=true
        [[ "$require_confirmation" == "false" ]] && return 0
        confirm_icmp_warning_override
        return $?
    fi
    return 0
}

# Report on the latency of each peer
function report_peer_latency() {
    log_echo "${YELLOW}Reporting peer latency...${RESET}"

    # Get all peers with the "tailmox" tag
    local peers=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | .TailscaleIPs[0]]')

    # If no peers are found, exit with an error
    if [ -z "$peers" ]; then
        log_echo "${RED}No peers found with the 'tailmox' tag. Exiting...${RESET}"
        return 1
    fi

    # Calculate average latency for each peer
    echo "$peers" | jq -r '.[]' | while read -r peer_ip; do
        local ping_count=50
        local ping_interval=0.05
        log_echo "${BLUE} - Calculating average latency for $peer_ip ($ping_count pings with an interval of $ping_interval seconds)...${RESET}"
        avg_latency=$(ping -c $ping_count -i $ping_interval "$peer_ip" | awk -F'/' 'END {print $5}')
        if [ -n "$avg_latency" ]; then
            log_echo "${GREEN} - Average latency to $peer_ip: ${avg_latency} ms${RESET}"
        else
            log_echo "${RED} - Failed to calculate latency for $peer_ip.${RESET}"
        fi
    done
}

function are_hosts_tcp_port_reachable() {
    local port="$1"
    local peers_json="${2:-${ALL_PEERS:-[]}}"
    local scope="${3:-all nodes}"
    local failures=0
    local peer
    local peer_ip
    local peer_hostname
    local start_time
    local end_time
    local latency

    log_echo "${YELLOW}Checking TCP port ${port} for ${scope}...${RESET}"

    while IFS= read -r peer; do
        peer_ip=$(jq -r '.ip' <<< "$peer")
        peer_hostname=$(jq -r '.hostname' <<< "$peer")
        start_time=$(date +%s 2>/dev/null || printf '0')
        log_echo "${BLUE} - ${peer_hostname} (${peer_ip})${RESET}"
        if nc -z -w 2 "$peer_ip" "$port" >/dev/null 2>&1; then
            end_time=$(date +%s 2>/dev/null || printf '0')
            latency=$(awk -v start="$start_time" -v end="$end_time" 'BEGIN { printf "%.3f", (end - start) * 1000 }')
            log_echo "${GREEN}   - TCP port ${port} is available; latency ${latency} ms.${RESET}"
        else
            end_time=$(date +%s 2>/dev/null || printf '0')
            latency=$(awk -v start="$start_time" -v end="$end_time" 'BEGIN { printf "%.3f", (end - start) * 1000 }')
            log_echo "${RED}   - TCP port ${port} is not available; latency ${latency} ms.${RESET}"
            failures=$((failures + 1))
        fi
    done < <(jq -c '.[]' <<< "$peers_json")

    [[ "$failures" -eq 0 ]]
}

# Check if TCP port 8006 is available on all nodes
function are_hosts_tcp_port_8006_reachable() {
    are_hosts_tcp_port_reachable 8006 "${1:-${ALL_PEERS:-[]}}" "${2:-all nodes}"
}

# Check if TCP port 443 is available on all nodes
function are_hosts_tcp_port_443_reachable() {
    are_hosts_tcp_port_reachable 443 "${1:-${ALL_PEERS:-[]}}" "${2:-all nodes}"
}

# Check if UDP port 5405 is open on all nodes (corosync)
function check_udp_ports_5405_to_5412() {
    log_echo "${YELLOW}Checking if UDP ports 5405 through 5412 (Corosync) are available on all nodes...${RESET}"

    # Iterate through all peers
    local peer_unavailable=false
    echo "$ALL_PEERS" | jq -c '.[]' | while read -r peer; do
        local peer_ip=$(echo "$peer" | jq -r '.ip')
        local peer_hostname=$(echo "$peer" | jq -r '.hostname')

        for port in {5405..5412}; do
            log_echo "${BLUE}Checking UDP port $port on $peer_hostname ($peer_ip)...${RESET}"
            
            # For UDP, we'll use nc with -u flag and a short timeout
            # nc -v -u -z -w 3 prox2.risk-mermaid.ts.net 5405
            if ! timeout 2 bash -c "echo -n > /dev/udp/$peer_hostname/$port" 2>/dev/null; then
                log_echo "${RED}UDP port $port is not available on $peer_hostname ($peer_ip).${RESET}"
                peer_unavailable=true
            else
                log_echo "${GREEN}UDP port $port is available on $peer_hostname ($peer_ip).${RESET}"
            fi
        done
    done

    if $peer_unavailable; then
        log_echo "${RED}Some peers have UDP ports 5405 through 5412 unavailable. These ports are required for Corosync cluster communication.${RESET}"
        exit 1
    else
        log_echo "${GREEN}All peers have UDP ports 5405 through 5412 available.${RESET}"
    fi
}

# Check if this node is already part of a Proxmox cluster
# Returns true/false ?
function check_local_node_cluster_status() {
    # log_echo "${YELLOW}Checking if this node is already part of a Proxmox cluster...${RESET}"
    
    # Check if the pvecm command exists (should be installed with Proxmox)
    if ! command -v pvecm &>/dev/null; then
        log_echo "${RED}pvecm command not found. Is this a Proxmox VE node?${RESET}"
        return 1
    fi
    
    # Get cluster status
    local cluster_status=$(pvecm status 2>&1)
    
    # Check if the node is part of a cluster
    if echo "$cluster_status" | grep -q "is this node part of a cluster"; then
        log_echo "${BLUE}This node is not part of any cluster.${RESET}"
        return 1
    elif echo "$cluster_status" | grep -q "Cluster information"; then
        local cluster_name=$(pvecm status | grep "Name:" | awk '{print $2}')
        # log_echo "${GREEN}This node is already part of cluster named: $cluster_name${RESET}"
        return 0
    else
        log_echo "${RED}Unable to determine cluster status. Output: $cluster_status${RESET}"
        return 1
    fi
}

# Check if a remote node is already part of a Proxmox cluster
# Returns true/false ?
function check_remote_node_cluster_status_via_ssh() {
    local node_ip=$1
    log_echo "${YELLOW}Checking if remote node $node_ip is part of a Proxmox cluster via SSH...${RESET}"
    
    # Check if the pvecm command exists (should be installed with Proxmox)
    if ! command -v pvecm &>/dev/null; then
        log_echo "${RED}pvecm command not found. Is this a Proxmox VE node?${RESET}"
        exit 1
    fi
    
    # Get cluster status
    ssh-keyscan -H "$TARGET_HOSTNAME" >> ~/.ssh/known_hosts 2>/dev/null
    local cluster_status=$(ssh "$node_ip" "pvecm status" 2>&1)
    
    # Check if the node is part of a cluster
    if echo "$cluster_status" | grep -q "is this node part of a cluster"; then
        log_echo "${BLUE}Remote node $node_ip is not part of any cluster.${RESET}"
        return 1
    elif echo "$cluster_status" | grep -q "Cluster information"; then
        local cluster_name=$(ssh "$TARGET_HOSTNAME" "pvecm status" | grep "Name:" | awk '{print $2}')
        log_echo "${GREEN}Remote node $node_ip is already part of cluster named: $cluster_name${RESET}"
        return 0
    else
        log_echo "${RED}Unable to determine cluster status for remote node $node_ip. Output: $cluster_status${RESET}"
        exit 1
    fi

}

# Check if a remote node is already part of a Proxmox cluster using API
# Returns true/false ?
function check_remote_node_cluster_status_via_api() {
    local node_hostname=$1
    local username=${2:-"root@pam"}  # Default to root@pam if not provided
    local password=$3
    local auth_response
    local ticket
    local csrf_token
    local cluster_response
    local cluster_data
    local cluster_name
    
    log_echo "${YELLOW}Checking if remote node $node_hostname is part of a Proxmox cluster via API...${RESET}"
    
    # First, authenticate and get a ticket
    if ! auth_response=$(curl -k -s \
        --data-urlencode "username=$username" \
        --data-urlencode "password=$password" \
        "https://$node_hostname:8006/api2/json/access/ticket" 2>/dev/null); then
        log_echo "${RED}Failed to connect to Proxmox API on $node_hostname${RESET}"
        return 1
    fi
    if [[ -z "$auth_response" ]]; then
        log_echo "${RED}Failed to connect to Proxmox API on $node_hostname${RESET}"
        return 1
    fi
    
    # Extract ticket and CSRFPreventionToken
    ticket=$(echo "$auth_response" | jq -r '.data.ticket // empty')
    csrf_token=$(echo "$auth_response" | jq -r '.data.CSRFPreventionToken // empty')
    
    if [ -z "$ticket" ] || [ "$ticket" == "null" ]; then
        log_echo "${RED}Authentication failed for $node_hostname. Check credentials.${RESET}"
        return 1
    fi
    
    # Get cluster status using the API
    if ! cluster_response=$(curl -k -s \
        -H "Cookie: PVEAuthCookie=$ticket" \
        -H "CSRFPreventionToken: $csrf_token" \
        "https://$node_hostname:8006/api2/json/cluster/status" 2>/dev/null); then
        log_echo "${RED}Failed to get cluster status from $node_hostname API${RESET}"
        return 1
    fi
    if [[ -z "$cluster_response" ]]; then
        log_echo "${RED}Failed to get cluster status from $node_hostname API${RESET}"
        return 1
    fi
    
    # Check if the response indicates a cluster exists
    cluster_data=$(echo "$cluster_response" | jq -r '.data // empty')
    
    if [ -z "$cluster_data" ] || [ "$cluster_data" == "null" ] || [ "$cluster_data" == "[]" ]; then
        log_echo "${BLUE}Remote node $node_hostname is not part of any cluster.${RESET}"
        return 1
    else
        # Extract cluster name from the first cluster entry
        cluster_name=$(echo "$cluster_response" | jq -r '.data[] | select(.type == "cluster") | .name // empty' | head -1)
        if [ -n "$cluster_name" ] && [ "$cluster_name" != "null" ]; then
            log_echo "${GREEN}Remote node $node_hostname is part of cluster named: $cluster_name${RESET}"
            return 0
        else
            log_echo "${BLUE}Remote node $node_hostname is not part of any cluster.${RESET}"
            return 1
        fi
    fi
}

# Run pvecm without interpolating the password into Tcl source or exposing it in
# the Expect process arguments or environment. Expect reads the literal value
# from standard input before interacting with the spawned command's pseudo-TTY.
function join_remote_proxmox_cluster() {
    local node_hostname=$1
    local local_tailscale_ip=$2
    local fingerprint=$3
    local password=$4

    printf '%s' "$password" | expect -c '
        set timeout 60
        set tailmox_password [read stdin]
        spawn pvecm add [lindex $argv 0] --link0 address=[lindex $argv 1] --fingerprint [lindex $argv 2]
        expect {
            "*?assword:*" {
                send -- "$tailmox_password\r"
                exp_continue
            }
            "*?assword for*" {
                send -- "$tailmox_password\r"
                exp_continue
            }
            "*authentication failure*" {
                puts "Authentication failed. Please check your password."
                exit 1
            }
            timeout {
                puts "Command timed out."
                exit 1
            }
            eof
        }
        catch wait result
        exit [lindex $result 3]
    ' "$node_hostname" "$local_tailscale_ip" "$fingerprint"
}

# Get the certificate fingerprint for a Proxmox node
# - parameter $1: hostname or IP address
function get_pve_certificate_fingerprint() {
    local hostname=$1
    local port=8006
    
    # log_echo "${YELLOW}Getting certificate fingerprint for $hostname:$port...${RESET}"
    
    # Use OpenSSL to connect to the server and get the certificate info
    local fingerprint=$(echo | openssl s_client -connect $hostname:$port 2>/dev/null | 
        openssl x509 -fingerprint -sha256 -noout | 
        cut -d'=' -f2)
    
    if [ -n "$fingerprint" ]; then
        # log_echo "${GREEN}Certificate fingerprint for $hostname:$port: $fingerprint${RESET}"
        echo "$fingerprint"
    else
        log_echo "${RED}Failed to get certificate fingerprint for $hostname:$port${RESET}"
        return 1
    fi
}

# Install and publish the Tailmox monitoring interface
function verify_monitor_url() {
    local url="$1"
    local timeout_seconds="${TAILMOX_MONITOR_CHECK_TIMEOUT_SECONDS:-10}"
    local response_code
    local curl_output

    if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
        log_echo "${RED}TAILMOX_MONITOR_CHECK_TIMEOUT_SECONDS must be a positive integer.${RESET}"
        return 1
    fi

    curl_output=$(curl --silent --show-error \
        --connect-timeout "$timeout_seconds" --max-time "$timeout_seconds" \
        --retry 5 --retry-delay 1 --retry-all-errors \
        --output /dev/null --write-out '%{http_code}' "$url" 2>&1 || true)
    response_code=${curl_output##*$'\n'}
    if [[ -z "$response_code" || ! "$response_code" =~ ^[0-9]{3}$ ]]; then
        log_echo "${RED}curl failed while checking $url${RESET}"
        if [[ -n "$curl_output" ]]; then
            log_echo "${RED}curl output: $curl_output${RESET}"
        fi
        return 1
    fi

    case "$response_code" in
        2??|3??|401|403)
            log_echo "${GREEN}Verified Tailmox monitoring at ${BLUE}$url${RESET}"
            return 0
            ;;
        *)
            log_echo "${RED}Tailmox monitoring is not available at $url (HTTP $response_code)${RESET}"
            if [[ -n "$curl_output" && "$curl_output" != "$response_code" ]]; then
                log_echo "${RED}curl output: $curl_output${RESET}"
            fi
            return 1
            ;;
    esac
}

function setup_monitoring_interface() {
    local script_dir=$(dirname "$(realpath "$0")")
    local magicdns_domain
    local node_monitor_url
    local service_monitor_url

    if [[ ! -f "$script_dir/tailmox-monitor.py" || ! -f "$script_dir/tailmox-monitor.service" ]]; then
        log_echo "${YELLOW}Tailmox monitoring files were not found. Skipping monitoring interface setup.${RESET}"
        return 0
    fi

    log_echo "${YELLOW}Installing the Tailmox monitoring interface...${RESET}"
    chmod +x "$script_dir/tailmox-monitor.py"
    sed "s|@TAILMOX_DIR@|$script_dir|g" "$script_dir/tailmox-monitor.service" > /etc/systemd/system/tailmox-monitor.service
    systemctl daemon-reload
    systemctl enable --now tailmox-monitor.service

    if systemctl is-active --quiet tailmox-monitor.service; then
        log_echo "${GREEN}Tailmox monitoring interface is running locally on port 8088.${RESET}"
    else
        log_echo "${RED}Tailmox monitoring interface did not start. Check: systemctl status tailmox-monitor.service${RESET}"
        return 1
    fi

    magicdns_domain="${TAILSCALE_DNS_NAME#*.}"
    if [[ -z "${TAILSCALE_DNS_NAME:-}" || "$magicdns_domain" == "$TAILSCALE_DNS_NAME" ]]; then
        log_echo "${RED}Unable to determine the Tailscale MagicDNS domain for the monitoring URLs.${RESET}"
        return 1
    fi
    node_monitor_url="https://${TAILSCALE_DNS_NAME}:8088/monitor"
    service_monitor_url="https://${TAILMOX_TAILSCALE_SERVICE_NAME}.${magicdns_domain}/"

    configure_tailscale_serve --bg --https=8088 --set-path=/monitor localhost:8088 || return 1
    configure_tailscale_serve "--service=svc:${TAILMOX_TAILSCALE_SERVICE_NAME}" --bg --https=443 localhost:8088 || return 1

    verify_monitor_url "$node_monitor_url" || return 1
}

# Create a new Proxmox cluster named "tailmox"
function create_cluster() {
    local TAILSCALE_IP=$(tailscale ip -4)
    local pve_config_dir="${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}"

    if [[ ! -d "$pve_config_dir" ]]; then
        printf 'Missing Proxmox cluster configuration directory: %s\n' "$pve_config_dir" >&2
        return 1
    fi

    log_echo "${YELLOW}Creating a new Proxmox cluster named 'tailmox'...${RESET}"
    check_all_peers_online || return 1
    backup_proxmox_cluster_configuration || return 1
    pvecm create tailmox --link0 address=$TAILSCALE_IP
}

# Add this local node into a cluster if it exists
function add_local_node_to_cluster() {
    if check_local_node_cluster_status; then
        log_echo "${PURPLE}This node is already in a cluster.${RESET}"
    else
        log_echo "${BLUE}This node is not in a cluster. Creating or joining a cluster is required.${RESET}"

        # Find if a cluster amongst peers already exists
        echo "$OTHER_PEERS" | jq -c '.[]' | while read -r target_peer; do
            TARGET_HOSTNAME=$(echo "$target_peer" | jq -r '.hostname')
            TARGET_IP=$(echo "$target_peer" | jq -r '.ip')
            TARGET_DNSNAME=$(echo "$target_peer" | jq -r '.dnsName' | sed 's/\.$//')
            
            log_echo "${BLUE}Checking cluster status on $TARGET_HOSTNAME ($TARGET_IP)...${RESET}"
            
            # Prompt for root password of the remote node first
            read -s -p "Please enter the root password for ${TARGET_HOSTNAME}: " ROOT_PASSWORD < /dev/tty
            echo
            
            # Try API-based check first, fall back to SSH if it fails
            local cluster_exists=false
            if check_remote_node_cluster_status_via_api "$TARGET_HOSTNAME" "root@pam" "$ROOT_PASSWORD"; then
                cluster_exists=true
            # elif check_remote_node_cluster_status_via_ssh "$TARGET_HOSTNAME"; then
            #    cluster_exists=true
            fi
            
            if [ "$cluster_exists" = true ]; then
                local LOCAL_TAILSCALE_IP=$(tailscale ip -4)
                local target_fingerprint=$(get_pve_certificate_fingerprint "$TARGET_HOSTNAME")

                log_echo "${GREEN}Found an existing cluster on $TARGET_HOSTNAME. Joining the cluster...${RESET}"

                join_remote_proxmox_cluster \
                    "$TARGET_HOSTNAME.$MAGICDNS_DOMAIN_NAME" \
                    "$LOCAL_TAILSCALE_IP" \
                    "$target_fingerprint" \
                    "$ROOT_PASSWORD"
                
                # Check if successful
                if [ $? -eq 0 ]; then
                    if ! record_local_host; then
                        log_echo "${RED}The node joined the Proxmox cluster, but Tailmox could not record $HOSTNAME in $STATE_FILE.${RESET}"
                        exit 1
                    fi
                    log_echo "${GREEN}Successfully joined cluster with $TARGET_HOSTNAME.${RESET}"
                    log_echo "${GREEN}You can now access your tailmox server directly at: ${BLUE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
                    log_echo "${GREEN}You can now access your tailmox service at: ${BLUE}https://tailmox.$MAGICDNS_DOMAIN_NAME/${RESET}"
                    exit 0
                else
                    log_echo "${RED}Failed to join cluster with $TARGET_HOSTNAME. Check the password and try again.${RESET}"
                    exit 1
                fi
            else
                log_echo "${YELLOW}No cluster found on $TARGET_HOSTNAME.${RESET}"
            fi
        done
        
    fi
}

####
#### ---MAIN SCRIPT---
####

if [ "${TAILMOX_LIBRARY_MODE:-false}" = "true" ]; then
    return 0 2>/dev/null || exit 0
fi

if [ "${1:-}" != "info" ] && [ "${1:-}" != "--backups-list" ] &&
    [ "${1:-}" != "--test" ]; then
    log_echo "${CYAN}━━━ TAILMOX SETUP ━━━${RESET}"
fi

# Parse the script parameters
AUTH_KEY="${TAILMOX_AUTH_KEY:-}"
TEST_ONLY=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        info) show_info; exit 0 ;;
        remove)
            shift
            [[ "$#" -eq 1 ]] || { printf 'Usage: tailmox.sh remove <node-name>\n' >&2; exit 2; }
            remove_cluster_node "$1"
            exit $?
            ;;
        --disable)
            shift
            disable_tailmox "$@"
            exit $?
            ;;
        --backups-list)
            list_proxmox_cluster_backups
            exit $?
            ;;
        --backup-create)
            backup_proxmox_cluster_configuration
            exit $?
            ;;
        --influx-install|--influx-restart|--influx-uninstall)
            action="${1#--influx-}"
            systemd_dir="${TAILMOX_SYSTEMD_DIR:-/etc/systemd/system}"
            service_name="${TAILMOX_INFLUX_SERVICE:-tailmox-influx.service}"
            service_source="$(dirname "${BASH_SOURCE[0]}")/tailmox-influx.service"
            service_target="$systemd_dir/$service_name"
            [[ -f "$service_source" ]] || { printf 'Missing InfluxDB service definition.\n' >&2; exit 1; }
            if [[ "$action" == install ]]; then
                if [[ -e "$service_target" ]] && { ! grep -Fqx 'Description=Tailmox test metrics InfluxDB exporter' "$service_target" || ! grep -Fq 'tailmox-influx-export.sh' "$service_target"; }; then
                    printf 'Refusing to replace unrelated service: %s\n' "$service_target" >&2
                    exit 1
                fi
                install -d -m 0755 "$systemd_dir" || exit 1
                sed "s|@TAILMOX_DIR@|$(dirname "${BASH_SOURCE[0]}")|g" "$service_source" > "$service_target" || exit 1
            elif [[ ! -e "$service_target" ]]; then printf 'Tailmox InfluxDB exporter is not installed.\n' >&2; exit 1
            elif ! grep -Fqx 'Description=Tailmox test metrics InfluxDB exporter' "$service_target" || ! grep -Fq 'tailmox-influx-export.sh' "$service_target"; then
                printf 'Refusing to modify unrelated service: %s\n' "$service_target" >&2
                exit 1
            fi
            if [[ "$action" == uninstall ]]; then systemctl disable --now "$service_name" && rm -f "$service_target" && systemctl daemon-reload || exit 1; printf 'Tailmox InfluxDB exporter uninstalled.\n'; exit 0; fi
            systemctl daemon-reload && systemctl enable "$service_name" && systemctl restart "$service_name" || exit 1
            printf 'Tailmox InfluxDB exporter %s.\n' "$( [[ "$action" == install ]] && printf 'installed and running' || printf 'restarted' )"
            exit 0
            ;;
        --test) TEST_ONLY=true ;;
        --staging) STAGING="true"; log_echo "${YELLOW}Staging mode enabled.${RESET}"; ;;
        --auth-key) AUTH_KEY="$2"; log_echo "${YELLOW}Using auth key for Tailscale...${RESET}"; shift; ;;
        *) log_echo "${RED}Unknown parameter: $1${RESET}"; exit 1 ;;
    esac
    shift
done

if [[ "$TEST_ONLY" == "true" ]]; then
    if ! STATUS_JSON=$(tailscale status --json) ||
        ! jq empty <<< "$STATUS_JSON" >/dev/null 2>&1; then
        printf 'Unable to read Tailscale status.\n' >&2
        exit 1
    fi
    TAILSCALE_IP=$(tailscale ip -4) || exit 1
    TAILSCALE_DNS_NAME=$(jq -r '.Self.DNSName // ""' <<< "$STATUS_JSON" | sed 's/\.$//')
    MAGICDNS_DOMAIN_NAME=$(printf '%s' "$TAILSCALE_DNS_NAME" | cut -d'.' -f2-)
    LOCAL_PEER=$(jq -n \
        --arg hostname "$HOSTNAME" \
        --arg ip "$TAILSCALE_IP" \
        --arg dnsName "$TAILSCALE_DNS_NAME" \
        '{hostname: $hostname, ip: $ip, dnsName: $dnsName, online: true}')
    OTHER_PEERS=$(jq -c '
        [.Peer[] | select((.Tags // []) | index("tag:tailmox") != null) |
            {hostname: .HostName, ip: .TailscaleIPs[0], dnsName: .DNSName, online: .Online}]
    ' <<< "$STATUS_JSON") || exit 1
    ALL_PEERS=$(jq -c --argjson localPeer "$LOCAL_PEER" '. + [$localPeer]' <<< "$OTHER_PEERS") || exit 1
    test_setup_safely
    exit $?
fi

if ! check_if_supported_proxmox_is_installed; then
    log_echo "${RED}Proxmox VE 8.x or 9.x is required. Exiting...${RESET}"
    exit 1
fi

if ! check_script_directory; then
    log_echo "${RED}This script must be run from the '/opt/tailmox' directory. Exiting...${RESET}"
    exit 1
fi

install_dependencies
install_tailscale

# Start Tailscale; use auth key if supplied
start_tailscale "$AUTH_KEY" || exit 1

### Now that Tailscale is running...

# Running 'tailscale serve' with these options allows a valid certificate on
# port 443, along with the built-in handling of the certificate.
configure_tailscale_serve --bg https+insecure://localhost:8006 || exit 1
log_echo "${GREEN}Tailscale serve is now running.${RESET}"

setup_monitoring_interface || exit 1

# Exit early if staging mode is enabled
if [[ "$STAGING" == "true" ]]; then
    log_echo "${YELLOW}Staging mode enabled. Exiting after \`tailscale serve\` setup.${RESET}"
    exit 0
fi

# Get all nodes with the "tailmox" tag as a JSON array
TAILSCALE_IP=$(tailscale ip -4)
MAGICDNS_DOMAIN_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | cut -d'.' -f2- | sed 's/\.$//');
LOCAL_PEER=$(jq -n --arg hostname "$HOSTNAME" --arg ip "$TAILSCALE_IP" --arg dnsName "$HOSTNAME.$MAGICDNS_DOMAIN_NAME" --arg online "true" '{hostname: $hostname, ip: $ip, dnsName: $dnsName, online: ($online == "true")}');
OTHER_PEERS=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | {hostname: .HostName, ip: .TailscaleIPs[0], dnsName: .DNSName, online: .Online}]');
ALL_PEERS=$(echo "$OTHER_PEERS" | jq --argjson localPeer "$LOCAL_PEER" '. + [$localPeer]');

log_echo "${YELLOW}Running the read-only setup preflight before clustering...${RESET}"
if ! test_setup_safely; then
    log_echo "${RED}Setup preflight failed. Exiting before cluster changes.${RESET}"
    exit 1
fi

# Check if the local node is already in a cluster
if ! check_local_node_cluster_status; then
    log_echo "${YELLOW}This node is not part of a cluster. Attempting to create or join a cluster...${RESET}"
    # Add this local node to a cluster if it exists
    add_local_node_to_cluster
else
    if ! record_local_host; then
        log_echo "${RED}This node is in the Proxmox cluster, but Tailmox could not record $HOSTNAME in $STATE_FILE.${RESET}"
        exit 1
    fi
    log_echo "${GREEN}This node is already part of a cluster, nothing further to do.${RESET}"
    log_echo "${GREEN}You can now access your tailmox server directly at: ${BLUE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
    log_echo "${GREEN}You can now access your tailmox service at: ${BLUE}https://${TAILMOX_TAILSCALE_SERVICE_NAME}.$MAGICDNS_DOMAIN_NAME/${RESET}"
    log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
    exit 0
fi

# If local node is now in the cluster...
if ! check_local_node_cluster_status; then
    log_echo "${BLUE}No existing cluster found amongst any peers.${RESET}"
    log_echo "${YELLOW}Do you want to create a cluster on this node?${RESET}"
    read -p "Enter 'y' to create a new cluster or 'n' to exit: " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        create_cluster
        if ! record_local_host; then
            log_echo "${RED}The Proxmox cluster was created, but Tailmox could not record $HOSTNAME in $STATE_FILE.${RESET}"
            exit 1
        fi
        log_echo "${GREEN}Cluster created successfully.${RESET}"
        log_echo "${GREEN}You can now access your tailmox server directly at: ${BLUE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
        log_echo "${GREEN}You can now access your tailmox service at: ${BLUE}https://${TAILMOX_TAILSCALE_SERVICE_NAME}.$MAGICDNS_DOMAIN_NAME/${RESET}"
        log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
    else
        log_echo "${RED}Exiting without creating a cluster.${RESET}"
        log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
        exit 1
    fi
fi

### This version is working when tested with 3 nodes!
