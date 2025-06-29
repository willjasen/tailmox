#!/bin/bash
# filepath: ./tailmox.sh

# Define color variables
YELLOW="\e[33m"
RED="\e[31m"
GREEN="\e[32m"
BLUE="\e[34m"
PURPLE="\e[35m"
RESET="\e[0m"

###
### ---FUNCTIONS---
### 

# Check if Proxmox is installed
function check_proxmox_8_installed() {
    echo -e "${YELLOW}Checking if Proxmox is installed...${RESET}"
    
    # Check for common Proxmox binaries and version file
    if [[ ! -f /usr/bin/pveversion ]]; then
        echo -e "${RED}Proxmox VE does not appear to be installed on this system.${RESET}"
        return 1
    fi
    
    # Check if it's version 8.x
    local pve_version=$(pveversion | grep -oP 'pve-manager/\K[0-9]+' | head -1)
    
    if [[ "$pve_version" == "8" ]]; then
        echo -e "${GREEN}Proxmox VE 8.x detected.${RESET}"
        return 0
    else
        echo -e "${RED}Proxmox VE 8.x is required. Found version: $pve_version${RESET}"
        return 1
    fi
}

# Install dependencies
function install_dependencies() {
    echo -e "${YELLOW}Checking for required dependencies...${RESET}"
    if ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}jq not found. Installing...${RESET}"
        apt update -qq;
        DEBIAN_FRONTEND=noninteractive apt install jq -y
    else
        # echo -e "${GREEN}jq is already installed.${RESET}"
        :
    fi

    if ! command -v expect &>/dev/null; then
        echo -e "${YELLOW}expect not found. Installing...${RESET}"
        apt update -qq;
        DEBIAN_FRONTEND=noninteractive apt install expect -y
    else
        # echo -e "${GREEN}expect is already installed.${RESET}"
        :
    fi
    # echo -e "${GREEN}All dependencies are installed.${RESET}"
}

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
        # echo -e "${GREEN}Tailscale is already installed.${RESET}"
        :
    fi
}

# Bring up Tailscale
function start_tailscale() {
    local auth_key="$1"
    echo -e "${GREEN}Starting Tailscale with --advertise-tags 'tag:tailmox'...${RESET}"
    
    if [ -n "$auth_key" ]; then
        # Use the provided auth key
        tailscale up --auth-key="$auth_key" --advertise-tags "tag:tailmox"
    else
        # Fall back to interactive authentication
        tailscale up --advertise-tags "tag:tailmox"
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to start Tailscale.${RESET}"
        exit 1
    fi

    # Retrieve the assigned Tailscale IPv4 address
    local TAILSCALE_IP=""
    while [ -z "$TAILSCALE_IP" ]; do
        echo -e "${YELLOW}Waiting for Tailscale to come online...${RESET}"
        sleep 1
        TAILSCALE_IP=$(tailscale ip -4)
    done

    TAILSCALE_DNS_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    echo -e "${GREEN}This host's Tailscale IPv4 address: $TAILSCALE_IP ${RESET}"
    echo -e "${GREEN}This host's Tailscale MagicDNS name: $TAILSCALE_DNS_NAME ${RESET}"
}

# Run Tailscale certificate services
function run_tailscale_cert_services() {
    if [ ! -d "/opt/tailscale-cert-services" ]; then
        echo -e "${YELLOW}Tailscale certificate services not found. Cloning repository...${RESET}"
        git clone --quiet https://github.com/willjasen/tailscale-cert-services /opt/tailscale-cert-services;
    else
        echo -e "${GREEN}Tailscale certificate services already cloned.${RESET}"
    fi
    cd /opt/tailscale-cert-services;
    VERSION="v1.1.0";
    git -c advice.detachedHead=false checkout tags/${VERSION} --quiet
    ./proxmox-cert.sh;
    cd /opt/tailmox;
}

# Check if all peers with the "tailmox" tag are online
function check_all_peers_online() {
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
        echo -e "${RED}No peers exist or not all tailmox peers are online. Exiting...${RESET}"
        exit 1
    fi

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
            ssh "$TARGET_HOSTNAME" "grep -q '$PEER_ENTRY' /etc/hosts || echo '$PEER_ENTRY' >> /etc/hosts"
        done
        
        echo -e "${GREEN}Finished updating hosts file on $TARGET_HOSTNAME${RESET}"
    done
}

