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
if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}jq not found. Installing...${RESET}"
    apt update
    apt install jq -y
else
    echo "jq is already installed."
fi

# Function to get all nodes with the "proxmox" tag
get_proxmox_nodes() {
    echo "Retrieving Tailscale nodes with 'proxmox' tag..."
    tailscale status --json | jq -r '.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | {hostname: .HostName, ip: .TailscaleIPs[0], online: .Online}'
}

# Function to check if all peers with the "tailmox" tag are online
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

# Install Tailscale if it is not already installed
if ! command -v tailscale &>/dev/null; then
    echo -e "${YELLOW}Tailscale not found. Installing...${RESET}";
    apt install curl -y;
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null;
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list;
    apt update;
    apt install tailscale -y;
else
     echo -e "${GREEN}Tailscale is already installed.${RESET}"
fi

# Bring up Tailscale
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

### Now that Tailscale is running...

# Update /etc/hosts for local resolution of Tailscale hostnames for the clustered Proxmox nodes
echo "This host's hostname: $HOSTNAME"
MAGICDNS_DOMAIN_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | cut -d'.' -f2- | sed 's/\.$//');
echo "MagicDNS domain name for this tailnet: $MAGICDNS_DOMAIN_NAME"
HOSTS_FILE_ENTRY="$TAILSCALE_IP ${HOSTNAME} ${HOSTNAME}.${MAGICDNS_DOMAIN_NAME}"
echo "Entry to add into /etc/hosts: $HOSTS_FILE_ENTRY"

if ! grep -q "$HOSTS_FILE_ENTRY" /etc/hosts; then
      echo "Adding local host entry to /etc/hosts: $HOSTS_FILE_ENTRY"
      echo "$HOSTS_FILE_ENTRY" >> /etc/hosts
else
      echo "Local host entry already exists in /etc/hosts: $HOSTS_FILE_ENTRY"
fi
### Probably need to ensure that two "HOSTNAME"s being in the hosts file aren't a thing

### Need to add the "tailmox" tag to the Tailscale ACL some way
# "tag:tailmox" [
#			"autogroup:owner",
#		 ]

# Get all other nodes with the "tailmox" tag as a JSON array
TAILMOX_PEERS=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | {hostname: .HostName, ip: .TailscaleIPs[0], dnsName: .DNSName, online: .Online}]');

# Update the local /etc/hosts with peer information
echo "Updating the local /etc/hosts with peer information..."
for peer in $(echo "$TAILMOX_PEERS" | jq -c '.[]'); do
    PEER_HOSTNAME=$(echo "$peer" | jq -r '.hostname')
    PEER_IP=$(echo "$peer" | jq -r '.ip')
    PEER_ONLINE=$(echo "$peer" | jq -r '.online')
    PEER_DNSNAME=$(echo "$peer" | jq -r '.dnsName')
    
    # Add all peers with valid hostname and IP, regardless of online status
    if [ -n "$PEER_HOSTNAME" ] && [ -n "$PEER_IP" ]; then
        # Create the entry for this peer
        PEER_ENTRY="$PEER_IP $PEER_HOSTNAME $PEER_HOSTNAME.$MAGICDNS_DOMAIN_NAME"
        
        echo "Processing peer: $PEER_HOSTNAME ($PEER_IP) - Online: $PEER_ONLINE"
        
        # Check if entry already exists in /etc/hosts
        if ! grep -q "$PEER_ENTRY" /etc/hosts; then
            echo "Adding host entry to /etc/hosts: $PEER_ENTRY"
            echo "$PEER_ENTRY" >> /etc/hosts
        else
            echo "Host entry already exists for $PEER_HOSTNAME"
        fi
    else
        echo "Skipping peer with missing hostname or IP: $PEER_HOSTNAME"
    fi
done

# Exit the script if all peers are not online
if ! check_all_peers_online; then
    echo -e "${RED}No peers exist or not all tailmox peers are online. Exiting...${RESET}"
    exit 1
fi

