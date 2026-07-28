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
#   --auth-key <key>    Use the provided Tailscale auth key for login
#
# Description:
#   By default, this script starts a tailnet-only web terminal. The installer
#   itself runs inside that terminal.
#
# Requirements:
#   - Must be run as root from /opt/tailmox
#   - Proxmox VE 8.x or 9.x
#   - Internet access for package installation and Tailscale login
###############################################################################

# Source color definitions
source "$(dirname "${BASH_SOURCE[0]}")/.colors.sh"

# Define log file. Read-only commands must not create or rotate host log files.
TAILMOX_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TAILMOX_EARLY_DRY_RUN=false
for tailmox_argument in "$@"; do
    if [[ "$tailmox_argument" == "--dry-run" ||
        "$tailmox_argument" == "--backups-list" ]]; then
        TAILMOX_EARLY_DRY_RUN=true
        break
    fi
done

if [[ "$TAILMOX_EARLY_DRY_RUN" == "true" ]]; then
    LOG_DIR=""
    LOG_FILE=/dev/null
else
    LOG_DIR="${TAILMOX_LOG_DIR:-/var/log}"
    LOG_FILE="$LOG_DIR/tailmox.log"
fi

# TMOX maps to 8669 on a telephone keypad.
TAILMOX_WEB_PORT="${TAILMOX_WEB_PORT:-8669}"
TAILMOX_WEB_BACKEND_PORT="${TAILMOX_WEB_BACKEND_PORT:-8670}"
TAILMOX_MONITOR_SSE_PORT="${TAILMOX_MONITOR_SSE_PORT:-8671}"
TAILMOX_WEB_SERVICE="${TAILMOX_WEB_SERVICE:-tailmox-web.service}"
TAILMOX_WEB_ROOT="${TAILMOX_WEB_ROOT:-/var/lib/tailmox/web}"
TAILMOX_WEB_ASSET_DIR="${TAILMOX_WEB_ASSET_DIR:-$TAILMOX_SCRIPT_DIR/web}"
TAILMOX_SYSTEMD_DIR="${TAILMOX_SYSTEMD_DIR:-/etc/systemd/system}"
TAILMOX_EXISTING_CLUSTER_BACKUP_DIR="${TAILMOX_EXISTING_CLUSTER_BACKUP_DIR:-/var/backups/tailmox}"
TAILMOX_CLUSTER_BACKUP_DIR="${TAILMOX_CLUSTER_BACKUP_DIR:-/var/backups/tailmox}"
TAILMOX_PVE_CONFIG_DIR="${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}"
TAILMOX_COROSYNC_CONFIG_DIR="${TAILMOX_COROSYNC_CONFIG_DIR:-/etc/corosync}"
TAILMOX_COROSYNC_COMMAND="${TAILMOX_COROSYNC_COMMAND:-corosync}"
TAILMOX_HOSTS_FILE="${TAILMOX_HOSTS_FILE:-/etc/hosts}"
TAILMOX_CLUSTER_STATE_FILE="${TAILMOX_CLUSTER_STATE_FILE:-$TAILMOX_PVE_CONFIG_DIR/tailmox/state.json}"

# Create and rotate logs only during real setup.
if [[ "$TAILMOX_EARLY_DRY_RUN" != "true" ]]; then
    mkdir -p "$LOG_DIR"

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
    
    # The web launcher stays quiet so it prints only its status and URL.
    if [[ "${TAILMOX_CONSOLE_OUTPUT:-true}" == "true" ]]; then
        echo -e "$message"
    fi
    
    # Output to log file without colors, with timestamp
    echo "[$timestamp] $(echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOG_FILE"
}

# Visually separate the major phases of the read-only setup test.
function log_test_section() {
    local section_number="$1"
    local section_title="$2"

    log_echo ""
    log_echo "${CYAN}━━━ ${section_number}. ${section_title} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
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
    if [[ "$script_dir" != *"/opt/tailmox"* ]]; then
        log_echo "${RED}This script must be run from the '/opt/tailmox' directory.${RESET}"
        exit 1
    fi
    log_echo "${GREEN}Running from the correct directory: $script_dir${RESET}"
}

# Install dependencies
function install_dependencies() {
    log_echo "${YELLOW}Checking for required dependencies...${RESET}"

    local dependencies=(curl expect git jq)
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log_echo "${YELLOW}$dep not found. Installing...${RESET}"
            apt update -qq || return 1
            DEBIAN_FRONTEND=noninteractive apt install "$dep" -y || return 1
        else
            :
        fi
    done

    install_ttyd
}

# Debian 12 does not ship ttyd, so install the upstream static binary and
# verify it against the checksum published with ttyd 1.7.7.
function install_ttyd() {
    local architecture
    local expected_sha256
    local ttyd_asset
    local ttyd_download
    local ttyd_version="1.7.7"

    if [[ -x /usr/local/bin/ttyd ]]; then
        return 0
    fi

    architecture=$(uname -m)
    case "$architecture" in
        x86_64)
            ttyd_asset="ttyd.x86_64"
            expected_sha256="8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55"
            ;;
        aarch64|arm64)
            ttyd_asset="ttyd.aarch64"
            expected_sha256="b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165"
            ;;
        *)
            log_echo "${RED}No supported ttyd build is available for $architecture.${RESET}"
            return 1
            ;;
    esac

    ttyd_download=$(mktemp /tmp/tailmox-ttyd.XXXXXX) || return 1
    if ! curl -fsSL \
        "https://github.com/tsl0922/ttyd/releases/download/$ttyd_version/$ttyd_asset" \
        -o "$ttyd_download"; then
        rm -f "$ttyd_download"
        return 1
    fi

    if ! printf '%s  %s\n' "$expected_sha256" "$ttyd_download" | sha256sum --check --status; then
        log_echo "${RED}The downloaded ttyd checksum did not match.${RESET}"
        rm -f "$ttyd_download"
        return 1
    fi

    if ! install -m 0755 "$ttyd_download" /usr/local/bin/ttyd; then
        rm -f "$ttyd_download"
        return 1
    fi

    rm -f "$ttyd_download"
}

# Publish a metadata-only inventory for the dashboard. Backup contents and
# absolute host paths are never copied into the web root.
function refresh_web_backup_inventory() {
    local backup_dir
    local backup_path
    local created_at
    local filename
    local generated_at
    local integrity
    local inventory_tmp
    local previous_backup_dir=""
    local records_file
    local size_bytes
    local type
    local -a backup_dirs=(
        "$TAILMOX_CLUSTER_BACKUP_DIR"
        "$TAILMOX_EXISTING_CLUSTER_BACKUP_DIR"
    )

    if [[ ! -d "$TAILMOX_WEB_ROOT" ]]; then
        return 1
    fi

    records_file=$(mktemp "${TMPDIR:-/tmp}/tailmox-backups.XXXXXX") || return 1
    inventory_tmp=$(mktemp "$TAILMOX_WEB_ROOT/.backups.json.XXXXXX") || {
        rm -f "$records_file"
        return 1
    }

    for backup_dir in "${backup_dirs[@]}"; do
        if [[ "$backup_dir" == "$previous_backup_dir" ]]; then
            continue
        fi
        previous_backup_dir="$backup_dir"

        if [[ ! -d "$backup_dir" ]]; then
            continue
        fi

        while IFS= read -r -d '' backup_path; do
            filename=$(basename "$backup_path")
            if [[ "$filename" == proxmox-cluster-*.tar.gz ]]; then
                type="cluster"
                if tar -tzf "$backup_path" >/dev/null 2>&1; then
                    integrity="valid"
                else
                    integrity="invalid"
                fi
            elif [[ "$filename" == corosync-*.conf ]]; then
                type="corosync"
                if [[ -s "$backup_path" ]]; then
                    integrity="valid"
                else
                    integrity="invalid"
                fi
            else
                continue
            fi

            if [[ "$filename" =~ ([0-9]{8}T[0-9]{6}Z) ]]; then
                created_at="${BASH_REMATCH[1]}"
            else
                continue
            fi

            if ! size_bytes=$(stat -c '%s' "$backup_path" 2>/dev/null); then
                size_bytes=$(stat -f '%z' "$backup_path" 2>/dev/null) || continue
            fi

            if ! jq -nc \
                --arg type "$type" \
                --arg filename "$filename" \
                --arg createdAt "$created_at" \
                --argjson sizeBytes "$size_bytes" \
                --arg integrity "$integrity" \
                '{
                    type: $type,
                    filename: $filename,
                    createdAt: $createdAt,
                    sizeBytes: $sizeBytes,
                    integrity: $integrity
                }' >> "$records_file"; then
                rm -f "$records_file" "$inventory_tmp"
                return 1
            fi
        done < <(
            find -P "$backup_dir" -maxdepth 1 -type f \
                \( -name 'proxmox-cluster-*.tar.gz' -o -name 'corosync-*.conf' \) \
                -print0
        )
    done

    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if ! jq -s --arg generatedAt "$generated_at" \
        '{
            generatedAt: $generatedAt,
            backups: (sort_by(.createdAt) | reverse)
        }' "$records_file" > "$inventory_tmp" ||
        ! chmod 0644 "$inventory_tmp" ||
        ! mv "$inventory_tmp" "$TAILMOX_WEB_ROOT/backups.json"; then
        rm -f "$records_file" "$inventory_tmp"
        return 1
    fi

    rm -f "$records_file"
    return 0
}