# Ensure the local node can ping all nodes via Tailscale
function ensure_ping_reachability() {
    echo -e "${YELLOW}Ensuring the local node can ping all other nodes...${RESET}"

    # Get all peers with the "tailmox" tag
    local peers=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | .TailscaleIPs[0]]')

    # If no peers are found, exit with an error
    if [ -z "$peers" ]; then
        echo -e "${RED}No peers found with the 'tailmox' tag. Exiting...${RESET}"
        return 1
    fi

    # Check ping reachability for each peer
    echo "$peers" | jq -r '.[]' | while read -r peer_ip; do
        echo -e "${BLUE}Pinging $peer_ip...${RESET}"
        if ! ping -c 1 -W 2 "$peer_ip" &>/dev/null; then
            echo -e "${RED}Failed to ping $peer_ip.${RESET}"
            return 1
        else
            echo -e "${GREEN}Successfully pinged $peer_ip.${RESET}"
        fi
    done
}

# Report on the latency of each peer
function report_peer_latency() {
    echo -e "${YELLOW}Reporting peer latency...${RESET}"

    # Get all peers with the "tailmox" tag
    local peers=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | .TailscaleIPs[0]]')

    # If no peers are found, exit with an error
    if [ -z "$peers" ]; then
        echo -e "${RED}No peers found with the 'tailmox' tag. Exiting...${RESET}"
        return 1
    fi

    # Calculate average latency for each peer
    echo "$peers" | jq -r '.[]' | while read -r peer_ip; do
        local ping_count=25
        local ping_interval=0.1
        echo -e "${BLUE}Calculating average latency for $peer_ip ($ping_count pings with an interval of $ping_interval seconds)...${RESET}"
        avg_latency=$(ping -c $ping_count -i $ping_interval "$peer_ip" | awk -F'/' 'END {print $5}')
        if [ -n "$avg_latency" ]; then
            echo -e "${GREEN}Average latency to $peer_ip: ${avg_latency} ms${RESET}"
        else
            echo -e "${RED}Failed to calculate latency for $peer_ip.${RESET}"
        fi
    done
}

# Check if TCP port 8006 is available on all nodes
function are_hosts_tcp_port_8006_reachable() {
    echo -e "${YELLOW}Checking if TCP port 8006 is available on all nodes...${RESET}"

    # Iterate through all peers
    echo "$ALL_PEERS" | jq -c '.[]' | while read -r peer; do
        local peer_ip=$(echo "$peer" | jq -r '.ip')
        local peer_hostname=$(echo "$peer" | jq -r '.hostname')

        echo -e "${BLUE}Checking TCP port 8006 on $peer_hostname ($peer_ip)...${RESET}"
        if ! nc -z -w 2 "$peer_ip" 8006 &>/dev/null; then
            echo -e "${RED}TCP port 8006 is not available on $peer_hostname ($peer_ip).${RESET}"
            return 1
        else
            echo -e "${GREEN}TCP port 8006 is available on $peer_hostname ($peer_ip).${RESET}"
        fi
    done
}

# Check if UDP port 5405 is open on all nodes (corosync)
function check_udp_ports_5405_to_5412() {
    echo -e "${YELLOW}Checking if UDP ports 5405 through 5412 (Corosync) are available on all nodes...${RESET}"

    # Iterate through all peers
    local peer_unavailable=false
    echo "$ALL_PEERS" | jq -c '.[]' | while read -r peer; do
        local peer_ip=$(echo "$peer" | jq -r '.ip')
        local peer_hostname=$(echo "$peer" | jq -r '.hostname')

        for port in {5405..5412}; do
            echo -e "${BLUE}Checking UDP port $port on $peer_hostname ($peer_ip)...${RESET}"
            
            # For UDP, we'll use nc with -u flag and a short timeout
            # nc -v -u -z -w 3 prox2.risk-mermaid.ts.net 5405
            if ! timeout 2 bash -c "echo -n > /dev/udp/$peer_hostname/$port" 2>/dev/null; then
                echo -e "${RED}UDP port $port is not available on $peer_hostname ($peer_ip).${RESET}"
                peer_unavailable=true
            else
                echo -e "${GREEN}UDP port $port is available on $peer_hostname ($peer_ip).${RESET}"
            fi
        done
    done

    if $peer_unavailable; then
        echo -e "${RED}Some peers have UDP ports 5405 through 5412 unavailable. These ports are required for Corosync cluster communication.${RESET}"
        exit 1
    else
        echo -e "${GREEN}All peers have UDP ports 5405 through 5412 available.${RESET}"
    fi
}

