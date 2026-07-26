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

# Define log file. Dry runs must not create or rotate host log files.
TAILMOX_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TAILMOX_EARLY_DRY_RUN=false
for tailmox_argument in "$@"; do
    if [[ "$tailmox_argument" == "--dry-run" ]]; then
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
TAILMOX_WEB_SERVICE="${TAILMOX_WEB_SERVICE:-tailmox-web.service}"
TAILMOX_SYSTEMD_DIR="${TAILMOX_SYSTEMD_DIR:-/etc/systemd/system}"

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

# Start the persistent localhost terminal and expose it only through Tailscale.
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

    if ! install -m 0644 "$service_source" "$service_target"; then
        log_echo "${RED}Unable to install the Tailmox web service.${RESET}"
        return 1
    fi

    if ! systemctl daemon-reload >>"$LOG_FILE" 2>&1 ||
        ! systemctl enable --now "$TAILMOX_WEB_SERVICE" >>"$LOG_FILE" 2>&1; then
        log_echo "${RED}Unable to start the Tailmox web terminal service.${RESET}"
        return 1
    fi

    if ! tailscale serve --bg --yes --https="$TAILMOX_WEB_PORT" \
        "http://127.0.0.1:$TAILMOX_WEB_BACKEND_PORT" >>"$LOG_FILE" 2>&1; then
        log_echo "${RED}Unable to expose the Tailmox web terminal through Tailscale Serve.${RESET}"
        return 1
    fi

    dns_name=$(tailscale status --json |
        jq -r '.Self.DNSName // empty' |
        sed 's/\.$//')
    if [[ -z "$dns_name" ]]; then
        log_echo "${RED}Unable to determine this host's Tailscale MagicDNS name.${RESET}"
        return 1
    fi

    printf 'Tailmox web server started.\n'
    printf 'https://%s:%s/\n' "$dns_name" "$TAILMOX_WEB_PORT"
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

    if ! tailscale status --json |
        jq -e '(.Self.Tags // []) | index("tag:tailmox") != null' >/dev/null 2>&1; then
        log_echo "${RED}This device does not have the required tag:tailmox identity. Assign it with the Tailscale API, admin console, or auth key before running Tailmox.${RESET}"
        return 1
    fi

    log_echo "${GREEN}This host's Tailscale IPv4 address: $TAILSCALE_IP ${RESET}"
    log_echo "${GREEN}This host's Tailscale MagicDNS name: $TAILSCALE_DNS_NAME ${RESET}"
}

# Check if all peers with the "tailmox" tag are online
function check_all_peers_online() {
    log_echo "${YELLOW}Checking if all tailmox peers are online...${RESET}"

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
        and ((.Peer | type) == "object")
    ' >/dev/null 2>&1; then
        log_echo "${RED}Tailscale is not fully online or returned incomplete peer status. No cluster changes will be made.${RESET}"
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

    if [[ ! -r /dev/tty ]]; then
        log_echo "${RED}ICMP warnings require interactive confirmation, but no terminal is available. No cluster changes will be made.${RESET}"
        return 1
    fi

    log_echo "${YELLOW}WARNING: One or more Tailmox peers did not answer every ICMP probe within 50 ms.${RESET}"
    if ! read -r -p "Type 'PROCEED' to continue despite the ICMP warning: " confirmation < /dev/tty; then
        log_echo "${RED}Unable to read interactive confirmation. No cluster changes will be made.${RESET}"
        return 1
    fi

    if [[ "$confirmation" != "PROCEED" ]]; then
        log_echo "${RED}ICMP warning was not explicitly accepted. No cluster changes will be made.${RESET}"
        return 1
    fi

    log_echo "${YELLOW}ICMP warning explicitly accepted. Continuing at the user's request.${RESET}"
    return 0
}

