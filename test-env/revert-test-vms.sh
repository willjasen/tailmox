#!/bin/bash
# filepath: ./revert-test-vms.sh

###
### This script is used for testing purposes only.
### When testing, this script can stop, revert to a snapshot, then start the Proxmox VMs being tested with.
### It can also delete all Tailscale devices with the tag "tailmox".
###
###
### Usage:
###   ./revert_test_vms.sh [--api-key <TAILSCALE_API_KEY>]
###
### Parameters:
###   --api-key <TAILSCALE_API_KEY>   (Optional) Tailscale API key used to delete devices tagged with "tailmox".
###
### Example:
###   ./revert_test_vms.sh --api-key tskey-xxxxxxxxxxxxxxxxxxxxxx
###

# Source color definitions
source "$(dirname "${BASH_SOURCE[0]}")/.colors.sh"

# Initialize the optional variable
TAILSCALE_API_KEY=""
VM_IDS=()

# --- 1. Argument Parsing Loop ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key)
            # Check if the next argument (the actual key) exists
            if [[ -n "$2" && "$2" != --* ]]; then
                TAILSCALE_API_KEY="$2"
                shift 2 # Consume the flag (--api-key) AND its value (the key)
            else
                echo "Error: --api-key requires a value." >&2
                exit 1
            fi
            ;;
        -h|--help)
            echo "Usage: $0 [--api-key <KEY>] <VM_ID_1> [VM_ID_2] ..."
            exit 0
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            exit 1
            ;;
        *)
            # This handles the remaining positional arguments (VM IDs)
            VM_IDS+=("$1")
            shift 1 # Consume the argument
            ;;
    esac
done