# Check if this node is already part of a Proxmox cluster
# Returns true/false ?
function check_local_node_cluster_status() {
    echo -e "${YELLOW}Checking if this node is already part of a Proxmox cluster...${RESET}"
    
    # Check if the pvecm command exists (should be installed with Proxmox)
    if ! command -v pvecm &>/dev/null; then
        echo -e "${RED}pvecm command not found. Is this a Proxmox VE node?${RESET}"
        return 1
    fi
    
    # Get cluster status
    local cluster_status=$(pvecm status 2>&1)
    
    # Check if the node is part of a cluster
    if echo "$cluster_status" | grep -q "is this node part of a cluster"; then
        echo -e "${BLUE}This node is not part of any cluster.${RESET}"
        return 1
    elif echo "$cluster_status" | grep -q "Cluster information"; then
        local cluster_name=$(pvecm status | grep "Name:" | awk '{print $2}')
        echo -e "${GREEN}This node is already part of cluster named: $cluster_name${RESET}"
        return 0
    else
        echo -e "${RED}Unable to determine cluster status. Output: $cluster_status${RESET}"
        return 1
    fi
}

# Check if a remote node is already part of a Proxmox cluster
# Returns true/false ?
function check_remote_node_cluster_status() {
    local node_ip=$1
    echo -e "${YELLOW}Checking if remote node $node_ip is part of a Proxmox cluster...${RESET}"
    
    # Check if the pvecm command exists (should be installed with Proxmox)
    if ! command -v pvecm &>/dev/null; then
        echo -e "${RED}pvecm command not found. Is this a Proxmox VE node?${RESET}"
        exit 1
    fi
    
    # Get cluster status
    ssh-keyscan -H "$TARGET_HOSTNAME" >> ~/.ssh/known_hosts 2>/dev/null
    local cluster_status=$(ssh "$node_ip" "pvecm status" 2>&1)
    
    # Check if the node is part of a cluster
    if echo "$cluster_status" | grep -q "is this node part of a cluster"; then
        echo -e "${BLUE}Remote node $node_ip is not part of any cluster.${RESET}"
        return 1
    elif echo "$cluster_status" | grep -q "Cluster information"; then
        local cluster_name=$(ssh "$TARGET_HOSTNAME" "pvecm status" | grep "Name:" | awk '{print $2}')
        echo -e "${GREEN}Remote node $node_ip is already part of cluster named: $cluster_name${RESET}"
        return 0
    else
        echo -e "${RED}Unable to determine cluster status for remote node $node_ip. Output: $cluster_status${RESET}"
        exit 1
    fi

}

# Get the certificate fingerprint for a Proxmox node
# - parameter $1: hostname or IP address
function get_pve_certificate_fingerprint() {
    local hostname=$1
    local port=8006
    
    # echo -e "${YELLOW}Getting certificate fingerprint for $hostname:$port...${RESET}"
    
    # Use OpenSSL to connect to the server and get the certificate info
    local fingerprint=$(echo | openssl s_client -connect $hostname:$port 2>/dev/null | 
        openssl x509 -fingerprint -sha256 -noout | 
        cut -d'=' -f2)
    
    if [ -n "$fingerprint" ]; then
        # echo -e "${GREEN}Certificate fingerprint for $hostname:$port: $fingerprint${RESET}"
        echo "$fingerprint"
    else
        echo -e "${RED}Failed to get certificate fingerprint for $hostname:$port${RESET}"
        return 1
    fi
}

# Create a new Proxmox cluster named "tailmox"
function create_cluster() {
    local TAILSCALE_IP=$(tailscale ip -4)
    echo -e "${YELLOW}Creating a new Proxmox cluster named 'tailmox'...${RESET}"
    pvecm create tailmox --link0 address=$TAILSCALE_IP
}

# Add this local node into a cluster if it exists
function add_local_node_to_cluster() {
    if check_local_node_cluster_status; then
        echo -e "${PURPLE}This node is already in a cluster.${RESET}"
    else
        echo -e "${BLUE}This node is not in a cluster. Creating or joining a cluster is required.${RESET}"

        # Find if a cluster amongst peers already exists
        echo "$OTHER_PEERS" | jq -c '.[]' | while read -r target_peer; do
            TARGET_HOSTNAME=$(echo "$target_peer" | jq -r '.hostname')
            TARGET_IP=$(echo "$target_peer" | jq -r '.ip')
            TARGET_DNSNAME=$(echo "$target_peer" | jq -r '.dnsName' | sed 's/\.$//')
            
            echo -e "${BLUE}Checking cluster status on $TARGET_HOSTNAME ($TARGET_IP)...${RESET}"
            if check_remote_node_cluster_status "$TARGET_HOSTNAME"; then
                local LOCAL_TAILSCALE_IP=$(tailscale ip -4)
                local target_fingerprint=$(get_pve_certificate_fingerprint "$TARGET_HOSTNAME")

                echo -e "${GREEN}Found an existing cluster on $TARGET_HOSTNAME. Joining the cluster...${RESET}"

                # Prompt for root password of the remote node
                # echo -e "${YELLOW}Please enter the root password for ${TARGET_HOSTNAME}:${RESET}"
                read -s -p "Please enter the root password for ${TARGET_HOSTNAME}: " ROOT_PASSWORD < /dev/tty
                echo

                 # Use expect to handle the password prompt with proper authentication
                expect -c "
                set timeout 60
                spawn pvecm add \"$TARGET_HOSTNAME\" --link0 address=$LOCAL_TAILSCALE_IP --fingerprint $target_fingerprint
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
                    echo -e "${GREEN}Successfully joined cluster with $TARGET_HOSTNAME.${RESET}"
                    exit 0
                else
                    echo -e "${RED}Failed to join cluster with $TARGET_HOSTNAME. Check the password and try again.${RESET}"
                    exit 1
                fi
            else
                echo -e "${YELLOW}No cluster found on $TARGET_HOSTNAME.${RESET}"
            fi
        done
        
    fi
}

