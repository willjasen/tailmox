#!/bin/bash
# filepath: ./tailmox.sh

# Install development dependencies
apt update;
# apt install -y gh;

# Install Tailscale if it is not already installed
if ! command -v tailscale &>/dev/null; then
    echo "Tailscale not found. Installing..."
    apt install -y tailscale
else
    echo "Tailscale is already installed."
fi

# Bring up Tailscale. Adjust flags as necessary.
echo "Starting Tailscale..."
tailscale up --accept-routes --advertise-tags proxmox
if [ $? -ne 0 ]; then
    echo "Failed to start Tailscale."
    exit 1
fi

# Allow time for Tailscale to assign an IP
sleep 5

# Retrieve the assigned Tailscale IPv4 address
TS_IP=$(tailscale ip -4)
if [ -z "$TS_IP" ]; then
    echo "Could not obtain Tailscale IP."
    exit 1
fi
echo "Your Tailscale IPv4: $TS_IP"

# # Update /etc/hosts for local resolution (example: use hostname.tailscale)
# HOSTNAME=$(hostname)
# HOSTS_ENTRY="$TS_IP ${HOSTNAME}.tailscale"

# if ! grep -q "$HOSTNAME.tailscale" /etc/hosts; then
#     echo "Adding local host entry to /etc/hosts: $HOSTS_ENTRY"
#     echo "$HOSTS_ENTRY" >> /etc/hosts
# fi

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
#     pvecm add "$MASTER_DNS" --link0 "$TS_IP"
#     if [ $? -ne 0 ]; then
#         echo "Failed to join the cluster."
#         exit 1
#     fi
#     echo "Successfully joined the cluster."
# fi