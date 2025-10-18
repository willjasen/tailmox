#!/bin/bash
# filepath: ./setup-debian13-vm.sh

###
### This script automates the creation of Debian 13 VMs in Proxmox using cloud-init
###

###############################################################################
# Debian 13 Cloud-Init VM Setup Script
#
# Usage:
#   ./setup-debian13-vm.sh [OPTIONS]
#
# Options:
#   --template-id <ID>        VM ID for template (default: 9000)
#   --vm-id <ID>             VM ID for new VM (required for deploy mode)
#   --vm-name <NAME>         Name for the new VM (required for deploy mode)
#   --mode <MODE>            Operation mode: template|deploy|both (default: both)
#   --storage <STORAGE>      Storage location (default: local-lvm)
#   --bridge <BRIDGE>        Network bridge (default: vmbr0)
#   --cores <CORES>          CPU cores (default: 2)
#   --memory <MB>            Memory in MB (default: 2048)
#   --disk-size <SIZE>       Disk size (default: 20G)
#   --ssh-key-file <FILE>    SSH public key file (default: ~/.ssh/id_rsa.pub)
#   --username <USER>        Cloud-init username (default: debian)
#   --password <PASS>        Cloud-init password (optional)
#   --ip <IP/CIDR>           Static IP address (optional, uses DHCP if not set)
#   --gateway <IP>           Gateway IP (required if static IP is set)
#   --nameserver <IP>        DNS server (default: 8.8.8.8)
#   --packages <LIST>        Comma-separated package list to install
#   --tailscale              Install Tailscale via cloud-init
#   --force                  Force overwrite existing template
#   --help                   Show this help message
#
# Examples:
#   # Create template only
#   ./setup-debian13-vm.sh --mode template
#   
#   # Deploy VM from existing template
#   ./setup-debian13-vm.sh --mode deploy --vm-id 101 --vm-name web-server-01
#   
#   # Create template and deploy VM with static IP
#   ./setup-debian13-vm.sh --vm-id 101 --vm-name web-server-01 --ip 192.168.1.100/24 --gateway 192.168.1.1
#   
#   # Deploy with Tailscale and custom packages
#   ./setup-debian13-vm.sh --vm-id 101 --vm-name dev-server --tailscale --packages "git,docker.io,htop"
#
###############################################################################