# Ping every other Tailmox peer by its Tailscale MagicDNS name in parallel.
# Use Tailscale's default DISCO ping to verify a Tailscale path, then test both a
# conventional 64-byte ICMP packet and a large 1280-byte ICMP packet. Eleven
# ICMP probes at 0.5-second intervals span approximately five seconds. Each
# reply gets a 50 ms window; slower or missing replies require confirmation.
function ensure_ping_reachability() {
    log_echo "${YELLOW}Checking all other Tailmox peers with Tailscale path pings and 64-byte and 1280-byte ICMP packets in parallel for approximately five seconds...${RESET}"

    local ping_count=11
    local ping_interval=0.5
    local ping_deadline=6
    local reply_timeout=0.05
    local latency_warning_ms=50
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

    if ! printf '%s\n' "$OTHER_PEERS" | jq -e '
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

    peer_count=$(printf '%s\n' "$OTHER_PEERS" | jq -r 'length')
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

        tailscale ping --c 1 "$peer_dns_name" >"$result_file" 2>&1 &
        ping_pids[$index]=$!
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
            index=$((index + 1))
        done
    done < <(printf '%s\n' "$OTHER_PEERS" | jq -c '.[]')

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

        if [[ "$check_type" == "tailscale" ]]; then
            tailscale_result=$(tail -1 "$result_file")
            if [[ "$command_succeeded" == true ]]; then
                log_echo "${GREEN} - $peer_hostname ($peer_dns_name), Tailscale path: ${tailscale_result:-reachable}.${RESET}"
            else
                log_echo "${RED} - $peer_hostname ($peer_dns_name), Tailscale path check failed: ${tailscale_result:-no result}. No cluster changes will be made.${RESET}"
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
            log_echo "${RED} - $peer_hostname ($peer_dns_name), ${packet_size}-byte ICMP: result could not be interpreted. No cluster changes will be made.${RESET}"
            all_reachable=false
        elif [[ "$received_count" -lt "$transmitted_count" ]]; then
            log_echo "${YELLOW} - WARNING: $peer_hostname ($peer_dns_name), ${packet_size}-byte ICMP: only $received_count of $transmitted_count replies arrived within 50 ms; ${packet_loss:-packet loss unknown}; average latency ${avg_latency:-unknown} ms.${RESET}"
            override_required=true
        elif [[ -z "$max_latency" ]]; then
            log_echo "${RED} - $peer_hostname ($peer_dns_name), ${packet_size}-byte ICMP: latency result could not be interpreted. No cluster changes will be made.${RESET}"
            all_reachable=false
        elif awk -v latency="$max_latency" -v limit="$latency_warning_ms" 'BEGIN { exit !(latency > limit) }'; then
            log_echo "${YELLOW} - WARNING: $peer_hostname ($peer_dns_name), ${packet_size}-byte ICMP: maximum latency ${max_latency} ms exceeded 50 ms; ${packet_loss:-packet loss unknown}; average latency ${avg_latency:-unknown} ms.${RESET}"
            override_required=true
        else
            log_echo "${GREEN} - $peer_hostname ($peer_dns_name), ${packet_size}-byte ICMP: all replies arrived within 50 ms; ${packet_loss:-0% packet loss}; average latency ${avg_latency:-unknown} ms.${RESET}"
        fi

        index=$((index + 1))
    done

    rm -r "$result_dir"

    if [ "$all_reachable" != true ]; then
        return 1
    fi

    if [ "$override_required" = true ] && ! confirm_icmp_warning_override; then
        return 1
    fi

    return 0
}

# Check if TCP port 8006 is available on all nodes
function are_hosts_tcp_port_8006_reachable() {
    log_echo "${YELLOW}Checking if TCP port 8006 is available on all nodes...${RESET}"

    # Iterate through all peers
    echo "$ALL_PEERS" | jq -c '.[]' | while read -r peer; do
        local peer_ip=$(echo "$peer" | jq -r '.ip')
        local peer_hostname=$(echo "$peer" | jq -r '.hostname')

        log_echo "${BLUE} - Checking TCP port 8006 on $peer_hostname ($peer_ip)...${RESET}"
        if ! nc -z -w 2 "$peer_ip" 8006 &>/dev/null; then
            log_echo "${RED} - TCP port 8006 is not available on $peer_hostname ($peer_ip).${RESET}"
            return 1
        else
            log_echo "${GREEN} - TCP port 8006 is available on $peer_hostname ($peer_ip).${RESET}"
        fi
    done
}