# Ensure each peer's /etc/hosts file contains all other peers' entries
# For each peer, remote into it and add each other peer's entry to its /etc/hosts
echo -e "${GREEN}Ensuring all peers have complete host information...${RESET}"
echo "$TAILMOX_PEERS" | jq -c '.[]' | while read -r target_peer; do
    TARGET_HOSTNAME=$(echo "$target_peer" | jq -r '.hostname')
    TARGET_IP=$(echo "$target_peer" | jq -r '.ip')
    TARGET_ONLINE=$(echo "$target_peer" | jq -r '.online')
    
    # Skip if the target is the current host or offline
    if [ "$TARGET_HOSTNAME" == "$HOSTNAME" ] || [ "$TARGET_ONLINE" != "true" ]; then
        [ "$TARGET_HOSTNAME" == "$HOSTNAME" ] && echo "Skipping current host: $TARGET_HOSTNAME"
        [ "$TARGET_ONLINE" != "true" ] && echo "Skipping offline peer: $TARGET_HOSTNAME"
        continue
    fi
    
    echo -e "${BLUE}Updating /etc/hosts on $TARGET_HOSTNAME ($TARGET_IP)...${RESET}"
    
    # First, ensure the target host has its own entry
    LOCAL_ENTRY="$TARGET_IP $TARGET_HOSTNAME $TARGET_HOSTNAME.$MAGICDNS_DOMAIN_NAME"
    if ! ssh -o ConnectTimeout=3 "$TARGET_HOSTNAME" "grep -q '$LOCAL_ENTRY' /etc/hosts || echo '$LOCAL_ENTRY' >> /etc/hosts"; then
        echo -e "${RED}Failed to update /etc/hosts on $TARGET_HOSTNAME. Exiting...${RESET}"
        exit 1
    else
        echo -e "${GREEN}Successfully updated /etc/hosts on $TARGET_HOSTNAME.${RESET}"
    fi
    
    # Then add entries for all other peers
    echo "$TAILMOX_PEERS" | jq -c '.[]' | while read -r peer_to_add; do
        PEER_HOSTNAME=$(echo "$peer_to_add" | jq -r '.hostname')
        PEER_IP=$(echo "$peer_to_add" | jq -r '.ip')
        
        # Skip if the peer is the same as target
        if [ "$PEER_HOSTNAME" == "$TARGET_HOSTNAME" ] || [ -z "$PEER_HOSTNAME" ] || [ -z "$PEER_IP" ]; then
            continue
        fi
        
        PEER_ENTRY="$PEER_IP $PEER_HOSTNAME $PEER_HOSTNAME.$MAGICDNS_DOMAIN_NAME"
        echo "Adding $PEER_HOSTNAME to $TARGET_HOSTNAME's /etc/hosts"
        ssh -o StrictHostKeyChecking=no "$TARGET_HOSTNAME" "grep -q '$PEER_ENTRY' /etc/hosts || echo '$PEER_ENTRY' >> /etc/hosts"
    done
    
    echo -e "${GREEN}Finished updating hosts file on $TARGET_HOSTNAME${RESET}"
done

# # Cluster configuration - initialize or join based on role.
# if [ "$ROLE" == "master" ]; then
#     echo "Initializing Proxmox cluster on master host..."
#     # Create a new Proxmox cluster. Adjust cluster name as needed.
#     pvecm create tailmox_cluster
#     if [ $? -ne 0 ]; then
#         echo "Failed to create cluster."
#         exit 1
#     fi
#     echo "Cluster created successfully."
# else
#     echo "Joining Proxmox cluster as slave..."
#     echo "Using master DNS: $MASTER_DNS"
#     # Join the existing cluster using the provided master DNS name and advertise the Tailscale IP as the local link.
#     pvecm add "$MASTER_DNS" --link0 "$TAILSCALE_IP"
#     if [ $? -ne 0 ]; then
#         echo "Failed to join the cluster."
#         exit 1
#     fi
#     echo "Successfully joined the cluster."
# fi