# Install the static dashboard separately from the root-only backup directory.
function install_web_dashboard() {
    local asset

    for asset in index.html tailmox.css tailmox.js; do
        if [[ ! -f "$TAILMOX_WEB_ASSET_DIR/$asset" ]]; then
            log_echo "${RED}Missing dashboard asset: $TAILMOX_WEB_ASSET_DIR/$asset${RESET}"
            return 1
        fi
    done

    if ! install -d -m 0755 "$TAILMOX_WEB_ROOT"; then
        log_echo "${RED}Unable to create the Tailmox dashboard directory.${RESET}"
        return 1
    fi

    for asset in index.html tailmox.css tailmox.js; do
        if ! install -m 0644 "$TAILMOX_WEB_ASSET_DIR/$asset" "$TAILMOX_WEB_ROOT/$asset"; then
            log_echo "${RED}Unable to install the Tailmox dashboard assets.${RESET}"
            return 1
        fi
    done

    if ! refresh_web_backup_inventory; then
        log_echo "${RED}Unable to build the Tailmox backup inventory.${RESET}"
        return 1
    fi
}

# Start the persistent localhost terminal and expose it alongside the dashboard
# only through Tailscale.
function start_web_terminal() {
    local script_dir
    local dns_name
    local service_source
    local service_target="$TAILMOX_SYSTEMD_DIR/$TAILMOX_WEB_SERVICE"

    script_dir="$TAILMOX_SCRIPT_DIR"
    service_source="$script_dir/tailmox-web.service"

    if [[ ! -f "$service_source" ]]; then
        log_echo "${RED}Missing web service definition: $service_source${RESET}"
        return 1
    fi

    if [[ -e "$service_target" ]] &&
        grep -Fqx 'Description=Tailmox web terminal' "$service_target" &&
        grep -Fq '/tailmox-web-terminal' "$service_target" &&
        systemctl is-active --quiet "$TAILMOX_WEB_SERVICE" >>"$LOG_FILE" 2>&1; then
        dns_name=$(tailscale status --json |
            jq -r '.Self.DNSName // empty' |
            sed 's/\.$//')
        if [[ -z "$dns_name" ]]; then
            log_echo "${RED}The Tailmox web server is running, but its Tailscale MagicDNS name could not be determined.${RESET}"
            return 1
        fi

        printf 'Tailmox web server is already running. %bhttps://%s:%s/%b\n' \
            "$BLUE" "$dns_name" "$TAILMOX_WEB_PORT" "$RESET"
        return 0
    fi

    if ! install_web_dashboard; then
        return 1
    fi

    if ! install -m 0644 "$service_source" "$service_target"; then
        log_echo "${RED}Unable to install the Tailmox web service.${RESET}"
        return 1
    fi

    if ! systemctl daemon-reload >>"$LOG_FILE" 2>&1 ||
        ! systemctl enable "$TAILMOX_WEB_SERVICE" >>"$LOG_FILE" 2>&1 ||
        ! systemctl restart "$TAILMOX_WEB_SERVICE" >>"$LOG_FILE" 2>&1; then
        log_echo "${RED}Unable to start the Tailmox web terminal service.${RESET}"
        return 1
    fi

    if ! tailscale serve --bg --yes --https="$TAILMOX_WEB_PORT" \
        --set-path=/ "$TAILMOX_WEB_ROOT" >>"$LOG_FILE" 2>&1 ||
        ! tailscale serve --bg --yes --https="$TAILMOX_WEB_PORT" \
            --set-path=/terminal \
            "http://127.0.0.1:$TAILMOX_WEB_BACKEND_PORT" >>"$LOG_FILE" 2>&1 ||
        ! tailscale serve --bg --yes --https="$TAILMOX_WEB_PORT" \
            --set-path=/monitor \
            "http://127.0.0.1:$TAILMOX_MONITOR_SSE_PORT" >>"$LOG_FILE" 2>&1; then
        log_echo "${RED}Unable to expose the Tailmox dashboard through Tailscale Serve.${RESET}"
        return 1
    fi

    dns_name=$(tailscale status --json |
        jq -r '.Self.DNSName // empty' |
        sed 's/\.$//')
    if [[ -z "$dns_name" ]]; then
        log_echo "${RED}Unable to determine this host's Tailscale MagicDNS name.${RESET}"
        return 1
    fi

    printf 'Tailmox web server started. %bhttps://%s:%s/%b\n' \
        "$BLUE" "$dns_name" "$TAILMOX_WEB_PORT" "$RESET"
}

# Stop only the Tailmox-owned web service and its dedicated Tailscale listener.
function stop_web_terminal() {
    local service_target="$TAILMOX_SYSTEMD_DIR/$TAILMOX_WEB_SERVICE"

    if [[ -e "$service_target" ]] &&
        { ! grep -Fqx 'Description=Tailmox web terminal' "$service_target" ||
          ! grep -Fq '/tailmox-web-terminal' "$service_target"; }; then
        printf 'Refusing to stop unrelated service: %s\n' "$service_target" >&2
        return 1
    fi

    if ! tailscale serve --https="$TAILMOX_WEB_PORT" off >>"$LOG_FILE" 2>&1; then
        printf 'Unable to stop the Tailmox Tailscale Serve listener.\n' >&2
        return 1
    fi

    if [[ -e "$service_target" ]] &&
        ! systemctl disable --now "$TAILMOX_WEB_SERVICE" >>"$LOG_FILE" 2>&1; then
        printf 'The Tailmox listener stopped, but the web terminal service did not.\n' >&2
        return 1
    fi

    printf 'Tailmox web server stopped.\n'
}

# Install Tailscale if it is not already installed
function install_tailscale() {
    if ! command -v tailscale &>/dev/null; then
        log_echo "${YELLOW}Tailscale not found. Installing...${RESET}"
        
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
            exit 1
        fi
    else
        # log_echo "${GREEN}Tailscale is already installed.${RESET}"
        :
    fi
}

