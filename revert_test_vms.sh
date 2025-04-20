#!/bin/bash
# filepath: ./revert-test-vms.sh

# Function to stop specified VMs on the local Proxmox host
function stop_vms() {
    local vm_ids=("$@")
    
    echo -e "${YELLOW}Attempting to stop VMs with IDs: ${vm_ids[*]}${RESET}"
    
    for vm_id in "${vm_ids[@]}"; do
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
    done
}
stop_vms 10000 10001
