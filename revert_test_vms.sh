#!/bin/bash
# filepath: ./revert-test-vms.sh

# Define color codes for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
RESET='\033[0m'

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

# Function to revert VMs to specified snapshots
function revert_vms_to_snapshot() {
    local snapname="v1-2"
    # shift
    local vm_ids=("$@")
    
    echo -e "${YELLOW}Attempting to revert VMs ${vm_ids[*]} to snapshot '$snapname'${RESET}"
    
    for vm_id in "${vm_ids[@]}"; do
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
    done
}

# Run the functions
stop_vms 10000 10001
revert_vms_to_snapshot 10000 10001
start_vms 10000 10001