# Verify the connected local node has the identity required by Tailmox.
function verify_local_tailmox_tag() {
    local status_json

    if ! status_json=$(tailscale status --json 2>/dev/null) ||
        ! printf '%s\n' "$status_json" |
            jq -e '
                .BackendState == "Running"
                and (.Self | type == "object")
                and ((.Self.Tags // []) | index("tag:tailmox") != null)
            ' >/dev/null 2>&1; then
        log_echo "${RED}This device is not connected with the required tag:tailmox identity, or Tailscale returned incomplete status. Assign the tag with the Tailscale API, admin console, or auth key before running Tailmox.${RESET}"
        return 1
    fi
}

# Bring up Tailscale
function start_tailscale() {
    local auth_key="$1"
    local status_json

    if status_json=$(tailscale status --json 2>/dev/null) &&
        printf '%s\n' "$status_json" |
            jq -e '.BackendState == "Running"' >/dev/null 2>&1; then
        log_echo "${GREEN}Tailscale is already connected; preserving its existing login and tags.${RESET}"
    else
        log_echo "${GREEN}Tailscale is not connected. Starting login...${RESET}"

        if [ -n "$auth_key" ]; then
            # Use the provided auth key. Tags are managed by the key or API.
            if ! tailscale up --auth-key="$auth_key"; then
                log_echo "${RED}Failed to start Tailscale.${RESET}"
                return 1
            fi
        else
            # Fall back to interactive authentication.
            if ! tailscale up; then
                log_echo "${RED}Failed to start Tailscale.${RESET}"
                return 1
            fi
        fi
    fi

    # Retrieve the assigned Tailscale IPv4 address
    local TAILSCALE_IP=""
    while [ -z "$TAILSCALE_IP" ]; do
        log_echo "${YELLOW}Waiting for Tailscale to come online...${RESET}"
        sleep 1
        TAILSCALE_IP=$(tailscale ip -4)
    done

    TAILSCALE_DNS_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')

    # Staging and clustering must stop before configuring Tailscale Serve unless
    # the post-login local identity is exactly the Tailmox tag.
    if ! verify_local_tailmox_tag; then
        return 1
    fi

    log_echo "${GREEN}This host's Tailscale IPv4 address: $TAILSCALE_IP ${RESET}"
    log_echo "${GREEN}This host's Tailscale MagicDNS name: $TAILSCALE_DNS_NAME ${RESET}"
}

# Check if all peers with the "tailmox" tag are online
function check_all_peers_online() {
    log_echo "${YELLOW}Checking if all Tailmox peers are online...${RESET}"

    local status_json
    local peers_data
    local peer_count
    local offline_peers

    # Fail closed if Tailscale status cannot be retrieved or does not contain
    # the peer object expected by the checks below.
    if ! status_json=$(tailscale status --json 2>/dev/null); then
        log_echo "${RED}Unable to retrieve Tailscale peer status. No cluster changes will be made.${RESET}"
        return 1
    fi

    if ! printf '%s\n' "$status_json" | jq -e '
        (.BackendState == "Running")
        and ((.Self | type) == "object")
        and (.Self.Online == true)
        and ((.Self.Tags // []) | index("tag:tailmox") != null)
        and ((.Peer | type) == "object")
    ' >/dev/null 2>&1; then
        log_echo "${RED}The local Tailscale host is not online with the exact tag:tailmox identity, or status data is incomplete. No cluster changes will be made.${RESET}"
        return 1
    fi

    # Match the exact Tailmox tag. A substring match could accidentally include
    # a differently scoped tag such as "tag:tailmox-test".
    if ! peers_data=$(printf '%s\n' "$status_json" | jq -c '[
        .Peer[]
        | select((.Tags // []) | index("tag:tailmox"))
        | {hostname: .HostName, online: .Online}
    ]'); then
        log_echo "${RED}Unable to parse Tailscale peer status. No cluster changes will be made.${RESET}"
        return 1
    fi

    # Missing hostnames or non-boolean online states are unsafe to interpret.
    if ! printf '%s\n' "$peers_data" | jq -e '
        all(.[];
            ((.hostname | type) == "string")
            and (.hostname | length > 0)
            and ((.online | type) == "boolean")
        )
    ' >/dev/null 2>&1; then
        log_echo "${RED}One or more Tailmox peers have incomplete status data. No cluster changes will be made.${RESET}"
        return 1
    fi

    peer_count=$(printf '%s\n' "$peers_data" | jq -r 'length')
    if [ "$peer_count" -eq 0 ]; then
        log_echo "${YELLOW}No existing Tailmox peers were found. Bootstrap may proceed.${RESET}"
        return 0
    fi

    offline_peers=$(printf '%s\n' "$peers_data" | jq -r '
        [.[] | select(.online != true) | .hostname] | join(", ")
    ')
    if [ -n "$offline_peers" ]; then
        log_echo "${RED}Not all Tailmox peers are online. Offline peers: $offline_peers. No cluster changes will be made.${RESET}"
        return 1
    fi

    log_echo "${GREEN}All $peer_count Tailmox peers are registered as online in Tailscale.${RESET}"
    return 0
}

# Re-run the peer check immediately before any command that changes Proxmox
# cluster membership or creates Corosync configuration. The earlier preflight
# checks are not sufficient on their own because a peer can go offline while
# the remaining checks or interactive prompts are in progress.
function require_all_peers_online_before_cluster_change() {
    if ! check_all_peers_online; then
        log_echo "${RED}Cluster change blocked because not all Tailmox peers are confirmed online.${RESET}"
        return 1
    fi

    return 0
}

# Archive the local files that Proxmox cluster creation and joining can modify.
# The archive must be complete before Tailmox invokes a mutating pvecm command.
function backup_proxmox_cluster_configuration() {
    local backup_timestamp
    local backup_archive
    local backup_suffix=0
    local temporary_archive
    local source_path
    local -a backup_sources=()
    local -a archive_sources=()

    for source_path in \
        "$TAILMOX_PVE_CONFIG_DIR" \
        "$TAILMOX_COROSYNC_CONFIG_DIR" \
        "$TAILMOX_HOSTS_FILE"; do
        if [[ -e "$source_path" ]]; then
            backup_sources+=("$source_path")
            archive_sources+=("${source_path#/}")
        fi
    done

    if [[ ! -d "$TAILMOX_PVE_CONFIG_DIR" ]]; then
        log_echo "${RED}Proxmox configuration directory $TAILMOX_PVE_CONFIG_DIR is unavailable. No cluster changes will be made.${RESET}"
        return 1
    fi

    if ! mkdir -p -m 0700 "$TAILMOX_CLUSTER_BACKUP_DIR"; then
        log_echo "${RED}Unable to create cluster backup directory $TAILMOX_CLUSTER_BACKUP_DIR. No cluster changes will be made.${RESET}"
        return 1
    fi

    backup_timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    backup_archive="$TAILMOX_CLUSTER_BACKUP_DIR/proxmox-cluster-${backup_timestamp}-$$.tar.gz"
    while [[ -e "$backup_archive" || -e "${backup_archive}.tmp" ]]; do
        backup_suffix=$((backup_suffix + 1))
        backup_archive="$TAILMOX_CLUSTER_BACKUP_DIR/proxmox-cluster-${backup_timestamp}-$$-${backup_suffix}.tar.gz"
    done
    temporary_archive="${backup_archive}.tmp"

    if ! (umask 077; tar -czf "$temporary_archive" -C / "${archive_sources[@]}"); then
        rm -f "$temporary_archive"
        log_echo "${RED}Unable to archive the current Proxmox cluster configuration. No cluster changes will be made.${RESET}"
        return 1
    fi

    if ! chmod 0600 "$temporary_archive" || ! mv "$temporary_archive" "$backup_archive"; then
        rm -f "$temporary_archive"
        log_echo "${RED}Unable to finalize the Proxmox cluster configuration archive. No cluster changes will be made.${RESET}"
        return 1
    fi

    TAILMOX_LAST_CLUSTER_BACKUP="$backup_archive"
    if [[ -d "$TAILMOX_WEB_ROOT" ]] && ! refresh_web_backup_inventory; then
        log_echo "${YELLOW}The backup succeeded, but the dashboard inventory could not be refreshed.${RESET}"
    fi
    log_echo "${GREEN}Archived the current Proxmox cluster configuration at $backup_archive.${RESET}"
    return 0
}

# List the private configuration backups created by Tailmox. Only regular
# files with Tailmox-controlled backup names are included.
function list_tailmox_configuration_backups() {
    local backup_dir
    local backup_path
    local filename
    local integrity
    local previous_backup_dir=""
    local size_bytes
    local type
    local -a backup_dirs=(
        "$TAILMOX_CLUSTER_BACKUP_DIR"
        "$TAILMOX_EXISTING_CLUSTER_BACKUP_DIR"
    )
    local -a backup_paths=()

    shopt -s nullglob
    for backup_dir in "${backup_dirs[@]}"; do
        if [[ "$backup_dir" == "$previous_backup_dir" ]]; then
            continue
        fi
        previous_backup_dir="$backup_dir"

        if [[ ! -d "$backup_dir" ]]; then
            continue
        fi
        if [[ ! -r "$backup_dir" ]]; then
            shopt -u nullglob
            printf 'Unable to read Tailmox backup directory: %s\n' "$backup_dir" >&2
            return 1
        fi

        for backup_path in \
            "$backup_dir"/proxmox-cluster-*.tar.gz \
            "$backup_dir"/corosync-*.conf; do
            if [[ -f "$backup_path" && ! -L "$backup_path" ]]; then
                backup_paths+=("$backup_path")
            fi
        done
    done
    shopt -u nullglob

    if [[ "${#backup_paths[@]}" -eq 0 ]]; then
        printf 'No Tailmox configuration backups found.\n'
        return 0
    fi

    printf '%-9s %12s %-9s %s\n' "TYPE" "SIZE (BYTES)" "INTEGRITY" "FILE"
    while IFS= read -r backup_path; do
        filename=$(basename "$backup_path")
        if [[ "$filename" == proxmox-cluster-*.tar.gz ]]; then
            type="cluster"
            if tar -tzf "$backup_path" >/dev/null 2>&1; then
                integrity="valid"
            else
                integrity="invalid"
            fi
        else
            type="corosync"
            if [[ -s "$backup_path" ]]; then
                integrity="valid"
            else
                integrity="invalid"
            fi
        fi

        if ! size_bytes=$(stat -c '%s' "$backup_path" 2>/dev/null); then
            size_bytes=$(stat -f '%z' "$backup_path" 2>/dev/null) || size_bytes="unknown"
        fi

        printf '%-9s %12s %-9s %s\n' \
            "$type" "$size_bytes" "$integrity" "$backup_path"
    done < <(printf '%s\n' "${backup_paths[@]}" | sort)

    return 0
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

# Require an explicit acknowledgement before continuing after an ICMP warning.
function confirm_icmp_warning_override() {
    local confirmation
    local confirmation_device="${TAILMOX_CONFIRMATION_DEVICE:-/dev/tty}"
    local confirmation_output_device="${TAILMOX_CONFIRMATION_OUTPUT_DEVICE:-/dev/tty}"
    local confirmation_timeout="${TAILMOX_CONFIRMATION_TIMEOUT_SECONDS:-10}"
    local countdown_pid

    if [[ ! -r "$confirmation_device" || ! -w "$confirmation_output_device" ]]; then
        log_echo "${RED}ICMP warnings require interactive confirmation, but no terminal is available. No cluster changes will be made.${RESET}"
        return 1
    fi

    log_echo "${YELLOW}WARNING: One or more Tailmox peers did not answer every ICMP probe within 50 ms.${RESET}"
    (
        local remaining="$confirmation_timeout"
        local unit

        while [[ "$remaining" -gt 0 ]]; do
            unit="seconds"
            if [[ "$remaining" -eq 1 ]]; then
                unit="second"
            fi

            if [[ "$remaining" -eq "$confirmation_timeout" ]]; then
                printf 'Time remaining: %s %s\n' "$remaining" "$unit"
                printf "Type 'PROCEED' to continue despite the ICMP warning: "
            else
                printf '\0337\033[1A\r\033[2KTime remaining: %s %s\0338' "$remaining" "$unit"
            fi

            sleep 1
            remaining=$((remaining - 1))
        done
    ) >> "$confirmation_output_device" &
    countdown_pid=$!

    if ! read -r -t "$confirmation_timeout" confirmation < "$confirmation_device"; then
        kill "$countdown_pid" 2>/dev/null || true
        wait "$countdown_pid" 2>/dev/null || true
        printf '\n' >> "$confirmation_output_device"
        log_echo "${RED}Confirmation timed out after ${confirmation_timeout} seconds. Setup cancelled; no cluster changes will be made.${RESET}"
        return 1
    fi

    kill "$countdown_pid" 2>/dev/null || true
    wait "$countdown_pid" 2>/dev/null || true

    if [[ "$confirmation" != "PROCEED" ]]; then
        log_echo "${RED}ICMP warning was not explicitly accepted. No cluster changes will be made.${RESET}"
        return 1
    fi

    log_echo "${YELLOW}ICMP warning explicitly accepted. Continuing at the user's request.${RESET}"
    return 0
}

# Ping every other Tailmox peer by its Tailscale MagicDNS name in parallel.
# Run a sequence of Tailscale's default DISCO pings to verify the Tailscale
# path. This allows the first probe to establish a direct route even if it uses
# DERP, while later probes can use that route. Five probes are spaced across a
# three-second window, and at least 80% must succeed.
# Separately, test both a conventional 64-byte ICMP packet and a large
# 1280-byte ICMP packet. Fifteen ICMP probes at approximately 0.357-second
# intervals span five seconds. Each ICMP reply gets a 50 ms window; slower or
# missing replies require confirmation.
function sample_tailscale_ping_reachability() {
    local peer_dns_name="$1"
    local result_file="$2"
    local ping_count="$3"
    local required_count="$4"
    local timeout="$5"
    local interval="$6"
    local attempt
    local successful_count=0
    local latency_count=0
    local latency_total_ms=0
    local latency_maximum_ms=0
    local attempt_latency_ms
    local latency_average_ms
    local attempt_file
    local started_at="${EPOCHREALTIME:-$(date +%s)}"
    local finished_at
    local duration_seconds
    local next_attempt_at
    local remaining_delay

    for ((attempt = 0; attempt < ping_count; attempt++)); do
        attempt_file="${result_file}.attempt-${attempt}"
        if tailscale ping --c 1 --timeout="$timeout" "$peer_dns_name" >"$attempt_file" 2>&1; then
            successful_count=$((successful_count + 1))
            attempt_latency_ms=$(sed -nE \
                's/.* in ([0-9]+([.][0-9]+)?)ms.*/\1/p' "$attempt_file" | tail -1)
            if [[ -n "$attempt_latency_ms" ]]; then
                latency_count=$((latency_count + 1))
                latency_total_ms=$(awk \
                    -v total="$latency_total_ms" -v latency="$attempt_latency_ms" \
                    'BEGIN { printf "%.3f", total + latency }')
                latency_maximum_ms=$(awk \
                    -v max_value="$latency_maximum_ms" -v latency="$attempt_latency_ms" \
                    'BEGIN { printf "%.3f", (latency > max_value) ? latency : max_value }')
            fi
        fi
        if [[ "$attempt" -lt $((ping_count - 1)) ]]; then
            next_attempt_at=$(awk -v started_at="$started_at" -v interval="$interval" \
                -v next_attempt="$((attempt + 1))" \
                'BEGIN { printf "%.6f", started_at + (interval * next_attempt) }')
            remaining_delay=$(awk -v next_attempt_at="$next_attempt_at" \
                -v current_at="${EPOCHREALTIME:-$(date +%s)}" \
                'BEGIN { printf "%.6f", next_attempt_at - current_at }')
            if awk -v delay="$remaining_delay" 'BEGIN { exit !(delay > 0) }'; then
                sleep "$remaining_delay"
            fi
        fi
    done

    finished_at="${EPOCHREALTIME:-$(date +%s)}"
    duration_seconds=$(awk -v started_at="$started_at" -v finished_at="$finished_at" \
        'BEGIN { printf "%d", (finished_at - started_at) + 0.5 }')

    if [[ "$latency_count" -gt 0 ]]; then
        latency_average_ms=$(awk \
            -v total="$latency_total_ms" -v count="$latency_count" \
            'BEGIN { printf "%.3f", total / count }')
        printf '%s of %s Tailscale pings succeeded (80%% required); average latency %s ms; maximum latency %s ms; duration %s s' \
            "$successful_count" "$ping_count" "$latency_average_ms" \
            "$latency_maximum_ms" "$duration_seconds" >"$result_file"
    else
        printf '%s of %s Tailscale pings succeeded (80%% required); average latency unknown ms; maximum latency unknown ms; duration %s s' \
            "$successful_count" "$ping_count" "$duration_seconds" >"$result_file"
    fi

    [[ "$successful_count" -ge "$required_count" ]]
}

function ensure_ping_reachability() {
    local peers_to_check="${1:-$OTHER_PEERS}"
    local check_description="${2:-all other Tailmox peers}"
    local require_icmp_confirmation="${3:-true}"

    log_echo "${YELLOW}Checking $check_description with five Tailscale path pings over three seconds and 15 64-byte and 1280-byte ICMP packets over five seconds in parallel...${RESET}"

    local ping_count=15
    local ping_interval=0.357142857
    local ping_deadline=6
    local reply_timeout=0.05
    local latency_warning_ms=50
    local tailscale_ping_count=5
    local tailscale_required_count=4
    local tailscale_ping_timeout=200ms
    local tailscale_ping_interval=0.75
    local peer_count
    local check_count
    local result_dir
    local peer
    local peer_hostname
    local peer_dns_name
    local payload_size
    local packet_size
    local result_file
    local avg_latency
    local max_latency
    local packet_loss
    local transmitted_count
    local received_count
    local check_type
    local command_succeeded
    local tailscale_result
    local duration_seconds
    local all_reachable=true
    local override_required=false
    local index=0
    local size_index
    local -a ping_payload_sizes=(56 1272)
    local -a icmp_packet_sizes=(64 1280)
    local -a peer_hostnames
    local -a peer_dns_names
    local -a check_types
    local -a packet_sizes
    local -a result_files
    local -a ping_pids
    local -a check_started_at

    function emit_monitor_icmp_result() {
        local hostname="$1"
        local size="$2"
        local status="$3"
        local received="$4"
        local sent="$5"
        local average="$6"
        local maximum="$7"
        local duration="$8"

        if [[ "${TAILMOX_MONITOR_OUTPUT:-false}" == "true" ]]; then
            printf '__TAILMOX_MONITOR_ICMP__\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$hostname" "$size" "$status" "$received" "$sent" "$average" "$maximum" "$duration"
        fi
    }

    if ! printf '%s\n' "$peers_to_check" | jq -e '
        (type == "array")
        and all(.[];
            ((.hostname | type) == "string")
            and (.hostname | length > 0)
            and ((.dnsName | type) == "string")
            and (.dnsName | length > 0)
        )
    ' >/dev/null 2>&1; then
        log_echo "${RED}Tailmox peer DNS data is invalid or incomplete. No cluster changes will be made.${RESET}"
        return 1
    fi

    peer_count=$(printf '%s\n' "$peers_to_check" | jq -r 'length')
    if [ "$peer_count" -eq 0 ]; then
        log_echo "${YELLOW}No other Tailmox peers require an ICMP check.${RESET}"
        return 0
    fi

    if ! result_dir=$(mktemp -d /tmp/tailmox-ping.XXXXXX); then
        log_echo "${RED}Unable to create temporary storage for ICMP results. No cluster changes will be made.${RESET}"
        return 1
    fi

    while IFS= read -r peer; do
        peer_hostname=$(printf '%s\n' "$peer" | jq -r '.hostname')
        peer_dns_name=$(printf '%s\n' "$peer" | jq -r '.dnsName' | sed 's/\.$//')

        result_file="$result_dir/$index"
        peer_hostnames[$index]="$peer_hostname"
        peer_dns_names[$index]="$peer_dns_name"
        check_types[$index]="tailscale"
        packet_sizes[$index]=""
        result_files[$index]="$result_file"

        sample_tailscale_ping_reachability \
            "$peer_dns_name" "$result_file" "$tailscale_ping_count" \
            "$tailscale_required_count" "$tailscale_ping_timeout" "$tailscale_ping_interval" &
        ping_pids[$index]=$!
        check_started_at[$index]="${EPOCHREALTIME:-$(date +%s)}"
        index=$((index + 1))

        for size_index in "${!ping_payload_sizes[@]}"; do
            payload_size="${ping_payload_sizes[$size_index]}"
            packet_size="${icmp_packet_sizes[$size_index]}"
            result_file="$result_dir/$index"

            peer_hostnames[$index]="$peer_hostname"
            peer_dns_names[$index]="$peer_dns_name"
            check_types[$index]="icmp"
            packet_sizes[$index]="$packet_size"
            result_files[$index]="$result_file"

            ping -n -c "$ping_count" -i "$ping_interval" -W "$reply_timeout" -w "$ping_deadline" \
                -s "$payload_size" "$peer_dns_name" >"$result_file" 2>&1 &
            ping_pids[$index]=$!
            check_started_at[$index]="${EPOCHREALTIME:-$(date +%s)}"
            index=$((index + 1))
        done
    done < <(printf '%s\n' "$peers_to_check" | jq -c '.[]')

    check_count=$index
    index=0
    while [ "$index" -lt "$check_count" ]; do
        peer_hostname="${peer_hostnames[$index]}"
        peer_dns_name="${peer_dns_names[$index]}"
        check_type="${check_types[$index]}"
        packet_size="${packet_sizes[$index]}"
        result_file="${result_files[$index]}"

        if wait "${ping_pids[$index]}"; then
            command_succeeded=true
        else
            command_succeeded=false
        fi

        duration_seconds=$(awk -v started_at="${check_started_at[$index]}" \
            -v finished_at="${EPOCHREALTIME:-$(date +%s)}" \
            'BEGIN { printf "%d", (finished_at - started_at) + 0.5 }')

        if [[ "$check_type" == "tailscale" ]]; then
            log_echo "${BLUE} - $peer_hostname ($peer_dns_name)${RESET}"
            tailscale_result=$(tail -1 "$result_file")
            if [[ "$command_succeeded" == true ]]; then
                log_echo "${GREEN}   - Tailscale path: ${tailscale_result:-reachable}.${RESET}"
            else
                log_echo "${RED}   - Tailscale path check failed: ${tailscale_result:-no result}. No cluster changes will be made.${RESET}"
                all_reachable=false
            fi
            index=$((index + 1))
            continue
        fi

        transmitted_count=$(awk -F',' '/packets transmitted/ {
            gsub(/[^0-9]/, "", $1)
            print $1
        }' "$result_file" | tail -1)
        received_count=$(awk -F',' '/packets transmitted/ {
            gsub(/[^0-9]/, "", $2)
            print $2
        }' "$result_file" | tail -1)
        packet_loss=$(awk -F',' '/packet loss/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $3)
            print $3
        }' "$result_file" | tail -1)
        avg_latency=$(awk -F'/' '/^(rtt|round-trip)/ {print $5}' "$result_file" | tail -1)
        max_latency=$(awk -F'/' '/^(rtt|round-trip)/ {print $6}' "$result_file" | tail -1)

        if [[ -z "$transmitted_count" || -z "$received_count" ]]; then
            log_echo "${RED}   - ${packet_size}-byte ICMP: result could not be interpreted. No cluster changes will be made.${RESET}"
            emit_monitor_icmp_result "$peer_hostname" "$packet_size" failed unknown unknown unknown unknown "$duration_seconds"
            all_reachable=false
        elif [[ "$received_count" -lt "$transmitted_count" ]]; then
            log_echo "${YELLOW}   - WARNING: ${packet_size}-byte ICMP: average latency ${avg_latency:-unknown} ms; maximum latency ${max_latency:-unknown} ms; only $received_count of $transmitted_count replies arrived within 50 ms; ${packet_loss:-packet loss unknown}.${RESET}"
            emit_monitor_icmp_result "$peer_hostname" "$packet_size" warning "$received_count" "$transmitted_count" "${avg_latency:-unknown}" "${max_latency:-unknown}" "$duration_seconds"
            override_required=true
        elif [[ -z "$max_latency" ]]; then
            log_echo "${RED}   - ${packet_size}-byte ICMP: latency result could not be interpreted. No cluster changes will be made.${RESET}"
            emit_monitor_icmp_result "$peer_hostname" "$packet_size" failed "$received_count" "$transmitted_count" "${avg_latency:-unknown}" unknown "$duration_seconds"
            all_reachable=false
        elif awk -v latency="$max_latency" -v limit="$latency_warning_ms" 'BEGIN { exit !(latency > limit) }'; then
            log_echo "${YELLOW}   - WARNING: ${packet_size}-byte ICMP: average latency ${avg_latency:-unknown} ms; maximum latency ${max_latency} ms exceeded 50 ms; $received_count of $transmitted_count replies arrived; ${packet_loss:-packet loss unknown}.${RESET}"
            emit_monitor_icmp_result "$peer_hostname" "$packet_size" warning "$received_count" "$transmitted_count" "${avg_latency:-unknown}" "$max_latency" "$duration_seconds"
            override_required=true
        else
            log_echo "${GREEN}   - ${packet_size}-byte ICMP: average latency ${avg_latency:-unknown} ms; maximum latency ${max_latency} ms; $received_count of $transmitted_count replies arrived within 50 ms; ${packet_loss:-0% packet loss}.${RESET}"
            emit_monitor_icmp_result "$peer_hostname" "$packet_size" passed "$received_count" "$transmitted_count" "${avg_latency:-unknown}" "$max_latency" "$duration_seconds"
        fi

        index=$((index + 1))
    done

    rm -r "$result_dir"

    if [ "$all_reachable" != true ]; then
        return 1
    fi

    if [[ "$override_required" == true ]]; then
        if [[ "$require_icmp_confirmation" == true ]]; then
            confirm_icmp_warning_override || return 1
        else
            TAILMOX_ICMP_WARNINGS_RECORDED=true
            log_echo "${YELLOW}ICMP warnings were recorded; the read-only test will continue without confirmation.${RESET}"
        fi
    fi

    return 0
}

# Check if TCP port 8006 is available on all nodes
function are_hosts_tcp_port_8006_reachable() {
    local peers_to_check="${1:-$ALL_PEERS}"
    local check_description="${2:-all nodes}"

    log_echo "${YELLOW}Checking if TCP port 8006 is available on $check_description...${RESET}"

    # Iterate through all peers
    printf '%s\n' "$peers_to_check" | jq -c '.[]' | while read -r peer; do
        local peer_ip
        local peer_hostname
        peer_ip=$(printf '%s\n' "$peer" | jq -r '.ip')
        peer_hostname=$(printf '%s\n' "$peer" | jq -r '.hostname')

        log_echo "${BLUE} - $peer_hostname ($peer_ip)${RESET}"
        local started_at="${EPOCHREALTIME:-$(date +%s)}"
        local finished_at
        local latency_ms
        if ! nc -z -w 2 "$peer_ip" 8006 &>/dev/null; then
            finished_at="${EPOCHREALTIME:-$(date +%s)}"
            latency_ms=$(awk -v started_at="$started_at" -v finished_at="$finished_at" \
                'BEGIN { printf "%.3f", (finished_at - started_at) * 1000 }')
            log_echo "${RED}   - TCP port 8006 is not available; latency ${latency_ms} ms.${RESET}"
            return 1
        else
            finished_at="${EPOCHREALTIME:-$(date +%s)}"
            latency_ms=$(awk -v started_at="$started_at" -v finished_at="$finished_at" \
                'BEGIN { printf "%.3f", (finished_at - started_at) * 1000 }')
            log_echo "${GREEN}   - TCP port 8006 is available; latency ${latency_ms} ms.${RESET}"
        fi
    done
}

# Check if TCP port 443 is available on all nodes
function are_hosts_tcp_port_443_reachable() {
    local peers_to_check="${1:-$ALL_PEERS}"
    local check_description="${2:-all nodes}"

    log_echo "${YELLOW}Checking if TCP port 443 is available on $check_description...${RESET}"

    # Iterate through all peers
    printf '%s\n' "$peers_to_check" | jq -c '.[]' | while read -r peer; do
        local peer_ip
        local peer_hostname
        peer_ip=$(printf '%s\n' "$peer" | jq -r '.ip')
        peer_hostname=$(printf '%s\n' "$peer" | jq -r '.hostname')

        log_echo "${BLUE} - $peer_hostname ($peer_ip)${RESET}"
        local started_at="${EPOCHREALTIME:-$(date +%s)}"
        local finished_at
        local latency_ms
        if ! nc -z -w 2 "$peer_ip" 443 &>/dev/null; then
            finished_at="${EPOCHREALTIME:-$(date +%s)}"
            latency_ms=$(awk -v started_at="$started_at" -v finished_at="$finished_at" \
                'BEGIN { printf "%.3f", (finished_at - started_at) * 1000 }')
            log_echo "${RED}   - TCP port 443 is not available; latency ${latency_ms} ms.${RESET}"
            return 1
        else
            finished_at="${EPOCHREALTIME:-$(date +%s)}"
            latency_ms=$(awk -v started_at="$started_at" -v finished_at="$finished_at" \
                'BEGIN { printf "%.3f", (finished_at - started_at) * 1000 }')
            log_echo "${GREEN}   - TCP port 443 is available; latency ${latency_ms} ms.${RESET}"
        fi
    done
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
    local report_cluster_membership="${1:-false}"

    # Check if the pvecm command exists (should be installed with Proxmox)
    if ! command -v pvecm &>/dev/null; then
        log_echo "${RED}pvecm command not found. Is this a Proxmox VE node?${RESET}"
        return 1
    fi

    # Get cluster status
    local cluster_status
    local cluster_name
    cluster_status=$(pvecm status 2>&1)

    # Check if the node is part of a cluster
    if printf '%s\n' "$cluster_status" | grep -q "is this node part of a cluster"; then
        log_echo "${BLUE}This node is not part of any cluster.${RESET}"
        return 1
    elif printf '%s\n' "$cluster_status" | grep -q "Cluster information"; then
        cluster_name=$(printf '%s\n' "$cluster_status" |
            awk '/^[[:space:]]*Name:[[:space:]]*/ { print $2; exit }')
        if [[ "$report_cluster_membership" == "true" ]]; then
            if [[ -n "$cluster_name" ]]; then
                log_echo "${GREEN}This node is already part of the Proxmox cluster named: $cluster_name.${RESET}"
            else
                log_echo "${GREEN}This node is already part of a Proxmox cluster.${RESET}"
            fi
        fi
        return 0
    else
        log_echo "${RED}Unable to determine cluster status. Output: $cluster_status${RESET}"
        return 1
    fi
}

# Record the Tailmox adoption of a quorate cluster in pmxcfs. This file is
# deliberately descriptive rather than authoritative: live Tailscale state,
# corosync.conf, and pvecm status are still required before any cluster change.
function write_tailmox_cluster_state() {
    local cluster_status=$1
    local configured_nodes=$2
    local cluster_name
    local state_directory
    local temporary_state
    local members_json
    local updated_at
    local node_name
    local current_address
    local tailscale_address

    cluster_name=$(printf '%s\n' "$cluster_status" | awk '/^[[:space:]]*Name:[[:space:]]*/ { print $2; exit }')
    if [[ -z "$cluster_name" ]]; then
        log_echo "${RED}Unable to determine the Proxmox cluster name for Tailmox state. No state file was written.${RESET}"
        return 1
    fi

    if ! members_json=$(while IFS=$'\t' read -r node_name current_address; do
        tailscale_address=$(printf '%s\n' "$ALL_PEERS" | jq -r \
            --arg node "$node_name" \
            '[.[] | select(.hostname == $node and .online == true) | .ip]
             | if length == 1 then .[0] else empty end')
        [[ -n "$tailscale_address" ]] || exit 1
        printf '%s\t%s\n' "$node_name" "$tailscale_address"
    done <<< "$configured_nodes" | jq -Rsc '
        split("\n")
        | map(select(length > 0) | split("\t")
              | select(length == 2)
              | {name: .[0], tailscaleIPv4: .[1]})
    '); then
        log_echo "${RED}Unable to build complete Tailmox cluster state from verified members. No state file was written.${RESET}"
        return 1
    fi

    if ! printf '%s\n' "$members_json" | jq -e --argjson expected_count "$(printf '%s\n' "$configured_nodes" | wc -l | tr -d ' ')" '
        (type == "array")
        and (length == $expected_count)
        and (all(.[]; (.name | type == "string") and (.name | length > 0)
                       and (.tailscaleIPv4 | type == "string") and (.tailscaleIPv4 | length > 0)))
    ' >/dev/null; then
        log_echo "${RED}Tailmox cluster state is incomplete. No state file was written.${RESET}"
        return 1
    fi

    state_directory=$(dirname "$TAILMOX_CLUSTER_STATE_FILE")
    if [[ -L "$TAILMOX_CLUSTER_STATE_FILE" || -d "$TAILMOX_CLUSTER_STATE_FILE" ]]; then
        log_echo "${RED}Tailmox state path is not a regular file: $TAILMOX_CLUSTER_STATE_FILE${RESET}"
        return 1
    fi
    if [[ -e "$TAILMOX_CLUSTER_STATE_FILE" ]] &&
        ! jq -e '.schemaVersion == 1 and (.members | type == "array")' \
            "$TAILMOX_CLUSTER_STATE_FILE" >/dev/null 2>&1; then
        log_echo "${RED}Existing Tailmox state is invalid and will not be overwritten: $TAILMOX_CLUSTER_STATE_FILE${RESET}"
        return 1
    fi
    if ! mkdir -p "$state_directory"; then
        log_echo "${RED}Unable to create the shared Tailmox state directory: $state_directory${RESET}"
        return 1
    fi

    temporary_state=$(mktemp "$state_directory/.state.json.XXXXXX") || {
        log_echo "${RED}Unable to create temporary Tailmox cluster state.${RESET}"
        return 1
    }
    updated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if ! jq -n \
        --arg cluster_name "$cluster_name" \
        --arg updated_at "$updated_at" \
        --argjson members "$members_json" \
        '{schemaVersion: 1, cluster: {name: $cluster_name}, members: $members,
          updatedAt: $updated_at}' > "$temporary_state" ||
        ! mv "$temporary_state" "$TAILMOX_CLUSTER_STATE_FILE"; then
        rm -f "$temporary_state"
        log_echo "${RED}Unable to write shared Tailmox cluster state. No state file was written.${RESET}"
        return 1
    fi
    chmod 0640 "$TAILMOX_CLUSTER_STATE_FILE" 2>/dev/null || true
    log_echo "${GREEN}Recorded verified Tailmox cluster members at $TAILMOX_CLUSTER_STATE_FILE.${RESET}"
}

# Prepare an existing Proxmox cluster for Tailmox without changing its
# membership. Corosync is a full-mesh protocol, so moving only the local node
# to Tailscale would isolate it from the other members. Require an online,
# exact Tailmox peer for every configured node and update all ring0 addresses
# in one shared corosync.conf change.
function prepare_existing_cluster_for_tailmox() {
    local cluster_status
    local configured_nodes
    local node_name
    local current_address
    local tailscale_address
    local migration_required=false
    local confirmation
    local confirmation_device="${TAILMOX_EXISTING_CLUSTER_CONFIRMATION_DEVICE:-/dev/tty}"
    local new_config="${TAILMOX_COROSYNC_CONFIG}.new"
    local peer_map

    TAILMOX_COROSYNC_CONFIG="${TAILMOX_COROSYNC_CONFIG:-$TAILMOX_PVE_CONFIG_DIR/corosync.conf}"

    if ! cluster_status=$(pvecm status 2>&1) ||
        ! printf '%s\n' "$cluster_status" | grep -q "Cluster information"; then
        log_echo "${RED}Unable to read the existing Proxmox cluster state. No Corosync changes will be made.${RESET}"
        return 1
    fi

    if ! printf '%s\n' "$cluster_status" | grep -Eq 'Quorate:[[:space:]]+Yes'; then
        log_echo "${RED}The existing cluster is not quorate. Tailmox will not change its Corosync network.${RESET}"
        return 1
    fi

    if [[ ! -f "$TAILMOX_COROSYNC_CONFIG" || ! -r "$TAILMOX_COROSYNC_CONFIG" ||
        ! -w "$TAILMOX_COROSYNC_CONFIG" ]]; then
        log_echo "${RED}The shared Corosync configuration is unavailable or not writable: $TAILMOX_COROSYNC_CONFIG${RESET}"
        return 1
    fi

    if ! configured_nodes=$(awk '
        /^[[:space:]]*node[[:space:]]*\{/ { in_node=1; name=""; address=""; next }
        in_node && /^[[:space:]]*name:[[:space:]]*/ {
            name=$0
            sub(/^[[:space:]]*name:[[:space:]]*/, "", name)
        }
        in_node && /^[[:space:]]*ring0_addr:[[:space:]]*/ {
            address=$0
            sub(/^[[:space:]]*ring0_addr:[[:space:]]*/, "", address)
        }
        in_node && /^[[:space:]]*\}/ {
            if (name == "" || address == "") {
                exit 2
            }
            print name "\t" address
            in_node=0
        }
        END {
            if (in_node) {
                exit 2
            }
        }
    ' "$TAILMOX_COROSYNC_CONFIG") || [[ -z "$configured_nodes" ]]; then
        log_echo "${RED}The Corosync node list is incomplete or could not be parsed. No changes will be made.${RESET}"
        return 1
    fi

    while IFS=$'\t' read -r node_name current_address; do
        tailscale_address=$(printf '%s\n' "$ALL_PEERS" | jq -r \
            --arg node "$node_name" \
            '[.[] | select(.hostname == $node and .online == true) | .ip]
             | if length == 1 then .[0] else empty end')

        if [[ -z "$tailscale_address" ]]; then
            log_echo "${RED}Cluster member $node_name does not have one unique, online tag:tailmox peer.${RESET}"
            log_echo "${RED}Run Tailmox staging on every existing member before adopting this cluster. No Corosync changes will be made.${RESET}"
            return 1
        fi

        if [[ "$current_address" != "$tailscale_address" ]]; then
            migration_required=true
        fi
    done <<< "$configured_nodes"

    if [[ "$migration_required" != "true" ]]; then
        if ! write_tailmox_cluster_state "$cluster_status" "$configured_nodes"; then
            return 1
        fi
        log_echo "${GREEN}The existing cluster already uses Tailscale for every Corosync link-0 address.${RESET}"
        log_echo "${GREEN}Cluster membership was preserved and this cluster is ready for new Tailmox hosts.${RESET}"
        return 0
    fi

    log_echo "${YELLOW}Tailmox found an existing quorate cluster whose Corosync link 0 is not fully on Tailscale.${RESET}"
    log_echo "${YELLOW}Cluster membership will be preserved, but Corosync may briefly lose quorum while every member changes networks.${RESET}"
    log_echo "${YELLOW}Type MIGRATE to update every existing member together, or anything else to leave the cluster unchanged.${RESET}"

    if [[ -r "$confirmation_device" ]]; then
        read -r confirmation < "$confirmation_device" || confirmation=""
    else
        confirmation=""
    fi

    if [[ "$confirmation" != "MIGRATE" ]]; then
        log_echo "${RED}Existing-cluster migration was not explicitly confirmed. No Corosync changes were made.${RESET}"
        return 1
    fi

    if [[ -e "$new_config" ]]; then
        log_echo "${RED}A pending Corosync configuration already exists at $new_config. Tailmox will not overwrite it.${RESET}"
        return 1
    fi

    if ! require_all_peers_online_before_cluster_change; then
        log_echo "${RED}Existing-cluster migration cancelled before changing Corosync.${RESET}"
        return 1
    fi

    if ! backup_proxmox_cluster_configuration; then
        log_echo "${RED}Existing-cluster migration cancelled because the current configuration could not be archived.${RESET}"
        return 1
    fi

    peer_map=$(mktemp "${TMPDIR:-/tmp}/tailmox-corosync-peers.XXXXXX") || return 1
    if ! printf '%s\n' "$ALL_PEERS" | jq -r \
        '.[] | select(.online == true) | [.hostname, .ip] | @tsv' > "$peer_map"; then
        rm -f "$peer_map"
        return 1
    fi

    if ! awk -v peer_map="$peer_map" '
        BEGIN {
            while ((getline line < peer_map) > 0) {
                split(line, fields, "\t")
                address[fields[1]]=fields[2]
            }
            close(peer_map)
        }
        /^[[:space:]]*node[[:space:]]*\{/ {
            in_node=1
            block=$0 ORS
            node_name=""
            next
        }
        in_node {
            block=block $0 ORS
            if ($0 ~ /^[[:space:]]*name:[[:space:]]*/) {
                node_name=$0
                sub(/^[[:space:]]*name:[[:space:]]*/, "", node_name)
            }
            if ($0 ~ /^[[:space:]]*\}/) {
                if (node_name == "" || !(node_name in address)) {
                    exit 2
                }
                replacement=block
                sub(/ring0_addr:[[:space:]]*[^[:space:]]+/, "ring0_addr: " address[node_name], replacement)
                printf "%s", replacement
                in_node=0
                block=""
            }
            next
        }
        /^[[:space:]]*config_version:[[:space:]]*[0-9]+/ {
            prefix=$0
            sub(/[0-9]+[[:space:]]*$/, "", prefix)
            version=$0
            sub(/^.*config_version:[[:space:]]*/, "", version)
            sub(/[[:space:]]*$/, "", version)
            print prefix (version + 1)
            version_seen=1
            next
        }
        { print }
        END {
            if (in_node || !version_seen) {
                exit 2
            }
        }
    ' "$TAILMOX_COROSYNC_CONFIG" > "$new_config"; then
        rm -f "$peer_map" "$new_config"
        log_echo "${RED}Unable to build a complete Tailmox Corosync configuration. The cluster was not changed.${RESET}"
        return 1
    fi
    rm -f "$peer_map"

    # Ask Corosync itself to parse and validate the complete candidate before
    # replacing the live configuration in pmxcfs. A missing validator, invalid
    # candidate, or other validation error must leave the shared file untouched.
    if ! "$TAILMOX_COROSYNC_COMMAND" -t -c "$new_config" >/dev/null 2>&1; then
        rm -f "$new_config"
        log_echo "${RED}Corosync rejected the generated configuration. The shared configuration was not changed.${RESET}"
        return 1
    fi

    if ! mv "$new_config" "$TAILMOX_COROSYNC_CONFIG"; then
        log_echo "${RED}Unable to activate the Tailmox Corosync configuration. The original is archived at $TAILMOX_LAST_CLUSTER_BACKUP.${RESET}"
        return 1
    fi

    if ! write_tailmox_cluster_state "$cluster_status" "$configured_nodes"; then
        log_echo "${RED}Corosync was migrated, but Tailmox state could not be recorded. Verify $TAILMOX_CLUSTER_STATE_FILE before adding hosts.${RESET}"
        return 1
    fi

    log_echo "${GREEN}Existing cluster membership was preserved.${RESET}"
    log_echo "${GREEN}All Corosync link-0 addresses now use Tailscale; the previous configuration is archived at $TAILMOX_LAST_CLUSTER_BACKUP.${RESET}"
    log_echo "${GREEN}This cluster is ready for a brand-new host to join by running Tailmox.${RESET}"
    return 0
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

    REMOTE_CLUSTER_STATUS_JSON=""
    
    log_echo "${YELLOW}Checking if remote node $node_hostname is part of a Proxmox cluster via API...${RESET}"
    
    # First, authenticate and get a ticket
    local auth_response=$(curl -k -s -d "username=$username&password=$password" \
        "https://$node_hostname:8006/api2/json/access/ticket" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$auth_response" ]; then
        log_echo "${RED}Failed to connect to Proxmox API on $node_hostname${RESET}"
        return 1
    fi
    
    # Extract ticket and CSRFPreventionToken
    local ticket=$(echo "$auth_response" | jq -r '.data.ticket // empty')
    local csrf_token=$(echo "$auth_response" | jq -r '.data.CSRFPreventionToken // empty')
    
    if [ -z "$ticket" ] || [ "$ticket" == "null" ]; then
        log_echo "${RED}Authentication failed for $node_hostname. Check credentials.${RESET}"
        return 1
    fi
    
    # Get cluster status using the API
    local cluster_response=$(curl -k -s \
        -H "Cookie: PVEAuthCookie=$ticket" \
        -H "CSRFPreventionToken: $csrf_token" \
        "https://$node_hostname:8006/api2/json/cluster/status" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$cluster_response" ]; then
        log_echo "${RED}Failed to get cluster status from $node_hostname API${RESET}"
        return 1
    fi
    
    # Check if the response indicates a cluster exists
    local cluster_data=$(echo "$cluster_response" | jq -r '.data // empty')
    
    if [ -z "$cluster_data" ] || [ "$cluster_data" == "null" ] || [ "$cluster_data" == "[]" ]; then
        log_echo "${BLUE}Remote node $node_hostname is not part of any cluster.${RESET}"
        return 1
    else
        # Extract cluster name from the first cluster entry
        local cluster_name=$(echo "$cluster_response" | jq -r '.data[] | select(.type == "cluster") | .name // empty' | head -1)
        if [ -n "$cluster_name" ] && [ "$cluster_name" != "null" ]; then
            REMOTE_CLUSTER_STATUS_JSON="$cluster_response"
            log_echo "${GREEN}Remote node $node_hostname is part of cluster named: $cluster_name${RESET}"
            return 0
        else
            log_echo "${BLUE}Remote node $node_hostname is not part of any cluster.${RESET}"
            return 1
        fi
    fi
}

# Refuse to join a cluster whose current Corosync node addresses are not the
# verified Tailscale addresses known to this host. Finding one tagged member is
# not sufficient: a new Corosync member must be able to reach the full mesh.
function remote_cluster_is_ready_for_tailmox_join() {
    if [[ -z "${REMOTE_CLUSTER_STATUS_JSON:-}" ]]; then
        log_echo "${RED}Remote cluster status is unavailable. The join will not be attempted.${RESET}"
        return 1
    fi

    if ! jq -n -e \
        --argjson status "$REMOTE_CLUSTER_STATUS_JSON" \
        --argjson peers "$ALL_PEERS" '
        ($status.data | map(select(.type == "node"))) as $nodes
        | ($nodes | length) > 0
        and all($nodes[];
            . as $node
            | ([$peers[]
                | select(
                    .online == true
                    and .hostname == $node.name
                    and .ip == $node.ip
                )] | length) == 1
        )
    ' >/dev/null 2>&1; then
        log_echo "${RED}The remote cluster does not advertise a verified Tailscale Corosync address for every member.${RESET}"
        log_echo "${RED}Run Tailmox on the existing cluster and complete its migration before joining this host.${RESET}"
        return 1
    fi

    return 0
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

# Create a new Proxmox cluster named "tailmox"
function create_cluster() {
    if ! require_all_peers_online_before_cluster_change; then
        return 1
    fi

    if ! backup_proxmox_cluster_configuration; then
        return 1
    fi

    local TAILSCALE_IP=$(tailscale ip -4)
    log_echo "${YELLOW}Creating a new Proxmox cluster named 'tailmox'...${RESET}"
    pvecm create tailmox --link0 "address=$TAILSCALE_IP"
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
                if remote_cluster_is_ready_for_tailmox_join; then
                    cluster_exists=true
                else
                    log_echo "${RED}Cluster join through $TARGET_HOSTNAME was rejected because the existing cluster is not Tailmox-ready.${RESET}"
                    continue
                fi
            # elif check_remote_node_cluster_status_via_ssh "$TARGET_HOSTNAME"; then
            #    cluster_exists=true
            fi
            
            if [ "$cluster_exists" = true ]; then
                local LOCAL_TAILSCALE_IP=$(tailscale ip -4)
                local target_fingerprint=$(get_pve_certificate_fingerprint "$TARGET_HOSTNAME")

                log_echo "${GREEN}Found an existing cluster on $TARGET_HOSTNAME. Joining the cluster...${RESET}"

                if ! require_all_peers_online_before_cluster_change; then
                    log_echo "${RED}Cluster join cancelled before pvecm add.${RESET}"
                    exit 1
                fi

                if ! backup_proxmox_cluster_configuration; then
                    log_echo "${RED}Cluster join cancelled because the current Proxmox configuration could not be archived.${RESET}"
                    exit 1
                fi

                 # Use expect to handle the password prompt with proper authentication
                expect -c "
                set timeout 60
                spawn pvecm add \"$TARGET_HOSTNAME.$MAGICDNS_DOMAIN_NAME\" --link0 address=$LOCAL_TAILSCALE_IP --fingerprint $target_fingerprint
                expect {
                    \"*?assword:*\" {
                        send \"$ROOT_PASSWORD\r\"
                        exp_continue
                    }
                    \"*?assword for*\" {
                        send \"$ROOT_PASSWORD\r\"
                        exp_continue
                    }
                    \"*authentication failure*\" {
                        puts \"Authentication failed. Please check your password.\"
                        exit 1
                    }
                    timeout {
                        puts \"Command timed out.\"
                        exit 1
                    }
                    eof
                }
                catch wait result
                exit [lindex \$result 3]
                "
                
                # Check if successful
                if [ $? -eq 0 ]; then
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

# Exercise the host-facing setup checks without making configuration changes.
function test_setup_safely() {
    local dependency
    local missing_dependencies=false
    local status_json
    local tailscale_ip
    local dns_name

    TAILMOX_ICMP_WARNINGS_RECORDED=false

    printf '%s\n' "Tailmox setup test (read-only)"
    printf '%s\n' "No packages, services, Tailscale settings, or cluster state will be changed."

    log_test_section 1 "Host readiness"
    if ! check_if_supported_proxmox_is_installed; then
        return 1
    fi

    if ! check_script_directory; then
        return 1
    fi

    log_echo "${YELLOW}Checking tools required by setup...${RESET}"
    for dependency in curl expect git jq ttyd tailscale pvecm ping nc openssl; do
        if ! command -v "$dependency" &>/dev/null; then
            log_echo "${RED} - $dependency is missing (normal setup would install it when supported).${RESET}"
            missing_dependencies=true
        fi
    done
    if [[ "$missing_dependencies" == "true" ]]; then
        log_echo "${RED}Setup cannot be fully tested until the missing tools are available.${RESET}"
        return 1
    fi

    # Cluster membership does not change the network checks, but operators
    # should know when the test is running on an existing Proxmox cluster.
    check_local_node_cluster_status true || true

    log_test_section 2 "Tailscale identity"
    log_echo "${YELLOW}Reading current Tailscale state...${RESET}"
    if ! status_json=$(tailscale status --json 2>/dev/null) ||
        ! printf '%s\n' "$status_json" | jq -e '
            (.BackendState == "Running")
            and ((.Self | type) == "object")
            and (.Self.Online == true)
            and ((.Self.Tags // []) | index("tag:tailmox") != null)
            and ((.Peer | type) == "object")
        ' >/dev/null 2>&1; then
        log_echo "${RED}This host is not online with the exact tag:tailmox identity, or Tailscale returned incomplete status.${RESET}"
        log_echo "${YELLOW}Normal setup would install or start Tailscale; the test did neither.${RESET}"
        return 1
    fi

    if ! tailscale_ip=$(tailscale ip -4 2>/dev/null) || [[ -z "$tailscale_ip" ]]; then
        log_echo "${RED}Unable to read this host's Tailscale IPv4 address.${RESET}"
        return 1
    fi
    dns_name=$(printf '%s\n' "$status_json" | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
    if [[ -z "$dns_name" ]]; then
        log_echo "${RED}Unable to read this host's Tailscale DNS name.${RESET}"
        return 1
    fi

    TAILSCALE_IP="$tailscale_ip"
    TAILSCALE_DNS_NAME="$dns_name"
    MAGICDNS_DOMAIN_NAME=$(printf '%s\n' "$dns_name" | cut -d'.' -f2-)
    LOCAL_PEER=$(jq -n \
        --arg hostname "$HOSTNAME" \
        --arg ip "$TAILSCALE_IP" \
        --arg dnsName "$TAILSCALE_DNS_NAME" \
        '{hostname: $hostname, ip: $ip, dnsName: $dnsName, online: true}')
    OTHER_PEERS=$(printf '%s\n' "$status_json" | jq -c '[.Peer[]
        | select((.Tags // []) | index("tag:tailmox"))
        | {
            hostname: .HostName,
            ip: .TailscaleIPs[0],
            dnsName: .DNSName,
            online: .Online
        }]')
    ALL_PEERS=$(printf '%s\n' "$OTHER_PEERS" |
        jq --argjson localPeer "$LOCAL_PEER" '. + [$localPeer]')
    LOCAL_PEERS=$(jq -n --argjson localPeer "$LOCAL_PEER" '[$localPeer]')

    log_test_section 3 "Local host connectivity"
    log_echo "${YELLOW}Testing the local Proxmox host first over its Tailscale address...${RESET}"
    ensure_ping_reachability "$LOCAL_PEERS" "the local Proxmox host" false || return 1
    are_hosts_tcp_port_8006_reachable "$LOCAL_PEERS" "the local Proxmox host" || return 1
    are_hosts_tcp_port_443_reachable "$LOCAL_PEERS" "the local Proxmox host" || return 1

    log_test_section 4 "Peer connectivity"
    check_all_peers_online || return 1
    ensure_ping_reachability "$OTHER_PEERS" "all other Tailmox peers" false || return 1
    are_hosts_tcp_port_8006_reachable "$OTHER_PEERS" "all other Tailmox peers" || return 1
    are_hosts_tcp_port_443_reachable "$OTHER_PEERS" "all other Tailmox peers" || return 1

    log_echo ""
    if [[ "$TAILMOX_ICMP_WARNINGS_RECORDED" == true ]]; then
        log_echo "${YELLOW}━━━ RESULT: Setup test passed with warnings ━━━━━━━━━━━━━━━━━━━${RESET}"
    else
        log_echo "${GREEN}━━━ RESULT: Setup test passed ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    fi
}

####
#### ---MAIN SCRIPT---
####

# Parse the script parameters
TERMINAL_MODE=false
STAGING=false
DRY_RUN=false
BACKUP_ACTION=""
WEB_ACTION=""
AUTH_KEY=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --staging) STAGING="true"; ;;
        --dry-run) DRY_RUN=true; ;;
        --backups-list) BACKUP_ACTION="list"; ;;
        --backup-create) BACKUP_ACTION="create"; ;;
        --web-stop) WEB_ACTION="stop"; ;;
        --auth-key)
            if [[ -z "${2:-}" ]]; then
                printf '%s\n' "--auth-key requires a value." >&2
                exit 1
            fi
            AUTH_KEY="$2"
            shift
            ;;
        --terminal) TERMINAL_MODE=true; ;;
        *) log_echo "${RED}Unknown parameter: $1${RESET}"; exit 1 ;;
    esac
    shift
done

# Allow the functions to be loaded by the regression tests without running the
# installer or making changes to a host.
if [[ "${TAILMOX_LIBRARY_MODE:-false}" == "true" ]]; then
    return 0 2>/dev/null || exit 0
fi

if [[ "$BACKUP_ACTION" == "list" ]]; then
    list_tailmox_configuration_backups
    exit $?
elif [[ "$BACKUP_ACTION" == "create" ]]; then
    backup_proxmox_cluster_configuration
    exit $?
fi

if [[ "$WEB_ACTION" == "stop" ]]; then
    stop_web_terminal
    exit $?
fi

if [[ "$DRY_RUN" == "true" ]]; then
    test_setup_safely
    exit $?
fi

if [[ "$TERMINAL_MODE" != "true" ]]; then
    TAILMOX_CONSOLE_OUTPUT=false

    if ! check_if_supported_proxmox_is_installed; then
        printf 'Proxmox VE 8.x or 9.x is required.\n' >&2
        exit 1
    fi

    if ! check_script_directory; then
        exit 1
    fi

    if ! install_dependencies >/dev/null 2>&1; then
        printf 'Unable to install Tailmox dependencies.\n' >&2
        exit 1
    fi

    if ! install_tailscale >/dev/null 2>&1 || ! start_tailscale "$AUTH_KEY" >/dev/null 2>&1; then
        printf 'Unable to start Tailscale. Use --auth-key if this host is not signed in.\n' >&2
        exit 1
    fi

    if ! start_web_terminal; then
        printf 'Unable to start the Tailmox web server. See %s for details.\n' "$LOG_FILE" >&2
        exit 1
    fi

    exit 0
fi

if [[ "$STAGING" == "true" ]]; then
    log_echo "${YELLOW}Staging mode enabled.${RESET}"
else
    log_echo "${GREEN}--- TAILMOX SCRIPT RUNNING ---${RESET}"
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
if ! start_tailscale "$AUTH_KEY"; then
    log_echo "${RED}The local Tailscale self-check failed. No cluster changes will be made.${RESET}"
    exit 1
fi

### Now that Tailscale is running...

# running 'tailscale serve' with these options allows a valid certificate on port 443, along with the built-in handling of the certificate
tailscale serve --bg https+insecure://localhost:8006 &>/dev/null
log_echo "${GREEN}Tailscale serve is now running.${RESET}"

tailscale serve --service=svc:tailmox https+insecure://localhost:8006 &>/dev/null
log_echo "${GREEN}Tailscale service started for tailmox.${RESET}"

# Exit early if staging mode is enabled
if [[ "$STAGING" == "true" ]]; then
    log_echo "${YELLOW}Staging mode enabled. Exiting after \`tailscale serve\` setup.${RESET}"
    exit 0
fi

# Get all nodes with the "tailmox" tag as a JSON array
TAILSCALE_IP=$(tailscale ip -4)
MAGICDNS_DOMAIN_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | cut -d'.' -f2- | sed 's/\.$//');
LOCAL_PEER=$(jq -n --arg hostname "$HOSTNAME" --arg ip "$TAILSCALE_IP" --arg dnsName "$HOSTNAME.$MAGICDNS_DOMAIN_NAME" --arg online "true" '{hostname: $hostname, ip: $ip, dnsName: $dnsName, online: ($online == "true")}');
OTHER_PEERS=$(tailscale status --json | jq -r '[.Peer[]
    | select((.Tags // []) | index("tag:tailmox"))
    | {hostname: .HostName, ip: .TailscaleIPs[0], dnsName: .DNSName, online: .Online}]');
ALL_PEERS=$(echo "$OTHER_PEERS" | jq --argjson localPeer "$LOCAL_PEER" '. + [$localPeer]');
LOCAL_PEERS=$(jq -n --argjson localPeer "$LOCAL_PEER" '[$localPeer]');

# Test this Proxmox host over Tailscale before relying on any remote peer.
log_echo "${YELLOW}Testing the local Proxmox host first over its Tailscale address...${RESET}"
if ! ensure_ping_reachability "$LOCAL_PEERS" "the local Proxmox host" ||
    ! are_hosts_tcp_port_8006_reachable "$LOCAL_PEERS" "the local Proxmox host" ||
    ! are_hosts_tcp_port_443_reachable "$LOCAL_PEERS" "the local Proxmox host"; then
    log_echo "${RED}The local Proxmox host failed its Tailscale self-test. Exiting...${RESET}"
    exit 1
fi

# Check that all Tailmox peers are online
if ! check_all_peers_online; then
    log_echo "${RED}Not all tailmox peers are online. Exiting...${RESET}"
    exit 1
fi

# Ensure that all peers are pingable
if ! ensure_ping_reachability; then
    log_echo "${RED}Some peers are unreachable via ping. Please check the network configuration.${RESET}"
    exit 1
else 
    log_echo "${GREEN}All Tailmox peers are reachable via ping.${RESET}"
fi

# Ensure that all peers are reachable via TCP port 8006
if ! are_hosts_tcp_port_8006_reachable "$OTHER_PEERS" "all other Tailmox peers"; then
    log_echo "${RED}Some peers have TCP port 8006 unavailable. Please check the network configuration.${RESET}"
    exit 1
else
    log_echo "${GREEN}All Tailmox peers have TCP port 8006 available.${RESET}"
fi

# Ensure that all peers are reachable via TCP port 443
if ! are_hosts_tcp_port_443_reachable "$OTHER_PEERS" "all other Tailmox peers"; then
    log_echo "${RED}Some peers have TCP port 443 unavailable. Please check the network configuration.${RESET}"
    exit 1
else
    log_echo "${GREEN}All Tailmox peers have TCP port 443 available.${RESET}"
fi

# Check if the local node is already in a cluster
if ! check_local_node_cluster_status; then
    log_echo "${YELLOW}This node is not part of a cluster. Attempting to create or join a cluster...${RESET}"
    # Add this local node to a cluster if it exists
    add_local_node_to_cluster
else
    log_echo "${GREEN}This node is already part of a cluster. Preparing that cluster for Tailmox...${RESET}"
    if ! prepare_existing_cluster_for_tailmox; then
        log_echo "${RED}The existing cluster was preserved but is not yet ready for a new Tailmox host.${RESET}"
        exit 1
    fi
    log_echo "${GREEN}You can now access your tailmox server directly at: ${BLUE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
    log_echo "${GREEN}You can now access your tailmox service at: ${BLUE}https://tailmox.$MAGICDNS_DOMAIN_NAME/${RESET}"
    log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
    exit 0
fi

# If local node is now in the cluster...
if ! check_local_node_cluster_status; then
    log_echo "${BLUE}No existing cluster found amongst any peers.${RESET}"
    log_echo "${YELLOW}Do you want to create a cluster on this node?${RESET}"
    read -p "Enter 'y' to create a new cluster or 'n' to exit: " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        if create_cluster; then
            log_echo "${GREEN}Cluster created successfully.${RESET}"
            log_echo "${GREEN}You can now access your tailmox server directly at: ${BLUE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
            log_echo "${GREEN}You can now access your tailmox service at: ${BLUE}https://tailmox.$MAGICDNS_DOMAIN_NAME/${RESET}"
            log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
        else
            log_echo "${RED}Cluster creation failed or was blocked by the peer safety check.${RESET}"
            log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
            exit 1
        fi
    else
        log_echo "${RED}Exiting without creating a cluster.${RESET}"
        log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
        exit 1
    fi
fi

### This version is working when tested with 3 nodes!