####
#### ---MAIN SCRIPT---
####

if ! check_proxmox_8_installed; then
    echo -e "${RED}Proxmox VE 8.x is required. Exiting...${RESET}"
    exit 1
fi

install_dependencies
install_tailscale

# Start Tailscale; use auth key if supplied
AUTH_KEY=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --auth-key) AUTH_KEY="$2"; echo "Using auth key for Tailscale..."; shift; ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done
start_tailscale $AUTH_KEY

### Now that Tailscale is running...

run_tailscale_cert_services

# Get all nodes with the "tailmox" tag as a JSON array
TAILSCALE_IP=$(tailscale ip -4)
MAGICDNS_DOMAIN_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | cut -d'.' -f2- | sed 's/\.$//');
LOCAL_PEER=$(jq -n --arg hostname "$HOSTNAME" --arg ip "$TAILSCALE_IP" --arg dnsName "$HOSTNAME.$MAGICDNS_DOMAIN_NAME" --arg online "true" '{hostname: $hostname, ip: $ip, dnsName: $dnsName, online: ($online == "true")}');
OTHER_PEERS=$(tailscale status --json | jq -r '[.Peer[] | select(.Tags != null and (.Tags[] | contains("tailmox"))) | {hostname: .HostName, ip: .TailscaleIPs[0], dnsName: .DNSName, online: .Online}]');
ALL_PEERS=$(echo "$OTHER_PEERS" | jq --argjson localPeer "$LOCAL_PEER" '. + [$localPeer]');

# Check that all Tailmox peers are online
if ! check_all_peers_online; then
    echo -e "${RED}Not all tailmox peers are online. Exiting...${RESET}"
    exit 1
fi

# Ensure that all peers have the Tailscale MagicDNS hostnames of all other hosts in the cluster
# Doesn't seem to be required at the moment...
# require_hostnames_in_cluster

# Ensure that all peers are pingable
if ! ensure_ping_reachability; then
    echo -e "${RED}Some peers are unreachable via ping. Please check the network configuration.${RESET}"
    exit 1
else 
    echo -e "${GREEN}All Tailmox peers are reachable via ping.${RESET}"
fi

# Report on the latency of each peer
report_peer_latency

# Ensure that all peers are reachable via TCP port 8006
if ! are_hosts_tcp_port_8006_reachable; then
    echo -e "${RED}Some peers have TCP port 8006 unavailable. Please check the network configuration.${RESET}"
    exit 1
else
    echo -e "${GREEN}All Tailmox peers have TCP port 8006 available.${RESET}"
fi

# Check if the local node is already in a cluster
if ! check_local_node_cluster_status; then
    echo -e "${YELLOW}This node is not part of a cluster. Attempting to create or join a cluster...${RESET}"
else
    echo -e "${GREEN}This node is already part of a cluster, nothing further to do.${RESET}"
    exit 1
fi

# Add this local node to a cluster if it exists
add_local_node_to_cluster

# If local node is now in the cluster...
if ! check_local_node_cluster_status; then
    echo -e "${BLUE}No existing cluster found amongst any peers.${RESET}"
    echo -e "${YELLOW}Do you want to create a cluster on this node?${RESET}"
    read -p "Enter 'y' to create a new cluster or 'n' to exit: " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        create_cluster
        echo -e "${GREEN}Cluster created successfully.${RESET}"
    else
        echo -e "${RED}Exiting without creating a cluster.${RESET}"
        exit 1
    fi
fi

echo -e "${GREEN}The script has exited successfully!${RESET}"

### This version is working when tested with 3 nodes!