# Source color definitions if available
if [ -f "$(dirname "${BASH_SOURCE[0]}")/.colors.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/.colors.sh"
else
    # Define basic colors if .colors.sh is not available
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    RESET='\033[0m'
fi

# Default values
TEMPLATE_ID="9000"
VM_ID=""
VM_NAME=""
MODE="both"
STORAGE="local-lvm"
BRIDGE="vmbr0"
CORES="2"
MEMORY="2048"
DISK_SIZE="20G"
SSH_KEY_FILE="$HOME/.ssh/id_rsa.pub"
USERNAME="debian"
PASSWORD=""
STATIC_IP=""
GATEWAY=""
NAMESERVER="8.8.8.8"
PACKAGES=""
INSTALL_TAILSCALE=false
FORCE=false

# Debian 13 cloud image URL
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
IMAGE_DIR="/var/lib/vz/template/iso"
IMAGE_FILE="$IMAGE_DIR/debian-13-generic-amd64.qcow2"

###
### ---FUNCTIONS---
###

function show_help() {
    cat << 'EOF'
Debian 13 Cloud-Init VM Setup Script

This script automates the creation of Debian 13 VMs in Proxmox using cloud-init.

Usage:
  ./setup-debian13-vm.sh [OPTIONS]

Options:
  --template-id <ID>        VM ID for template (default: 9000)
  --vm-id <ID>             VM ID for new VM (required for deploy mode)
  --vm-name <NAME>         Name for the new VM (required for deploy mode)
  --mode <MODE>            Operation mode: template|deploy|both (default: both)
  --storage <STORAGE>      Storage location (default: local-lvm)
  --bridge <BRIDGE>        Network bridge (default: vmbr0)
  --cores <CORES>          CPU cores (default: 2)
  --memory <MB>            Memory in MB (default: 2048)
  --disk-size <SIZE>       Disk size (default: 20G)
  --ssh-key-file <FILE>    SSH public key file (default: ~/.ssh/id_rsa.pub)
  --username <USER>        Cloud-init username (default: debian)
  --password <PASS>        Cloud-init password (optional)
  --ip <IP/CIDR>           Static IP address (optional, uses DHCP if not set)
  --gateway <IP>           Gateway IP (required if static IP is set)
  --nameserver <IP>        DNS server (default: 8.8.8.8)
  --packages <LIST>        Comma-separated package list to install
  --tailscale              Install Tailscale via cloud-init
  --force                  Force overwrite existing template
  --help                   Show this help message

Examples:
  # Create template only
  ./setup-debian13-vm.sh --mode template
  
  # Deploy VM from existing template
  ./setup-debian13-vm.sh --mode deploy --vm-id 101 --vm-name web-server-01
  
  # Create template and deploy VM with static IP
  ./setup-debian13-vm.sh --vm-id 101 --vm-name web-server-01 --ip 192.168.1.100/24 --gateway 192.168.1.1
  
  # Deploy with Tailscale and custom packages
  ./setup-debian13-vm.sh --vm-id 101 --vm-name dev-server --tailscale --packages "git,docker.io,htop"

Requirements:
  - Must be run as root on a Proxmox VE host
  - Internet access for downloading cloud image
  - Sufficient storage space for VM template and VMs
EOF
}

function log_echo() {
    local message="$1"
    echo -e "$message"
}

function check_requirements() {
    log_echo "${YELLOW}Checking requirements...${RESET}"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_echo "${RED}This script must be run as root.${RESET}"
        exit 1
    fi
    
    # Check if this is a Proxmox system
    if ! command -v qm &>/dev/null; then
        log_echo "${RED}This script must be run on a Proxmox VE host.${RESET}"
        exit 1
    fi
    
    # Check if required tools are available
    local tools=("wget" "qm" "jq")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_echo "${YELLOW}Installing $tool...${RESET}"
            apt update -qq && apt install -y "$tool"
        fi
    done
    
    log_echo "${GREEN}Requirements check passed.${RESET}"
}

function download_debian_image() {
    log_echo "${YELLOW}Checking for Debian 13 cloud image...${RESET}"
    
    if [[ -f "$IMAGE_FILE" && "$FORCE" != true ]]; then
        log_echo "${GREEN}Debian 13 cloud image already exists at $IMAGE_FILE${RESET}"
        return 0
    fi
    
    log_echo "${YELLOW}Downloading Debian 13 cloud image...${RESET}"
    mkdir -p "$IMAGE_DIR"
    
    if wget -O "$IMAGE_FILE" "$DEBIAN_IMAGE_URL"; then
        log_echo "${GREEN}Successfully downloaded Debian 13 cloud image.${RESET}"
    else
        log_echo "${RED}Failed to download Debian 13 cloud image.${RESET}"
        exit 1
    fi
}

function check_vm_exists() {
    local vm_id="$1"
    qm status "$vm_id" &>/dev/null
}

function create_template() {
    log_echo "${YELLOW}Creating Debian 13 template (ID: $TEMPLATE_ID)...${RESET}"
    
    # Check if template already exists
    if check_vm_exists "$TEMPLATE_ID"; then
        if [[ "$FORCE" == true ]]; then
            log_echo "${YELLOW}Template VM $TEMPLATE_ID exists. Destroying it...${RESET}"
            qm stop "$TEMPLATE_ID" 2>/dev/null || true
            qm destroy "$TEMPLATE_ID"
        else
            log_echo "${RED}Template VM $TEMPLATE_ID already exists. Use --force to overwrite.${RESET}"
            exit 1
        fi
    fi
    
    # Create VM
    log_echo "${BLUE}Creating VM $TEMPLATE_ID...${RESET}"
    qm create "$TEMPLATE_ID" \
        --name "debian-13-template" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --net0 "virtio,bridge=$BRIDGE" \
        --agent enabled=1 \
        --ostype l26 \
        --cpu host \
        --machine q35 \
        --bios seabios
    
    # Import disk image
    log_echo "${BLUE}Importing disk image...${RESET}"
    qm disk import "$TEMPLATE_ID" "$IMAGE_FILE" "$STORAGE"
    
    # Configure the imported disk
    log_echo "${BLUE}Configuring disk...${RESET}"
    qm set "$TEMPLATE_ID" --scsihw virtio-scsi-pci --scsi0 "$STORAGE:vm-$TEMPLATE_ID-disk-0"
    
    # Add cloud-init drive
    log_echo "${BLUE}Adding cloud-init drive...${RESET}"
    qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit"
    
    # Set boot order
    qm set "$TEMPLATE_ID" --boot c --bootdisk scsi0
    
    # Add serial console
    qm set "$TEMPLATE_ID" --serial0 socket --vga serial0
    
    # Convert to template
    log_echo "${BLUE}Converting to template...${RESET}"
    qm template "$TEMPLATE_ID"
    
    log_echo "${GREEN}Template created successfully (ID: $TEMPLATE_ID).${RESET}"
}

function generate_cloud_init_config() {
    local config_file="/var/lib/vz/snippets/debian-13-cloudinit-$VM_ID.yml"
    
    log_echo "${BLUE}Generating cloud-init configuration...${RESET}"
    
    # Create snippets directory if it doesn't exist
    mkdir -p "/var/lib/vz/snippets"
    
    # Start building the cloud-init config
    cat > "$config_file" << EOF
#cloud-config
hostname: $VM_NAME
fqdn: $VM_NAME.local

users:
  - name: $USERNAME
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
EOF

    # Add SSH key if available
    if [[ -f "$SSH_KEY_FILE" ]]; then
        echo "    ssh_authorized_keys:" >> "$config_file"
        echo "      - $(cat "$SSH_KEY_FILE")" >> "$config_file"
    fi

    # Add password if provided
    if [[ -n "$PASSWORD" ]]; then
        # Hash the password
        local hashed_password=$(openssl passwd -6 "$PASSWORD")
        echo "    passwd: '$hashed_password'" >> "$config_file"
        echo "    lock_passwd: false" >> "$config_file"
    fi

    # Add base packages
    cat >> "$config_file" << EOF

packages:
  - qemu-guest-agent
  - curl
  - wget
  - git
  - htop
  - unattended-upgrades
  - openssh-server
EOF

    # Add custom packages
    if [[ -n "$PACKAGES" ]]; then
        IFS=',' read -ra PACKAGE_ARRAY <<< "$PACKAGES"
        for package in "${PACKAGE_ARRAY[@]}"; do
            echo "  - $package" >> "$config_file"
        done
    fi

    # Add Tailscale if requested
    if [[ "$INSTALL_TAILSCALE" == true ]]; then
        cat >> "$config_file" << EOF

runcmd:
  - curl -fsSL https://tailscale.com/install.sh | sh
  - systemctl enable tailscaled
  - systemctl start tailscaled
EOF
    else
        cat >> "$config_file" << EOF

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - systemctl enable ssh
  - systemctl start ssh
EOF
    fi

    cat >> "$config_file" << EOF

package_update: true
package_upgrade: true
timezone: UTC

write_files:
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
    owner: root:root
    permissions: '0644'

final_message: "Debian 13 VM '$VM_NAME' setup complete!"
EOF

    echo "$config_file"
}

function deploy_vm() {
    log_echo "${YELLOW}Deploying VM from template...${RESET}"
    
    # Check if VM already exists
    if check_vm_exists "$VM_ID"; then
        log_echo "${RED}VM $VM_ID already exists.${RESET}"
        exit 1
    fi
    
    # Check if template exists
    if ! check_vm_exists "$TEMPLATE_ID"; then
        log_echo "${RED}Template $TEMPLATE_ID does not exist. Create it first.${RESET}"
        exit 1
    fi
    
    # Clone template
    log_echo "${BLUE}Cloning template $TEMPLATE_ID to VM $VM_ID...${RESET}"
    qm clone "$TEMPLATE_ID" "$VM_ID" --name "$VM_NAME" --full
    
    # Configure cloud-init
    log_echo "${BLUE}Configuring cloud-init...${RESET}"
    
    # Generate and set custom cloud-init config
    local config_file=$(generate_cloud_init_config)
    qm set "$VM_ID" --cicustom "user=local:snippets/$(basename "$config_file")"
    
    # Set cloud-init user
    qm set "$VM_ID" --ciuser "$USERNAME"
    
    # Set password if provided
    if [[ -n "$PASSWORD" ]]; then
        qm set "$VM_ID" --cipassword "$PASSWORD"
    fi
    
    # Set SSH keys if available
    if [[ -f "$SSH_KEY_FILE" ]]; then
        qm set "$VM_ID" --sshkeys "$SSH_KEY_FILE"
    fi
    
    # Configure network
    if [[ -n "$STATIC_IP" ]]; then
        if [[ -z "$GATEWAY" ]]; then
            log_echo "${RED}Gateway is required when using static IP.${RESET}"
            exit 1
        fi
        qm set "$VM_ID" --ipconfig0 "ip=$STATIC_IP,gw=$GATEWAY"
    else
        qm set "$VM_ID" --ipconfig0 "ip=dhcp"
    fi
    
    # Set nameserver
    qm set "$VM_ID" --nameserver "$NAMESERVER"
    
    # Resize disk if different from template
    if [[ "$DISK_SIZE" != "20G" ]]; then
        log_echo "${BLUE}Resizing disk to $DISK_SIZE...${RESET}"
        qm resize "$VM_ID" scsi0 "$DISK_SIZE"
    fi
    
    log_echo "${GREEN}VM $VM_ID ($VM_NAME) deployed successfully.${RESET}"
    
    # Ask if user wants to start the VM
    read -p "Start VM $VM_ID now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_echo "${BLUE}Starting VM $VM_ID...${RESET}"
        qm start "$VM_ID"
        log_echo "${GREEN}VM $VM_ID started.${RESET}"
        
        # Show how to access the VM
        if [[ -n "$STATIC_IP" ]]; then
            local vm_ip=$(echo "$STATIC_IP" | cut -d'/' -f1)
            log_echo "${PURPLE}VM should be accessible at: ssh $USERNAME@$vm_ip${RESET}"
        else
            log_echo "${PURPLE}Check VM console or DHCP logs for assigned IP address.${RESET}"
        fi
        
        log_echo "${YELLOW}Note: First boot may take a few minutes for cloud-init to complete.${RESET}"
    fi
}

function main() {
    log_echo "${GREEN}--- Debian 13 Cloud-Init VM Setup ---${RESET}"
    
    check_requirements
    
    case "$MODE" in
        "template")
            download_debian_image
            create_template
            ;;
        "deploy")
            if [[ -z "$VM_ID" || -z "$VM_NAME" ]]; then
                log_echo "${RED}VM ID and VM name are required for deploy mode.${RESET}"
                exit 1
            fi
            deploy_vm
            ;;
        "both")
            if [[ -z "$VM_ID" || -z "$VM_NAME" ]]; then
                log_echo "${RED}VM ID and VM name are required for both mode.${RESET}"
                exit 1
            fi
            download_debian_image
            create_template
            deploy_vm
            ;;
        *)
            log_echo "${RED}Invalid mode: $MODE. Use template, deploy, or both.${RESET}"
            exit 1
            ;;
    esac
    
    log_echo "${GREEN}--- Script completed successfully ---${RESET}"
}

###
### ---MAIN SCRIPT---
###

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --template-id)
            TEMPLATE_ID="$2"
            shift 2
            ;;
        --vm-id)
            VM_ID="$2"
            shift 2
            ;;
        --vm-name)
            VM_NAME="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        --storage)
            STORAGE="$2"
            shift 2
            ;;
        --bridge)
            BRIDGE="$2"
            shift 2
            ;;
        --cores)
            CORES="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --ssh-key-file)
            SSH_KEY_FILE="$2"
            shift 2
            ;;
        --username)
            USERNAME="$2"
            shift 2
            ;;
        --password)
            PASSWORD="$2"
            shift 2
            ;;
        --ip)
            STATIC_IP="$2"
            shift 2
            ;;
        --gateway)
            GATEWAY="$2"
            shift 2
            ;;
        --nameserver)
            NAMESERVER="$2"
            shift 2
            ;;
        --packages)
            PACKAGES="$2"
            shift 2
            ;;
        --tailscale)
            INSTALL_TAILSCALE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            log_echo "${RED}Unknown option: $1${RESET}"
            show_help
            exit 1
            ;;
    esac
done

# Run main function
main