#!/bin/bash
# filepath: ./tailmox.sh

# Install development dependencies
# apt install -y gh;

# Define color variables
YELLOW="\e[33m"
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

# Install Tailscale if it is not already installed
if ! command -v tailscale &>/dev/null; then
    echo -e "${YELLOW}Tailscale not found. Installing...${RESET}";
    apt install curl -y;
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null;
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list;
    apt update;
    apt install tailscale -y;
else
    echo "Tailscale is already installed."
fi

# Bring up Tailscale
echo "Starting Tailscale with --advertise-tags 'tag:tailmox'..."
tailscale up --advertise-tags "tag:tailmox"
if [ $? -ne 0 ]; then
    echo "Failed to start Tailscale."
    exit 1
fi

# Retrieve the assigned Tailscale IPv4 address
TAILSCALE_IP=""
while [ -z "$TAILSCALE_IP" ]; do
    echo "Waiting for Tailscale to come online..."
    sleep 1
    TAILSCALE_IP=$(tailscale ip -4)
done

echo "This host's Tailscale IPv4 address: $TAILSCALE_IP"

### Now that Tailscale is running...

# Update /etc/hosts for local resolution of Tailscale hostnames for the clustered Proxmox nodes
echo "This host's hostname: $HOSTNAME"
MAGICDNS_DOMAIN_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | cut -d'.' -f2- | sed 's/\.$//')
echo "MagicDNS domain name for this tailnet: $MAGICDNS_DOMAIN_NAME"

# Add this host's entry to /etc/hosts
HOSTS_FILE_ENTRY="$TAILSCALE_IP ${HOSTNAME} ${HOSTNAME}.${MAGICDNS_DOMAIN_NAME}"
echo "Entry to add into /etc/hosts: $HOSTS_FILE_ENTRY"

if ! grep -q "$HOSTS_FILE_ENTRY" /etc/hosts; then
    echo "Adding local host entry to /etc/hosts: $HOSTS_FILE_ENTRY"
    echo "$HOSTS_FILE_ENTRY" >> /etc/hosts
else
    echo "Local host entry already exists in /etc/hosts: $HOSTS_FILE_ENTRY"
fi

# Add entries for all Proxmox nodes with the "tailmox" tag
echo "Getting Proxmox nodes with the 'tailmox' tag...";
PROXMOX_NODES=$(get_proxmox_nodes)
echo "$PROXMOX_NODES" | jq -c '.[]' | while read -r NODE; do
    NODE_HOSTNAME=$(echo "$NODE" | jq -r '.hostname')
    NODE_IP=$(echo "$NODE" | jq -r '.ip')
    NODE_ONLINE=$(echo "$NODE" | jq -r '.online')

    if [ "$NODE_ONLINE" == "true" ]; then
        NODE_ENTRY="$NODE_IP $NODE_HOSTNAME $NODE_HOSTNAME.${MAGICDNS_DOMAIN_NAME}"
        echo "Entry to add into /etc/hosts for Proxmox node: $NODE_ENTRY"

        if ! grep -q "$NODE_ENTRY" /etc/hosts; then
            echo "Adding Proxmox node entry to /etc/hosts: $NODE_ENTRY"
            echo "$NODE_ENTRY" >> /etc/hosts
        else
            echo "Proxmox node entry already exists in /etc/hosts: $NODE_ENTRY"
        fi
    else
        echo "Skipping offline Proxmox node: $NODE_HOSTNAME"
    fi
done


### Need to add the "tailmox" tag to the Tailscale ACL some way
# "tag:tailmox" [
#			"autogroup:owner",
#		]



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