# Check if TCP port 443 is available on all nodes
function are_hosts_tcp_port_443_reachable() {
    log_echo "${YELLOW}Checking if TCP port 443 is available on all nodes...${RESET}"

    # Iterate through all peers
    echo "$ALL_PEERS" | jq -c '.[]' | while read -r peer; do
        local peer_ip=$(echo "$peer" | jq -r '.ip')
        local peer_hostname=$(echo "$peer" | jq -r '.hostname')

        log_echo "${BLUE} - Checking TCP port 443 on $peer_hostname ($peer_ip)...${RESET}"
        if ! nc -z -w 2 "$peer_ip" 443 &>/dev/null; then
            log_echo "${RED} - TCP port 443 is not available on $peer_hostname ($peer_ip).${RESET}"
            return 1
        else
            log_echo "${GREEN} - TCP port 443 is available on $peer_hostname ($peer_ip).${RESET}"
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
            log_echo "${GREEN}Remote node $node_hostname is part of cluster named: $cluster_name${RESET}"
            return 0
        else
            log_echo "${BLUE}Remote node $node_hostname is not part of any cluster.${RESET}"
            return 1
        fi
    fi
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

    local TAILSCALE_IP=$(tailscale ip -4)
    log_echo "${YELLOW}Creating a new Proxmox cluster named 'tailmox'...${RESET}"
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

                if ! require_all_peers_online_before_cluster_change; then
                    log_echo "${RED}Cluster join cancelled before pvecm add.${RESET}"
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
                    log_echo "${GREEN}You can now access your tailmox server directly at: ${PURPLE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
                    log_echo "${GREEN}You can now access your tailmox service at: ${PURPLE}https://tailmox.$MAGICDNS_DOMAIN_NAME/${RESET}"
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

    printf '%s\n' "Tailmox setup test (read-only)"
    printf '%s\n\n' "No packages, services, Tailscale settings, or cluster state will be changed."

    if ! check_if_supported_proxmox_is_installed; then
        return 1
    fi

    if ! check_script_directory; then
        return 1
    fi

    log_echo "${YELLOW}Checking tools required by setup...${RESET}"
    for dependency in curl expect git jq ttyd tailscale pvecm ping nc openssl; do
        if command -v "$dependency" &>/dev/null; then
            log_echo "${GREEN} - $dependency is available.${RESET}"
        else
            log_echo "${RED} - $dependency is missing (normal setup would install it when supported).${RESET}"
            missing_dependencies=true
        fi
    done
    if [[ "$missing_dependencies" == "true" ]]; then
        log_echo "${RED}Setup cannot be fully tested until the missing tools are available.${RESET}"
        return 1
    fi

    log_echo "${YELLOW}Reading current Tailscale state...${RESET}"
    if ! status_json=$(tailscale status --json 2>/dev/null) ||
        ! printf '%s\n' "$status_json" | jq -e '
            (.BackendState == "Running")
            and ((.Self | type) == "object")
            and (.Self.Online == true)
            and ((.Peer | type) == "object")
        ' >/dev/null 2>&1; then
        log_echo "${RED}Tailscale is not online or returned incomplete status.${RESET}"
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

    check_all_peers_online || return 1
    ensure_ping_reachability || return 1
    are_hosts_tcp_port_8006_reachable || return 1
    are_hosts_tcp_port_443_reachable || return 1

    log_echo "${YELLOW}Reading current Proxmox cluster state...${RESET}"
    check_local_node_cluster_status || true

    printf '\n%s\n' "Setup test passed."
    printf '%s\n' "Skipped all mutating steps: package installation, Tailscale up/serve,"
    printf '%s\n' "systemd changes, certificate changes, and Proxmox cluster create/join."
}

####
#### ---MAIN SCRIPT---
####

# Parse the script parameters
TERMINAL_MODE=false
STAGING=false
DRY_RUN=false
AUTH_KEY=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --staging) STAGING="true"; ;;
        --dry-run) DRY_RUN=true; ;;
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

log_echo "${GREEN}--- TAILMOX SCRIPT RUNNING ---${RESET}"
if [[ "$STAGING" == "true" ]]; then
    log_echo "${YELLOW}Staging mode enabled.${RESET}"
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
start_tailscale "$AUTH_KEY"

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
OTHER_PEERS=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | {hostname: .HostName, ip: .TailscaleIPs[0], dnsName: .DNSName, online: .Online}]');
ALL_PEERS=$(echo "$OTHER_PEERS" | jq --argjson localPeer "$LOCAL_PEER" '. + [$localPeer]');

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
if ! are_hosts_tcp_port_8006_reachable; then
    log_echo "${RED}Some peers have TCP port 8006 unavailable. Please check the network configuration.${RESET}"
    exit 1
else
    log_echo "${GREEN}All Tailmox peers have TCP port 8006 available.${RESET}"
fi

# Ensure that all peers are reachable via TCP port 443
if ! are_hosts_tcp_port_443_reachable; then
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
    log_echo "${GREEN}This node is already part of a cluster, nothing further to do.${RESET}"
    log_echo "${GREEN}You can now access your tailmox server directly at: ${PURPLE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
    log_echo "${GREEN}You can now access your tailmox service at: ${PURPLE}https://tailmox.$MAGICDNS_DOMAIN_NAME/${RESET}"
    log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
    exit 1
fi

# If local node is now in the cluster...
if ! check_local_node_cluster_status; then
    log_echo "${BLUE}No existing cluster found amongst any peers.${RESET}"
    log_echo "${YELLOW}Do you want to create a cluster on this node?${RESET}"
    read -p "Enter 'y' to create a new cluster or 'n' to exit: " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        if create_cluster; then
            log_echo "${GREEN}Cluster created successfully.${RESET}"
            log_echo "${GREEN}You can now access your tailmox server directly at: ${PURPLE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
            log_echo "${GREEN}You can now access your tailmox service at: ${PURPLE}https://tailmox.$MAGICDNS_DOMAIN_NAME/${RESET}"
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
