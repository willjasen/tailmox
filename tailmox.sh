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

# `info` is intentionally usable from a non-Proxmox machine, so it must not
# require write access to /var/log.
if [ "${1:-}" != "info" ] && [ "${TAILMOX_LIBRARY_MODE:-false}" != "true" ]; then
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
            apt update -qq;
            DEBIAN_FRONTEND=noninteractive apt install "$dep" -y
        else
            :
        fi
    done
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
    log_echo "${GREEN}Starting Tailscale with --advertise-tags 'tag:tailmox'...${RESET}"
    
    if [ -n "$auth_key" ]; then
        # Use the provided auth key
        tailscale up --auth-key="$auth_key" --advertise-tags "tag:tailmox"
    else
        # Fall back to interactive authentication
        tailscale up --advertise-tags "tag:tailmox"
    fi
    
    if [ $? -ne 0 ]; then
        log_echo "${RED}Failed to start Tailscale.${RESET}"
        exit 1
    fi

    # Retrieve the assigned Tailscale IPv4 address
    local TAILSCALE_IP=""
    while [ -z "$TAILSCALE_IP" ]; do
        log_echo "${YELLOW}Waiting for Tailscale to come online...${RESET}"
        sleep 1
        TAILSCALE_IP=$(tailscale ip -4)
    done

    TAILSCALE_DNS_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    log_echo "${GREEN}This host's Tailscale IPv4 address: $TAILSCALE_IP ${RESET}"
    log_echo "${GREEN}This host's Tailscale MagicDNS name: $TAILSCALE_DNS_NAME ${RESET}"
}

# Check if all peers with the "tailmox" tag are online
function check_all_peers_online() {
    log_echo "${YELLOW}Checking if all tailmox peers are online...${RESET}"
    local all_peers_online=true
    local offline_peers=""
    
    # Get the peers data
    local peers_data=$(tailscale status --json | jq -r '.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox")))')
    
    # If no peers are found, return 1
    if [ -z "$peers_data" ]; then
        log_echo "${YELLOW}No tailmox peers were found, but proceeding anyways.${RESET}"
        return 0
    fi
    
    # Check each peer's status
    echo "$peers_data" | jq -c '.HostName + ":" + (.Online|tostring)' | while read -r peer_status; do
        local hostname=$(echo "$peer_status" | cut -d: -f1)
        local is_online=$(echo "$peer_status" | cut -d: -f2)
        
        if [ "$is_online" != "true" ]; then
            all_peers_online=false
            offline_peers="${offline_peers}${hostname}, "
        fi
    done
    
    if [ "$all_peers_online" = true ]; then
        log_echo "${GREEN}All tailmox peers are registered as online in Tailscale.${RESET}"
        return 0
    else
        offline_peers=${offline_peers%, }
        log_echo "${RED}Not all tailmox peers are online in Tailscale. Offline peers: $offline_peers"
        return 1
    fi
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
    log_echo "${YELLOW}Ensuring the local node can ping all other nodes...${RESET}"

    # Get all peers with the "tailmox" tag
    local peers=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | .TailscaleIPs[0]]')

    # If no peers are found, exit with an error
    if [ -z "$peers" ]; then
        log_echo "${RED}No peers found with the 'tailmox' tag. Exiting...${RESET}"
        return 1
    fi

    # Number of attempts for pinging
    local max_attempts=3

    # Check ping reachability for each peer
    echo "$peers" | jq -r '.[]' | while read -r peer_ip; do
        # Get the hostname for the peer
        local peer_hostname=$(tailscale status --json | jq -r ".Peer[] | select(.TailscaleIPs[0] == \"$peer_ip\") | .HostName")
        local ping_interval=0.5
        local ping_count=6
        local ping_span=$(echo "$ping_interval * $ping_count" | bc)

        for attempt in $(seq 1 $max_attempts); do
            log_echo "${BLUE} - Attempt $attempt: Pinging $peer_hostname ($peer_ip) ($ping_count pings over $ping_span seconds)...${RESET}"
            if ! ping -c $ping_count -i $ping_interval -W 1 "$peer_ip" | grep -q "0 received"; then
                log_echo "${GREEN} - Successfully pinged $peer_hostname ($peer_ip) on attempt $attempt.${RESET}"
                break
            else
                log_echo "${YELLOW} - Attempt $attempt failed to ping $peer_hostname ($peer_ip). Retrying...${RESET}"
            fi

            # If this was the last attempt, log failure and return
            if [ "$attempt" -eq 3 ]; then
                log_echo "${RED} - Failed to ping $peer_hostname ($peer_ip) after 3 attempts. All responses were lost.${RESET}"
                return 1
            fi
        done
    done
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
                    if ! record_local_host; then
                        log_echo "${RED}The node joined the Proxmox cluster, but Tailmox could not record $HOSTNAME in $STATE_FILE.${RESET}"
                        exit 1
                    fi
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

####
#### ---MAIN SCRIPT---
####

if [ "${TAILMOX_LIBRARY_MODE:-false}" = "true" ]; then
    return 0 2>/dev/null || exit 0
fi

if [ "${1:-}" != "info" ]; then
    log_echo "${GREEN}--- TAILMOX SCRIPT RUNNING ---${RESET}"
fi

# Parse the script parameters
while [[ "$#" -gt 0 ]]; do
    case $1 in
        info) show_info; exit 0 ;;
        remove)
            shift
            [[ "$#" -eq 1 ]] || { printf 'Usage: tailmox.sh remove <node-name>\n' >&2; exit 2; }
            remove_cluster_node "$1"
            exit $?
            ;;
        --staging) STAGING="true"; log_echo "${YELLOW}Staging mode enabled.${RESET}"; ;;
        --auth-key) AUTH_KEY="$2"; log_echo "${YELLOW}Using auth key for Tailscale...${RESET}"; shift; ;;
        *) log_echo "${RED}Unknown parameter: $1${RESET}"; exit 1 ;;
    esac
    shift
done

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
start_tailscale $AUTH_KEY

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

# Report on the latency of each peer
report_peer_latency

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
    if ! record_local_host; then
        log_echo "${RED}This node is in the Proxmox cluster, but Tailmox could not record $HOSTNAME in $STATE_FILE.${RESET}"
        exit 1
    fi
    log_echo "${GREEN}This node is already part of a cluster, nothing further to do.${RESET}"
    log_echo "${GREEN}You can now access your tailmox server directly at: ${PURPLE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
    log_echo "${GREEN}You can now access your tailmox service at: ${PURPLE}https://tailmox.$MAGICDNS_DOMAIN_NAME/${RESET}"
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
        log_echo "${GREEN}You can now access your tailmox server directly at: ${PURPLE}https://$HOSTNAME.$MAGICDNS_DOMAIN_NAME/${RESET}"
        log_echo "${GREEN}You can now access your tailmox service at: ${PURPLE}https://tailmox.$MAGICDNS_DOMAIN_NAME/${RESET}"
        log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
    else
        log_echo "${RED}Exiting without creating a cluster.${RESET}"
        log_echo "${GREEN}--- TAILMOX SCRIPT EXITING ---${RESET}"
        exit 1
    fi
fi

### This version is working when tested with 3 nodes!
