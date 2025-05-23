#!/bin/bash
# filepath: ./revert-test-vms.sh

###
### This script is used for testing purposes only.
### When testing, this script can stop, revert to a snapshot, then start the Proxmox VMs being tested with.
###

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

# Run the functions
stop_vms 10000 10001 10002
revert_vms_to_snapshot 10000 10001 10002
start_vms 10000 10001 10002
test_guest_agents 10000 10001 10002

echo -e "${GREEN}The script has completed successfully!${RESET}"