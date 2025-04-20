#!/bin/bash
# filepath: ./tailmox.sh

# Install development dependencies
# apt install -y gh;

# Define color variables
YELLOW="\e[33m"
RED="\e[31m"
GREEN="\e[32m"
BLUE="\e[34m"
PURPLE="\e[35m"
RESET="\e[0m"

# Install dependencies
function install_dependencies() {
    if ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}jq not found. Installing...${RESET}"
        apt update
        apt install jq -y
    else
        echo "jq is already installed."
    fi
}
install_dependencies

# Install Tailscale if it is not already installed
function install_tailscale() {
    if ! command -v tailscale &>/dev/null; then
        echo -e "${YELLOW}Tailscale not found. Installing...${RESET}"
        apt install curl -y
        curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
        apt update
        apt install tailscale -y
    else
        echo -e "${GREEN}Tailscale is already installed.${RESET}"
    fi
}
install_tailscale

# Bring up Tailscale
function start_tailscale() {
    echo "Starting Tailscale with --advertise-tags 'tag:tailmox'..."
    tailscale up --advertise-tags "tag:tailmox"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to start Tailscale.${RESET}"
        exit 1
    fi

    # Retrieve the assigned Tailscale IPv4 address
    TAILSCALE_IP=""
    while [ -z "$TAILSCALE_IP" ]; do
        echo -e "${YELLOW}Waiting for Tailscale to come online...${RESET}"
        sleep 1
        TAILSCALE_IP=$(tailscale ip -4)
    done

    echo "This host's Tailscale IPv4 address: $TAILSCALE_IP"
}
start_tailscale

### Now that Tailscale is running...

# Check if all peers with the "tailmox" tag are online
check_all_peers_online() {
    echo -e "${YELLOW}Checking if all tailmox peers are online...${RESET}"
    local all_peers_online=true
    local offline_peers=""
    
    # Get the peers data
    local peers_data=$(tailscale status --json | jq -r '.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox")))')
    
    # If no peers are found, return 1
    if [ -z "$peers_data" ]; then
        echo -e "${YELLOW}No tailmox peers were found.${RESET}"
        return 1
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
        echo -e "${GREEN}All tailmox peers are online.${RESET}"
        return 0
    else
        offline_peers=${offline_peers%, }
        echo -e "${RED}Not all tailmox peers are online. Offline peers: $offline_peers"
        return 1
    fi
}

# Ensure that each Proxmox host in the cluster has the Tailscale MagicDNS hostnames of all other hosts in the cluster
require_hostnames_in_cluster() {
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
        echo -e "${RED}No peers exist or not all tailmox peers are online. Exiting...${RESET}"
        exit 1
    fi

    # Get all nodes with the "tailmox" tag as a JSON array
    LOCAL_PEER=$(jq -n --arg hostname "$HOSTNAME" --arg ip "$TAILSCALE_IP" --arg dnsName "$HOSTNAME.$MAGICDNS_DOMAIN_NAME" --arg online "true" '{hostname: $hostname, ip: $ip, dnsName: $dnsName, online: ($online == "true")}');
    OTHER_PEERS=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | {hostname: .HostName, ip: .TailscaleIPs[0], dnsName: .DNSName, online: .Online}]');
    ALL_PEERS=$(echo "$OTHER_PEERS" | jq --argjson localPeer "$LOCAL_PEER" '. + [$localPeer]');

    # Ensure each peer's /etc/hosts file contains all other peers' entries
    # For each peer, remote into it and add each other peer's entry to its /etc/hosts
    echo -e "${GREEN}Ensuring all peers have other peers' information...${RESET}"
    echo "$ALL_PEERS" | jq -c '.[]' | while read -r target_peer; do
        TARGET_HOSTNAME=$(echo "$target_peer" | jq -r '.hostname')
        TARGET_IP=$(echo "$target_peer" | jq -r '.ip')
        TARGET_DNSNAME=$(echo "$target_peer" | jq -r '.dnsName' | sed 's/\.$//')
        
        echo -e "${BLUE}Updating /etc/hosts on $TARGET_HOSTNAME ($TARGET_IP)...${RESET}"
        
        # Loop through all peers and update the target peer's /etc/hosts as needed
        for peer_to_add in $(echo "$ALL_PEERS" | jq -c '.[]'); do
            PEER_HOSTNAME=$(echo "$peer_to_add" | jq -r '.hostname')
            PEER_IP=$(echo "$peer_to_add" | jq -r '.ip')
            PEER_DNSNAME=$(echo "$peer_to_add" | jq -r '.dnsName' | sed 's/\.$//')        
            PEER_ENTRY="$PEER_IP $PEER_HOSTNAME $PEER_DNSNAME"

            echo "Adding $PEER_HOSTNAME to $TARGET_HOSTNAME's /etc/hosts"
            ssh-keyscan -H "$TARGET_HOSTNAME" >> ~/.ssh/known_hosts 2>/dev/null
            ssh -o StrictHostKeyChecking=no "$TARGET_HOSTNAME" "grep -q '$PEER_ENTRY' /etc/hosts || echo '$PEER_ENTRY' >> /etc/hosts"
        done
        
        echo -e "${GREEN}Finished updating hosts file on $TARGET_HOSTNAME${RESET}"
    done
}
require_hostnames_in_cluster

# Ensure the local node can ping all nodes via Tailscale
function ensure_ping_reachability() {
    echo -e "${YELLOW}Ensuring the local node can ping all other nodes...${RESET}"

    # Get all peers with the "tailmox" tag
    local peers=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | .TailscaleIPs[0]]')

    # If no peers are found, exit with an error
    if [ -z "$peers" ]; then
        echo -e "${RED}No peers found with the 'tailmox' tag. Exiting...${RESET}"
        exit 1
    fi

    # Check ping reachability for each peer
    local unreachable_peers=""
    echo "$peers" | jq -r '.[]' | while read -r peer_ip; do
        echo -e "${BLUE}Pinging $peer_ip...${RESET}"
        if ! ping -c 1 -W 2 "$peer_ip" &>/dev/null; then
            echo -e "${RED}Failed to ping $peer_ip.${RESET}"
            unreachable_peers="${unreachable_peers}${peer_ip}, "
        else
            echo -e "${GREEN}Successfully pinged $peer_ip.${RESET}"
        fi
    done

    # Report unreachable peers, if any
    if [ -n "$unreachable_peers" ]; then
        unreachable_peers=${unreachable_peers%, }
        echo -e "${RED}The following peers are unreachable: $unreachable_peers${RESET}"
        exit 1
    else
        echo -e "${GREEN}All peers are reachable via ping.${RESET}"
    fi
}
ensure_ping_reachability