# Check if the VM_IDS array has a size greater than 0
if [ ${#VM_IDS[@]} -eq 0 ]; then
    # Output the error message to standard error (>&2)
    echo "Error: You must specify at least one VM ID." >&2
    echo "Usage: $0 [--api-key <KEY>] <VM_ID_1> [VM_ID_2] ..." >&2
    # Exit with a non-zero status code (1) to signal an error
    exit 1
fi

# Allow passing Tailscale API key as a parameter
# while [[ "$#" -gt 0 ]]; do
#    case $1 in
#        --api-key) TAILSCALE_API_KEY="$2"; echo "Using API key for Tailscale..."; shift; ;;
#        *) echo "Unknown parameter: $1"; exit 1 ;;
#    esac
#    shift
# done

# Function to delete all Tailscale devices with the tag "tailmox"
function delete_tailscale_tagged_devices() {
    if [ -z "$TAILSCALE_API_KEY" ]; then
        echo -e "${RED}TAILSCALE_API_KEY is not set. Skipping Tailscale device deletion.${RESET}"
        return 1
    fi

    echo -e "${YELLOW}Deleting all Tailscale devices with tag 'tailmox'...${RESET}"

    # Get all devices with the tag "tailmox"
    local devices_json
    local http_code
    devices_json=$(curl -s -w "%{http_code}" -u "$TAILSCALE_API_KEY:" \
        "https://api.tailscale.com/api/v2/tailnet/-/devices")
    http_code="${devices_json: -3}"
    devices_json="${devices_json:0:${#devices_json}-3}"

    if [ "$http_code" == "401" ] || [ "$http_code" == "403" ]; then
        echo -e "${RED}Tailscale API key is invalid or unauthorized (HTTP $http_code).${RESET}"
        return 1
    fi

    if [ -z "$devices_json" ] || ! echo "$devices_json" | jq empty &>/dev/null; then
        echo -e "${RED}Failed to fetch devices from Tailscale API or received invalid response.${RESET}"
        return 1
    fi

    # Extract device IDs and names with the tag "tag:tailmox"
    local device_info
    device_info=$(echo "$devices_json" | jq -r '.devices[] | select(.tags != null and (.tags[] == "tag:tailmox")) | "\(.id) \(.name)"')

    if [ -z "$device_info" ]; then
        echo -e "${PURPLE}No devices found with tag 'tailmox'.${RESET}"
        return 0
    fi

    # Delete each device
    while read -r id name; do
        echo -e "${BLUE}Deleting device $name...${RESET}"
        curl -s -X DELETE -u "$TAILSCALE_API_KEY:" \
            "https://api.tailscale.com/api/v2/device/$id" > /dev/null
    done <<< "$device_info"

    echo -e "${GREEN}All tagged Tailscale devices deleted.${RESET}"
}

# Function to stop a single VM
function stop_single_vm() {
    local vm_id=$1
    
    # Check if VM exists
    if qm status "$vm_id" &>/dev/null; then
        # Get current VM status
        local status=$(qm status "$vm_id" | awk '{print $2}')
        
        if [ "$status" == "running" ]; then
            echo -e "${BLUE}Stopping VM $vm_id...${RESET}"
            qm stop "$vm_id"
            
            # Wait for VM to stop
            local timeout=60
            local count=0
            while [ "$count" -lt "$timeout" ]; do
                status=$(qm status "$vm_id" | awk '{print $2}')
                if [ "$status" == "stopped" ]; then
                    echo -e "${GREEN}VM $vm_id successfully stopped.${RESET}"
                    break
                fi
                count=$((count + 1))
                sleep 1
            done
            
            if [ "$count" -ge "$timeout" ]; then
                echo -e "${RED}Failed to stop VM $vm_id within timeout period.${RESET}"
            fi
        else
            echo -e "${PURPLE}VM $vm_id is already stopped or in state: $status${RESET}"
        fi
    else
        echo -e "${RED}VM with ID $vm_id does not exist.${RESET}"
    fi
}

# Function to stop specified VMs in parallel
function stop_vms() {
    local vm_ids=("$@")
    
    echo -e "${YELLOW}Attempting to stop VMs with IDs: ${vm_ids[*]}${RESET}"
    
    # Array to keep track of background processes
    pids=()
    
    for vm_id in "${vm_ids[@]}"; do
        # Start each VM stop operation in the background
        stop_single_vm "$vm_id" &
        pids+=($!)
    done
    
    # Wait for all background processes to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    echo -e "${GREEN}All VM stop operations completed.${RESET}"
}

# Function to start a single VM
function start_single_vm() {
    local vm_id=$1
    
    # Check if VM exists
    if qm status "$vm_id" &>/dev/null; then
        # Get current VM status
        local status=$(qm status "$vm_id" | awk '{print $2}')
        
        if [ "$status" != "running" ]; then
            echo -e "${BLUE}Starting VM $vm_id...${RESET}"
            qm start "$vm_id"
            
            # Wait for VM to start
            local timeout=60
            local count=0
            while [ "$count" -lt "$timeout" ]; do
                status=$(qm status "$vm_id" | awk '{print $2}')
                if [ "$status" == "running" ]; then
                    echo -e "${GREEN}VM $vm_id successfully started.${RESET}"
                    break
                fi
                count=$((count + 1))
                sleep 1
            done
            
            if [ "$count" -ge "$timeout" ]; then
                echo -e "${RED}Failed to start VM $vm_id within timeout period.${RESET}"
            fi
        else
            echo -e "${PURPLE}VM $vm_id is already running.${RESET}"
        fi
    else
        echo -e "${RED}VM with ID $vm_id does not exist.${RESET}"
    fi
}

# Function to start specified VMs in parallel
function start_vms() {
    local vm_ids=("$@")
    
    echo -e "${YELLOW}Attempting to start VMs with IDs: ${vm_ids[*]}${RESET}"
    
    # Array to keep track of background processes
    pids=()
    
    for vm_id in "${vm_ids[@]}"; do
        # Start each VM start operation in the background
        start_single_vm "$vm_id" &
        pids+=($!)
    done
    
    # Wait for all background processes to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    echo -e "${GREEN}All VM start operations completed.${RESET}"
}

# Function to revert a single VM to a snapshot
function revert_single_vm() {
    local vm_id=$1
    local snapname=$2
    
    # Check if VM exists
    if qm status "$vm_id" &>/dev/null; then
        # Check if the snapshot exists
        # if qm snapshot "$vm_id" list | grep -q "$snapname"; then
            echo -e "${BLUE}Reverting VM $vm_id to snapshot '$snapname'...${RESET}"
            
            # Roll back to the snapshot
            qm rollback $vm_id $snapname
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Successfully reverted VM $vm_id to snapshot '$snapname'.${RESET}"
            else
                echo -e "${RED}Failed to revert VM $vm_id to snapshot '$snapname'.${RESET}"
            fi
        # else
        #    echo -e "${RED}Snapshot '$snapname' not found for VM $vm_id.${RESET}"
        #fi
    else
        echo -e "${RED}VM with ID $vm_id does not exist.${RESET}"
    fi
}

# Function to revert VMs to specified snapshots in parallel
function revert_vms_to_snapshot() {
    local snapname="ready-for-testing"
    local vm_ids=("$@")
    
    echo -e "${YELLOW}Attempting to revert VMs ${vm_ids[*]} to snapshot '$snapname' in parallel${RESET}"
    
    # Array to keep track of background processes
    pids=()
    
    for vm_id in "${vm_ids[@]}"; do
        # Start each VM revert operation in the background
        revert_single_vm "$vm_id" "$snapname" &
        pids+=($!)
    done
    
    # Wait for all background processes to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    echo -e "${GREEN}All VM revert operations completed.${RESET}"
}

# Function to test if a VM's guest agent is working
function test_guest_agent() {
    local vm_id=$1
    local max_attempts=$2
    local wait_seconds=$3
    
    # Default values if not provided
    max_attempts=${max_attempts:-30}
    wait_seconds=${wait_seconds:-10}
    
    echo -e "${YELLOW}Testing guest agent for VM $vm_id (max $max_attempts attempts, ${wait_seconds}s interval)...${RESET}"
    
    # Check if VM exists and is running
    if qm status "$vm_id" &>/dev/null; then
        local status=$(qm status "$vm_id" | awk '{print $2}')
        if [ "$status" != "running" ]; then
            echo -e "${RED}VM $vm_id is not running (status: $status). Cannot test guest agent.${RESET}"
            return 1
        fi
        
        # Try to ping the guest agent
        local attempt=1
        while [ "$attempt" -le "$max_attempts" ]; do
            echo -e "${BLUE}Attempt $attempt/$max_attempts: Checking guest agent on ${vm_id}...${RESET}"
            
            # Use qm agent command to check if agent is responsive
            if qm agent "$vm_id" ping &>/dev/null; then
                echo -e "${GREEN}Guest agent on VM $vm_id is responsive!${RESET}"
                return 0
            else
                echo -e "${PURPLE}Guest agent on ${vm_id} not responsive yet. Waiting ${wait_seconds}s...${RESET}"
                sleep "$wait_seconds"
            fi
            
            attempt=$((attempt + 1))
        done
        
        echo -e "${RED}Guest agent on VM $vm_id failed to respond after $max_attempts attempts.${RESET}"
        return 1
    else
        echo -e "${RED}VM with ID $vm_id does not exist.${RESET}"
        return 1
    fi
}

# Function to test guest agents for multiple VMs in parallel
function test_guest_agents() {
    local vm_ids=("$@")
    local max_attempts=${max_attempts:-30}
    local wait_seconds=${wait_seconds:-1}
    
    echo -e "${YELLOW}Testing guest agents for VMs with IDs: ${vm_ids[*]}${RESET}"
    
    # Array to keep track of background processes
    pids=()
    results=()
    
    for vm_id in "${vm_ids[@]}"; do
        # Start each guest agent test in the background
        test_guest_agent "$vm_id" "$max_attempts" "$wait_seconds" &
        pids+=($!)
    done
    
    # Wait for all background processes to complete
    for pid in "${pids[@]}"; do
        wait $pid
        results+=($?)
    done
    
    # Check if all tests were successful
    all_success=true
    for i in "${!vm_ids[@]}"; do
        if [ ${results[$i]} -ne 0 ]; then
            all_success=false
            echo -e "${RED}Guest agent test failed for VM ${vm_ids[$i]}${RESET}"
        fi
    done
    
    if $all_success; then
        echo -e "${GREEN}All guest agent tests completed successfully.${RESET}"
        return 0
    else
        echo -e "${RED}Some guest agent tests failed.${RESET}"
        return 1
    fi
}

###
### MAIN SCRIPT ###
##

# Revert the VMs back so that they are ready for testing again
stop_vms "${VM_IDS[@]}"
revert_vms_to_snapshot "${VM_IDS[@]}"

# Delete all Tailscale hosts with tag "tailmox" before starting VMs
delete_tailscale_tagged_devices

# Start the VMs and wait until their guest agents are responsive
start_vms "${VM_IDS[@]}"
test_guest_agents "${VM_IDS[@]}"

echo -e "${GREEN}The script has completed successfully!${RESET}"